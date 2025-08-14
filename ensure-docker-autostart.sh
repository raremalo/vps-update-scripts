#!/bin/bash
# ensure-docker-autostart-coolify.sh
# Stellt sicher, dass Docker-Container nach Reboot in korrekter Reihenfolge starten
# Features: Docker-Wartezeit, Coolify-Stack-Reihenfolge, Soketi-Verifizierung

set -euo pipefail

LOGFILE="/var/log/docker-autostart.log"
MAX_WAIT_DOCKER=60
MAX_WAIT_SERVICE=30

# =====================================
# Logging
# =====================================
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOGFILE"
}

# =====================================
# Docker-Funktionen
# =====================================
wait_for_docker() {
    local elapsed=0
    
    log "Warte auf Docker-Dienst..."
    
    while ! docker info >/dev/null 2>&1; do
        if [[ $elapsed -ge $MAX_WAIT_DOCKER ]]; then
            log "ERROR: Docker nicht gestartet nach ${MAX_WAIT_DOCKER} Sekunden"
            exit 1
        fi
        
        sleep 2
        elapsed=$((elapsed + 2))
        
        if [[ $((elapsed % 10)) -eq 0 ]]; then
            log "Warte auf Docker... (${elapsed}/${MAX_WAIT_DOCKER} Sekunden)"
        fi
    done
    
    log "✓ Docker ist bereit"
    
    # Zusätzliche Wartezeit für Docker-Stabilisierung
    sleep 5
}

wait_for_container() {
    local container_name="$1"
    local max_wait="${2:-$MAX_WAIT_SERVICE}"
    local elapsed=0
    
    while ! docker ps | grep -q "$container_name"; do
        if [[ $elapsed -ge $max_wait ]]; then
            log "WARNING: $container_name nicht gestartet nach ${max_wait} Sekunden"
            return 1
        fi
        
        sleep 2
        elapsed=$((elapsed + 2))
    done
    
    # Prüfe ob Container wirklich läuft (nicht nur existiert)
    if docker inspect -f '{{.State.Running}}' "$container_name" 2>/dev/null | grep -q true; then
        log "✓ $container_name läuft"
        return 0
    else
        log "✗ $container_name ist nicht im Running-Status"
        return 1
    fi
}

# =====================================
# Coolify-Funktionen
# =====================================
start_coolify_stack() {
    if [[ ! -d "/data/coolify/source" ]]; then
        log "Coolify nicht installiert - überspringe"
        return 0
    fi
    
    log "=== Starte Coolify-Stack ==="
    cd /data/coolify/source
    
    # 1. Datenbank und Redis
    log "Starte Datenbank-Services..."
    docker compose up -d coolify-db coolify-redis 2>&1 | tee -a "$LOGFILE"
    
    wait_for_container "coolify-db" || true
    wait_for_container "coolify-redis" || true
    
    # Extra Wartezeit für DB-Initialisierung
    log "Warte auf Datenbank-Initialisierung..."
    sleep 10
    
    # 2. Soketi Realtime Service
    log "Starte Soketi Realtime-Service..."
    docker compose up -d coolify-realtime 2>&1 | tee -a "$LOGFILE"
    
    if wait_for_container "coolify-realtime"; then
        # Teste Soketi-Port
        if nc -z localhost 6001 2>/dev/null; then
            log "✓ Soketi Port 6001 ist erreichbar"
        else
            log "WARNING: Soketi Port 6001 nicht erreichbar"
        fi
    fi
    
    # 3. Coolify Hauptcontainer
    log "Starte Coolify Hauptcontainer..."
    docker compose up -d coolify 2>&1 | tee -a "$LOGFILE"
    
    if wait_for_container "coolify"; then
        # Warte auf Coolify-Initialisierung
        sleep 15
        
        # Teste Coolify-Port
        if nc -z localhost 8000 2>/dev/null; then
            log "✓ Coolify Port 8000 ist erreichbar"
        else
            log "WARNING: Coolify Port 8000 nicht erreichbar"
        fi
    fi
    
    # 4. Proxy
    log "Starte Coolify Proxy..."
    docker compose up -d coolify-proxy 2>&1 | tee -a "$LOGFILE"
    
    wait_for_container "coolify-proxy" || true
    
    # Finale Verifizierung
    log "=== Coolify Status-Check ==="
    local all_running=true
    
    for service in coolify-db coolify-redis coolify-realtime coolify coolify-proxy; do
        if docker ps | grep -q "$service"; then
            local status=$(docker inspect -f '{{.State.Status}}' "$service" 2>/dev/null)
            local health=$(docker inspect -f '{{.State.Health.Status}}' "$service" 2>/dev/null || echo "no healthcheck")
            log "✓ $service: Status=$status, Health=$health"
        else
            log "✗ $service: Nicht gefunden oder nicht laufend"
            all_running=false
        fi
    done
    
    if [[ "$all_running" == "true" ]]; then
        log "SUCCESS: Alle Coolify-Services laufen"
    else
        log "WARNING: Einige Coolify-Services laufen nicht korrekt"
    fi
}

# =====================================
# Andere Container
# =====================================
start_other_containers() {
    log "=== Starte andere Container mit Autostart ==="
    
    local started_count=0
    local failed_count=0
    
    # Finde alle Container mit restart-policy always/unless-stopped
    docker ps -a --format '{{.Names}}' | grep -v "^coolify" | while read -r container; do
        if [[ -z "$container" ]]; then
            continue
        fi
        
        local restart_policy=$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$container" 2>/dev/null)
        
        if [[ "$restart_policy" == "always" ]] || [[ "$restart_policy" == "unless-stopped" ]]; then
            log "Starte Container: $container (Policy: $restart_policy)"
            
            if docker start "$container" 2>&1 | tee -a "$LOGFILE"; then
                ((started_count++))
                
                # Kurze Pause zwischen Container-Starts
                sleep 2
                
                # Verifiziere Start
                if docker ps | grep -q "$container"; then
                    log "✓ $container erfolgreich gestartet"
                else
                    log "✗ $container gestartet aber nicht laufend"
                    ((failed_count++))
                fi
            else
                log "✗ Fehler beim Starten von $container"
                ((failed_count++))
            fi
        fi
    done
    
    log "Container-Start abgeschlossen: $started_count erfolgreich, $failed_count fehlgeschlagen"
}

# =====================================
# System-Checks
# =====================================
system_health_check() {
    log "=== System Health Check ==="
    
    # Memory Check
    local mem_available=$(free -m | awk 'NR==2{print $7}')
    local mem_total=$(free -m | awk 'NR==2{print $2}')
    local mem_percent=$((100 - (mem_available * 100 / mem_total)))
    log "Memory: ${mem_percent}% verwendet (${mem_available}MB von ${mem_total}MB verfügbar)"
    
    # Disk Check
    local disk_usage=$(df -h / | awk 'NR==2{print $5}' | sed 's/%//')
    log "Disk: ${disk_usage}% verwendet auf /"
    
    # Docker Check
    local container_running=$(docker ps -q | wc -l)
    local container_total=$(docker ps -aq | wc -l)
    log "Docker: ${container_running} von ${container_total} Container laufen"
    
    # Network Check
    if ping -c 1 -W 2 google.com >/dev/null 2>&1; then
        log "✓ Internet-Verbindung aktiv"
    else
        log "✗ Keine Internet-Verbindung"
    fi
}

# =====================================
# Hauptprogramm
# =====================================
main() {
    log "========================================="
    log "=== Docker Autostart gestartet ==="
    log "========================================="
    
    # Warte auf Docker
    wait_for_docker
    
    # Starte Coolify-Stack
    start_coolify_stack
    
    # Kurze Pause zwischen Coolify und anderen Containern
    sleep 5
    
    # Starte andere Container
    start_other_containers
    
    # System Health Check
    system_health_check
    
    log "========================================="
    log "=== Docker Autostart abgeschlossen ==="
    log "========================================="
}

# Error Handler
error_handler() {
    local line_no=$1
    log "ERROR: Fehler in Zeile $line_no"
    exit 1
}

trap 'error_handler $LINENO' ERR

# Führe Hauptprogramm aus
main "$@"