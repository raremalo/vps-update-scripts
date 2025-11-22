#!/bin/bash
# ensure-docker-autostart-coolify.sh
# Stellt sicher, dass Docker-Container nach Reboot in korrekter Reihenfolge starten
# Optimiert für Coolify mit Soketi-Support

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

# Finde Coolify-Installationspfad
detect_coolify_path() {
    local possible_paths=(
        "/data/coolify/source"
        "/opt/coolify/source"
        "/root/coolify/source"
    )
    
    for path in "${possible_paths[@]}"; do
        if [[ -d "$path" ]] && [[ -f "$path/docker-compose.yml" ]]; then
            echo "$path"
            return 0
        fi
    done
    
    echo ""
}

# Starte Coolify in korrekter Reihenfolge
start_coolify() {
    if ! docker ps -a | grep -q coolify; then
        log "Coolify nicht installiert, überspringe..."
        return 0
    fi
    
    log "Starte Coolify-Services..."
    
    local coolify_path=$(detect_coolify_path)
    
    if [[ -n "$coolify_path" ]]; then
        log "Coolify-Pfad gefunden: $coolify_path"
        cd "$coolify_path"
        
        # Verwende docker compose für korrekte Reihenfolge
        log "Starte mit docker-compose..."
        docker compose up -d 2>/dev/null || docker-compose up -d
        
    else
        log "Kein docker-compose.yml gefunden, starte Container manuell..."
        
        # 1. Datenbank und Redis zuerst
        log "Starte Datenbank und Redis..."
        docker start coolify-db 2>/dev/null || true
        docker start coolify-redis 2>/dev/null || true
        sleep 10
        
        # 2. SOKETI (Realtime) - KRITISCH: MUSS VOR Coolify starten!
        log "Starte Soketi (Realtime Service)..."
        docker start coolify-realtime 2>/dev/null || true
        sleep 10  # Wichtig: Soketi braucht Zeit zum Starten
        
        # 3. Hauptcontainer
        log "Starte Coolify Hauptservice..."
        docker start coolify 2>/dev/null || true
        sleep 10
        
        # 4. Proxy
        log "Starte Coolify Proxy..."
        docker start coolify-proxy 2>/dev/null || true
        sleep 5
    fi
    
    # Warte und verifiziere
    sleep 10
    
    log "Verifiziere Coolify-Services..."
    
    if docker ps | grep -q "coolify-db"; then
        log "✓ Coolify Database läuft"
    else
        log "✗ WARNING: Coolify Database läuft nicht!"
    fi
    
    if docker ps | grep -q "coolify-redis"; then
        log "✓ Coolify Redis läuft"
    else
        log "✗ WARNING: Coolify Redis läuft nicht!"
    fi
    
    if docker ps | grep -q "coolify-realtime"; then
        log "✓ Coolify Soketi (Realtime) läuft"
    else
        log "✗ CRITICAL: Coolify Soketi läuft nicht! Coolify benötigt diesen Service!"
    fi
    
    if docker ps | grep "^coolify" | grep -qv "coolify-"; then
        log "✓ Coolify Hauptservice läuft"
    else
        log "✗ WARNING: Coolify Hauptservice läuft nicht!"
    fi
    
    if docker ps | grep -q "coolify-proxy"; then
        log "✓ Coolify Proxy läuft"
    else
        log "✗ WARNING: Coolify Proxy läuft nicht!"
    fi
}

# Starte andere Container
start_other_containers() {
    log "Starte andere Container mit Restart-Policy..."
    
    # Finde alle Container die nicht laufen aber restart policy haben
    docker ps -a --format '{{.Names}}' | grep -v "^coolify" | while read -r container; do
        if [[ -n "$container" ]]; then
            local state=$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null || echo "false")
            local restart_policy=$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$container" 2>/dev/null || echo "")
            
            if [[ "$state" == "false" ]] && ([[ "$restart_policy" == "always" ]] || [[ "$restart_policy" == "unless-stopped" ]]); then
                log "Starte Container: $container"
                docker start "$container" 2>/dev/null || log "Fehler beim Starten von $container"
            fi
        fi
    done
}

# Hauptfunktion
main() {
    log "=== Docker Autostart für Coolify gestartet ==="
    log "Datum: $(date)"
    log "Hostname: $(hostname)"
    
    wait_for_docker
    start_coolify
    start_other_containers
    
    log "=== Docker Autostart abgeschlossen ==="
    log "Finale Container-Status:"
    docker ps --format "table {{.Names}}\t{{.Status}}" | tee -a "$LOGFILE"
}

main
