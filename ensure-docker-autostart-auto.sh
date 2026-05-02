#!/usr/bin/env bash
# ensure-docker-autostart-auto.sh
# Intelligentes Docker-Autostart-Skript für Coolify und Dokploy
# Startet Container nach Reboot in korrekter Reihenfolge
# Version 1.0

set -euo pipefail

LOGFILE="/var/log/docker-autostart.log"

# Wird automatisch erkannt
DEPLOYMENT_SYSTEM=""
DEPLOYMENT_PATH=""

# Docker Compose Befehl erkennen
DOCKER_COMPOSE=""
detect_docker_compose() {
    if docker compose version >/dev/null 2>&1; then
        DOCKER_COMPOSE="docker compose"
    elif command -v docker-compose >/dev/null 2>&1; then
        DOCKER_COMPOSE="docker-compose"
    else
        log "✗ ERROR: Weder 'docker compose' noch 'docker-compose' gefunden"
        exit 1
    fi
    log "Docker Compose: $DOCKER_COMPOSE"
}

# =====================================
# Hilfsfunktionen
# =====================================
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOGFILE"
}

# =====================================
# Auto-Detection
# =====================================
detect_deployment_system() {
    log "Erkenne Deployment-System..."
    
    # Prüfe auf Coolify
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "coolify"; then
        DEPLOYMENT_SYSTEM="coolify"
        
        # Finde Coolify-Pfad
        for path in "/data/coolify/source" "/opt/coolify/source" "/root/coolify/source"; do
            if [[ -d "$path" ]] && [[ -f "$path/docker-compose.yml" ]]; then
                DEPLOYMENT_PATH="$path"
                break
            fi
        done
        
        log "✓ Coolify erkannt"
        [[ -n "$DEPLOYMENT_PATH" ]] && log "  Pfad: $DEPLOYMENT_PATH"
        return 0
    fi
    
    # Prüfe auf Dokploy
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "dokploy"; then
        DEPLOYMENT_SYSTEM="dokploy"
        
        # Finde Dokploy-Pfad
        for path in "/etc/dokploy" "/opt/dokploy" "/var/lib/dokploy" "/root/dokploy"; do
            if [[ -d "$path" ]] && [[ -f "$path/docker-compose.yml" ]]; then
                DEPLOYMENT_PATH="$path"
                break
            fi
        done
        
        log "✓ Dokploy erkannt"
        [[ -n "$DEPLOYMENT_PATH" ]] && log "  Pfad: $DEPLOYMENT_PATH"
        return 0
    fi
    
    log "⚠ Kein bekanntes Deployment-System gefunden"
    DEPLOYMENT_SYSTEM="none"
}

# =====================================
# Docker warten
# =====================================
wait_for_docker() {
    local max_attempts=30
    local attempt=1
    
    log "Warte auf Docker-Dienst..."
    
    while ! docker info >/dev/null 2>&1; do
        log "Warte auf Docker... ($attempt/$max_attempts)"
        sleep 2
        ((attempt++))
        
        if [[ $attempt -gt $max_attempts ]]; then
            log "✗ ERROR: Docker nicht gestartet nach $max_attempts Versuchen"
            exit 1
        fi
    done
    
    log "✓ Docker ist bereit"
}

# =====================================
# Coolify starten
# =====================================
start_coolify() {
    log "Starte Coolify-Services..."
    
    # docker start bevorzugt — vermeidet compose-Validierungsfehler
    # Container existieren bereits, müssen nur gestartet werden
    log "→ Starte DB und Redis..."
    docker start coolify-db coolify-redis 2>/dev/null || true
    sleep 10
    
    log "→ Starte Realtime (Soketi)..."
    docker start coolify-realtime 2>/dev/null || true
    sleep 10
    
    log "→ Starte Coolify Hauptcontainer..."
    docker start coolify 2>/dev/null || true
    sleep 10
    
    log "→ Starte Proxy..."
    docker start coolify-proxy 2>/dev/null || true
    sleep 5
    
    # Warte und verifiziere
    sleep 10
    verify_coolify
}

verify_coolify() {
    log "Verifiziere Coolify-Services..."
    
    [[ $(docker ps | grep -c "coolify-db") -gt 0 ]] && log "✓ Coolify Database läuft" || log "✗ WARNING: Coolify Database läuft nicht!"
    [[ $(docker ps | grep -c "coolify-redis") -gt 0 ]] && log "✓ Coolify Redis läuft" || log "✗ WARNING: Coolify Redis läuft nicht!"
    [[ $(docker ps | grep -c "coolify-realtime") -gt 0 ]] && log "✓ Coolify Soketi läuft" || log "✗ WARNING: Coolify Soketi läuft nicht!"
    [[ $(docker ps | grep "^coolify" | grep -vc "coolify-") -gt 0 ]] && log "✓ Coolify Hauptservice läuft" || log "✗ WARNING: Coolify Hauptservice läuft nicht!"
    [[ $(docker ps | grep -c "coolify-proxy") -gt 0 ]] && log "✓ Coolify Proxy läuft" || log "✗ WARNING: Coolify Proxy läuft nicht!"
}

# =====================================
# Dokploy starten
# =====================================
start_dokploy() {
    log "Starte Dokploy-Services..."
    
    # docker start bevorzugt — vermeidet compose-Validierungsfehler
    log "Starte PostgreSQL und Redis..."
    docker start dokploy-postgres dokploy-redis 2>/dev/null || true
    sleep 10
    
    log "Starte Dokploy Hauptservice..."
    docker start dokploy 2>/dev/null || true
    sleep 10
    
    log "Starte Traefik Proxy..."
    docker start dokploy-traefik 2>/dev/null || true
    sleep 5
    
    # Warte und verifiziere
    sleep 10
    verify_dokploy
}

verify_dokploy() {
    log "Verifiziere Dokploy-Services..."
    
    [[ $(docker ps | grep -c "dokploy-postgres") -gt 0 ]] && log "✓ Dokploy PostgreSQL läuft" || log "✗ WARNING: Dokploy PostgreSQL läuft nicht!"
    [[ $(docker ps | grep -c "dokploy-redis") -gt 0 ]] && log "✓ Dokploy Redis läuft" || log "✗ WARNING: Dokploy Redis läuft nicht!"
    [[ $(docker ps | grep -c "dokploy/dokploy") -gt 0 ]] && log "✓ Dokploy Hauptservice läuft" || log "✗ WARNING: Dokploy Hauptservice läuft nicht!"
    [[ $(docker ps | grep -c "dokploy-traefik") -gt 0 ]] && log "✓ Traefik Proxy läuft" || log "✗ WARNING: Traefik Proxy läuft nicht!"
}

# =====================================
# Andere Container starten
# =====================================
start_other_containers() {
    log "Starte andere Container mit Restart-Policy..."
    
    local system_prefix
    case "$DEPLOYMENT_SYSTEM" in
        coolify) system_prefix="coolify" ;;
        dokploy) system_prefix="dokploy" ;;
        *) system_prefix="nonexistent" ;;
    esac
    
    while read -r container; do
        if [[ -n "$container" ]]; then
            local state=$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null || echo "false")
            local restart_policy=$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$container" 2>/dev/null || echo "")

            if [[ "$state" == "false" ]] && ([[ "$restart_policy" == "always" ]] || [[ "$restart_policy" == "unless-stopped" ]]); then
                log "Starte Container: $container"
                docker start "$container" 2>/dev/null || log "⚠ Fehler beim Starten von $container"
            fi
        fi
    done < <(docker ps -a --format '{{.Names}}' | grep -v "^${system_prefix}")
}

# =====================================
# Hauptfunktion
# =====================================
main() {
    log "========================================="
    log "Docker Autostart gestartet"
    log "========================================="
    log "Datum: $(date)"
    log "Hostname: $(hostname)"
    
    # Warte auf Docker
    wait_for_docker
    
    # Erkenne Docker Compose
    detect_docker_compose

    # Erkenne System
    detect_deployment_system
    log "System: ${DEPLOYMENT_SYSTEM^^}"
    
    # Starte entsprechenden Stack
    case "$DEPLOYMENT_SYSTEM" in
        coolify)
            start_coolify
            ;;
        dokploy)
            start_dokploy
            ;;
        *)
            log "⚠ Kein bekanntes Deployment-System, starte nur Docker-Container"
            ;;
    esac
    
    # Starte andere Container
    start_other_containers
    
    log "========================================="
    log "Docker Autostart abgeschlossen"
    log "========================================="
    log "Finale Container-Status:"
    docker ps --format "table {{.Names}}\t{{.Status}}" | tee -a "$LOGFILE"
}

# Ausführen
main
