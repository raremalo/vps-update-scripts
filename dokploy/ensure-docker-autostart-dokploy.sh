#!/usr/bin/env bash
# ensure-docker-autostart-dokploy.sh
# Stellt sicher, dass Docker-Container nach Reboot in korrekter Reihenfolge starten
# Optimiert für Dokploy (angepasst von Coolify-Version)

set -euo pipefail

LOGFILE="/var/log/docker-autostart.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOGFILE"
}

# Warte auf Docker
wait_for_docker() {
    local max_attempts=30
    local attempt=1
    
    log "Warte auf Docker-Dienst..."
    
    while ! docker info >/dev/null 2>&1; do
        log "Warte auf Docker... ($attempt/$max_attempts)"
        sleep 2
        ((attempt++))
        
        if [[ $attempt -gt $max_attempts ]]; then
            log "ERROR: Docker nicht gestartet nach $max_attempts Versuchen"
            exit 1
        fi
    done
    
    log "✓ Docker ist bereit"
}

# Finde Dokploy-Installationspfad
detect_dokploy_path() {
    local possible_paths=(
        "/etc/dokploy"
        "/opt/dokploy"
        "/var/lib/dokploy"
        "/root/dokploy"
    )
    
    for path in "${possible_paths[@]}"; do
        if [[ -d "$path" ]] && [[ -f "$path/docker-compose.yml" ]]; then
            echo "$path"
            return 0
        fi
    done
    
    echo ""
}

# Starte Dokploy in korrekter Reihenfolge
start_dokploy() {
    if ! docker ps -a --format '{{.Names}}' | grep -qi "dokploy"; then
        log "Dokploy nicht installiert, überspringe..."
        return 0
    fi
    
    log "Starte Dokploy-Services..."
    
    # Erkenne Container-Namen dynamisch
    local c_postgres c_redis c_main c_traefik
    local all_containers
    all_containers=$(docker ps -a --format '{{.Names}}')
    
    c_postgres=$(echo "$all_containers" | grep -iE '(dokploy.*postgres|postgres.*dokploy)' | head -1) || true
    c_redis=$(echo "$all_containers" | grep -iE '(dokploy.*redis|redis.*dokploy)' | head -1) || true
    c_traefik=$(echo "$all_containers" | grep -iE '(dokploy.*traefik|traefik.*dokploy)' | head -1) || true
    c_main=$(echo "$all_containers" | grep -i 'dokploy' | grep -viE '(postgres|redis|traefik)' | head -1) || true
    
    log "Erkannte Container: pg=$c_postgres redis=$c_redis main=$c_main traefik=$c_traefik"
    
    local dokploy_path=$(detect_dokploy_path)
    
    if [[ -n "$dokploy_path" ]]; then
        log "Dokploy-Pfad gefunden: $dokploy_path"
        cd "$dokploy_path"
        
        # Verwende docker compose für korrekte Reihenfolge
        log "Starte mit docker-compose..."
        docker compose up -d 2>/dev/null || docker-compose up -d
        
    else
        log "Kein docker-compose.yml gefunden, starte Container manuell..."
        
        # 1. Datenbank und Redis zuerst
        log "Starte Datenbank und Redis..."
        [[ -n "$c_postgres" ]] && docker start "$c_postgres" 2>/dev/null || true
        [[ -n "$c_redis" ]] && docker start "$c_redis" 2>/dev/null || true
        sleep 10
        
        # 2. Hauptcontainer (KEIN Soketi bei Dokploy!)
        log "Starte Dokploy Hauptservice..."
        [[ -n "$c_main" ]] && docker start "$c_main" 2>/dev/null || true
        sleep 10
        
        # 3. Traefik
        log "Starte Traefik Proxy..."
        [[ -n "$c_traefik" ]] && docker start "$c_traefik" 2>/dev/null || true
        sleep 5
    fi
    
    # Warte und verifiziere
    sleep 10
    
    log "Verifiziere Dokploy-Services..."
    
    if [[ -n "$c_postgres" ]] && docker ps --format '{{.Names}}' | grep -qx "$c_postgres"; then
        log "✓ PostgreSQL ($c_postgres) läuft"
    else
        log "✗ WARNING: PostgreSQL läuft nicht!"
    fi

    if [[ -n "$c_redis" ]] && docker ps --format '{{.Names}}' | grep -qx "$c_redis"; then
        log "✓ Redis ($c_redis) läuft"
    else
        log "✗ WARNING: Redis läuft nicht!"
    fi

    if [[ -n "$c_main" ]] && docker ps --format '{{.Names}}' | grep -qx "$c_main"; then
        log "✓ Dokploy ($c_main) läuft"
    else
        log "✗ WARNING: Dokploy Hauptservice läuft nicht!"
    fi

    if [[ -n "$c_traefik" ]] && docker ps --format '{{.Names}}' | grep -qx "$c_traefik"; then
        log "✓ Traefik ($c_traefik) läuft"
    else
        log "✗ WARNING: Traefik Proxy läuft nicht!"
    fi
}

# Starte andere Container
start_other_containers() {
    log "Starte andere Container mit Restart-Policy..."
    
    # Finde alle Container die nicht laufen aber restart policy haben
    while read -r container; do
        if [[ -n "$container" ]]; then
            local state=$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null || echo "false")
            local restart_policy=$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$container" 2>/dev/null || echo "")

            if [[ "$state" == "false" ]] && ([[ "$restart_policy" == "always" ]] || [[ "$restart_policy" == "unless-stopped" ]]); then
                log "Starte Container: $container"
                docker start "$container" 2>/dev/null || log "Fehler beim Starten von $container"
            fi
        fi
    done < <(docker ps -a --format '{{.Names}}' | grep -v "^dokploy")
}

# Hauptfunktion
main() {
    log "=== Docker Autostart für Dokploy gestartet ==="
    log "Datum: $(date)"
    log "Hostname: $(hostname)"
    
    wait_for_docker
    start_dokploy
    start_other_containers
    
    log "=== Docker Autostart abgeschlossen ==="
    log "Finale Container-Status:"
    docker ps --format "table {{.Names}}\t{{.Status}}" | tee -a "$LOGFILE"
}

main
