#!/usr/bin/env bash
# vps-update-auto.sh
# Intelligentes VPS Update-Skript das automatisch Coolify oder Dokploy erkennt
# Version 2.0

set -euo pipefail

# =====================================
# Konfiguration
# =====================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGFILE="/var/log/vps-update.log"
LOCKFILE="/var/run/vps-update.lock"

# Apt-Lock: Maximale Wartezeit in Sekunden (Standard: 5 Minuten)
APT_LOCK_WAIT="${APT_LOCK_WAIT:-300}"
APT_LOCK_INTERVAL=10

# Log-Rotation: Maximale Loggröße in Bytes (Standard: 1MB)
LOG_MAX_SIZE="${LOG_MAX_SIZE:-1048576}"

# Reboot: Countdown in Sekunden (Standard: 60)
REBOOT_DELAY="${REBOOT_DELAY:-60}"

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
        log "ERROR" "Weder 'docker compose' noch 'docker-compose' gefunden"
        exit 1
    fi
    log "INFO" "Docker Compose: $DOCKER_COMPOSE"
}

# =====================================
# Farben
# =====================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# =====================================
# Hilfsfunktionen
# =====================================
log() {
    local level="$1"
    shift
    local color=""
    case "$level" in
        INFO)    color="$BLUE" ;;
        SUCCESS) color="$GREEN" ;;
        WARNING) color="$YELLOW" ;;
        ERROR)   color="$RED" ;;
    esac
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*"
    echo -e "${color}${msg}${NC}" | tee -a "$LOGFILE"
}

rotate_log() {
    if [[ -f "$LOGFILE" ]] && [[ $(stat -f%z "$LOGFILE" 2>/dev/null || stat -c%s "$LOGFILE" 2>/dev/null) -gt "$LOG_MAX_SIZE" ]]; then
        local backup="${LOGFILE}.$(date '+%Y%m%d%H%M%S')"
        mv "$LOGFILE" "$backup"
        gzip "$backup" 2>/dev/null || true
        # Nur die letzten 3 rotierten Logs behalten
        ls -t "${LOGFILE}."*.gz 2>/dev/null | tail -n +4 | xargs rm -f 2>/dev/null || true
        log "INFO" "Log rotiert"
    fi
}

cleanup() {
    rm -f "$LOCKFILE"
}

emergency_restart() {
    log "ERROR" "⚠ Fehler aufgetreten — starte Container als Notfall-Maßnahme neu..."
    start_deployment_stack || true
    start_other_containers || true
    log "WARNING" "Container wurden nach Fehler neu gestartet"
}

trap cleanup EXIT

# =====================================
# Auto-Detection
# =====================================
detect_deployment_system() {
    log "INFO" "Erkenne Deployment-System..."
    
    # Prüfe auf Coolify
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "coolify"; then
        DEPLOYMENT_SYSTEM="coolify"
        
        local coolify_paths=(
            "/data/coolify/source"
            "/opt/coolify/source"
            "/root/coolify/source"
        )
        
        for path in "${coolify_paths[@]}"; do
            if [[ -d "$path" ]] && [[ -f "$path/docker-compose.yml" ]]; then
                DEPLOYMENT_PATH="$path"
                break
            fi
        done
        
        log "SUCCESS" "✓ Coolify erkannt"
        [[ -n "$DEPLOYMENT_PATH" ]] && log "INFO" "  Pfad: $DEPLOYMENT_PATH"
        return 0
    fi
    
    # Prüfe auf Dokploy
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "dokploy"; then
        DEPLOYMENT_SYSTEM="dokploy"
        
        local dokploy_paths=(
            "/etc/dokploy"
            "/opt/dokploy"
            "/var/lib/dokploy"
            "/root/dokploy"
        )
        
        for path in "${dokploy_paths[@]}"; do
            if [[ -d "$path" ]] && [[ -f "$path/docker-compose.yml" ]]; then
                DEPLOYMENT_PATH="$path"
                break
            fi
        done
        
        log "SUCCESS" "✓ Dokploy erkannt"
        [[ -n "$DEPLOYMENT_PATH" ]] && log "INFO" "  Pfad: $DEPLOYMENT_PATH"
        return 0
    fi
    
    log "WARNING" "Kein bekanntes Deployment-System gefunden (Coolify/Dokploy)"
    DEPLOYMENT_SYSTEM="none"
}

# =====================================
# Hauptfunktionen
# =====================================
check_prerequisites() {
    # Root-Check
    if [[ $EUID -ne 0 ]]; then
        log "ERROR" "Dieses Skript muss als root ausgeführt werden"
        exit 1
    fi

    # Atomic lock
    exec 9>"$LOCKFILE"
    flock -n 9 || { log "ERROR" "Script läuft bereits (Lock: $LOCKFILE)"; exit 1; }
    
    # Log-Rotation
    rotate_log
    
    # Docker Compose erkennen
    detect_docker_compose

    # Erkenne Deployment-System
    detect_deployment_system
}

stop_docker_containers() {
    log "INFO" "Stoppe Docker-Container..."
    
    case "$DEPLOYMENT_SYSTEM" in
        coolify)
            stop_coolify_containers
            ;;
        dokploy)
            stop_dokploy_containers
            ;;
        *)
            stop_generic_containers
            ;;
    esac
    
    log "SUCCESS" "Container gestoppt"
}

stop_coolify_containers() {
    log "INFO" "Stoppe Coolify-Container in korrekter Reihenfolge..."
    
    # 1. Proxy
    docker stop coolify-proxy 2>/dev/null || true
    sleep 2
    
    # 2. Hauptcontainer
    docker stop coolify 2>/dev/null || true
    sleep 2
    
    # 3. Soketi (Realtime)
    docker stop coolify-realtime 2>/dev/null || true
    sleep 2
    
    # 4. Datenbank und Redis
    docker stop coolify-redis 2>/dev/null || true
    docker stop coolify-db 2>/dev/null || true
    sleep 2
}

stop_dokploy_containers() {
    log "INFO" "Stoppe Dokploy-Container in korrekter Reihenfolge..."
    
    # 1. Traefik Proxy
    docker stop dokploy-traefik 2>/dev/null || true
    sleep 2
    
    # 2. Hauptcontainer
    docker stop dokploy 2>/dev/null || true
    sleep 2
    
    # 3. Datenbank und Redis
    docker stop dokploy-redis 2>/dev/null || true
    docker stop dokploy-postgres 2>/dev/null || true
    sleep 2
}

stop_generic_containers() {
    log "INFO" "Stoppe alle Docker-Container..."
    local containers
    containers=$(docker ps -q)
    if [[ -n "$containers" ]]; then
        docker stop $containers 2>/dev/null || true
    fi
}

# =====================================
# apt mit Lock-Retry
# =====================================
wait_for_apt_lock() {
    local waited=0
    while fuser /var/lib/apt/lists/lock >/dev/null 2>&1 || \
          fuser /var/lib/dpkg/lock >/dev/null 2>&1 || \
          fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
        
        if [[ $waited -ge $APT_LOCK_WAIT ]]; then
            log "ERROR" "Apt-Lock konnte nach ${APT_LOCK_WAIT}s nicht erhalten werden"
            return 1
        fi
        
        log "INFO" "Warte auf apt-Lock... (${waited}/${APT_LOCK_WAIT}s)"
        sleep "$APT_LOCK_INTERVAL"
        waited=$((waited + APT_LOCK_INTERVAL))
    done
    log "INFO" "Apt-Lock verfügbar"
}

update_system() {
    log "INFO" "Starte System-Updates..."
    
    # Warte auf apt-Lock
    wait_for_apt_lock || return 1
    
    # Update Paketlisten
    log "INFO" "Aktualisiere Paketlisten..."
    apt-get update || {
        log "ERROR" "apt-get update fehlgeschlagen"
        return 1
    }
    
    # Halte problematische Pakete zurück
    log "INFO" "Halte problematische Pakete zurück..."
    apt-mark hold snapd ubuntu-advantage-tools 2>/dev/null || true
    
    # Führe Updates durch (nur upgrade, kein dist-upgrade)
    log "INFO" "Führe Paket-Updates durch..."
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" || {
        log "ERROR" "apt-get upgrade fehlgeschlagen"
        return 1
    }
    
    # Aufräumen
    log "INFO" "Räume alte Pakete auf..."
    apt-get autoremove -y
    apt-get autoclean
    
    log "SUCCESS" "System-Updates abgeschlossen"
}

# =====================================
# Container starten
# =====================================
start_deployment_stack() {
    case "$DEPLOYMENT_SYSTEM" in
        coolify)
            start_coolify_stack
            ;;
        dokploy)
            start_dokploy_stack
            ;;
        *)
            log "INFO" "Kein Deployment-System erkannt, überspringe..."
            ;;
    esac
}

start_coolify_stack() {
    log "INFO" "Starte Coolify-Stack in korrekter Reihenfolge..."
    
    # docker start bevorzugt — vermeidet compose-Validierungsfehler
    # Container existieren bereits, müssen nur gestartet werden
    log "INFO" "Starte Datenbank und Redis..."
    docker start coolify-db coolify-redis 2>/dev/null || true
    sleep 10
    
    log "INFO" "Starte Soketi (Realtime Service)..."
    docker start coolify-realtime 2>/dev/null || true
    sleep 10
    
    log "INFO" "Starte Coolify Hauptservice..."
    docker start coolify 2>/dev/null || true
    sleep 10
    
    log "INFO" "Starte Coolify Proxy..."
    docker start coolify-proxy 2>/dev/null || true
    sleep 5
    
    # Verifizierung
    verify_coolify_services
}

verify_coolify_services() {
    log "INFO" "Verifiziere Coolify-Services..."
    
    local all_ok=true
    
    if docker ps --format '{{.Names}}' | grep -qx "coolify-db"; then
        log "SUCCESS" "✓ Coolify Database läuft"
    else
        log "WARNING" "✗ Coolify Database läuft nicht!"
        all_ok=false
    fi

    if docker ps --format '{{.Names}}' | grep -qx "coolify-redis"; then
        log "SUCCESS" "✓ Coolify Redis läuft"
    else
        log "WARNING" "✗ Coolify Redis läuft nicht!"
        all_ok=false
    fi

    if docker ps --format '{{.Names}}' | grep -qx "coolify-realtime"; then
        log "SUCCESS" "✓ Coolify Soketi (Realtime) läuft"
    else
        log "WARNING" "✗ Coolify Soketi läuft nicht!"
        all_ok=false
    fi

    if docker ps --format '{{.Names}}' | grep -qx "coolify"; then
        log "SUCCESS" "✓ Coolify Hauptservice läuft"
    else
        log "ERROR" "✗ Coolify Hauptservice läuft nicht!"
        all_ok=false
    fi

    if docker ps --format '{{.Names}}' | grep -qx "coolify-proxy"; then
        log "SUCCESS" "✓ Coolify Proxy läuft"
    else
        log "WARNING" "✗ Coolify Proxy läuft nicht!"
        all_ok=false
    fi
    
    [[ "$all_ok" == true ]] && log "SUCCESS" "Coolify-Stack vollständig gestartet"
}

start_dokploy_stack() {
    log "INFO" "Starte Dokploy-Stack in korrekter Reihenfolge..."
    
    # docker start bevorzugt — vermeidet compose-Validierungsfehler
    log "INFO" "Starte PostgreSQL und Redis..."
    docker start dokploy-postgres dokploy-redis 2>/dev/null || true
    sleep 10
    
    log "INFO" "Starte Dokploy Hauptservice..."
    docker start dokploy 2>/dev/null || true
    sleep 10
    
    log "INFO" "Starte Traefik Proxy..."
    docker start dokploy-traefik 2>/dev/null || true
    sleep 5
    
    # Verifizierung
    verify_dokploy_services
}

verify_dokploy_services() {
    log "INFO" "Verifiziere Dokploy-Services..."
    
    local all_ok=true
    
    if docker ps --format '{{.Names}}' | grep -qx "dokploy-postgres"; then
        log "SUCCESS" "✓ Dokploy PostgreSQL läuft"
    else
        log "WARNING" "✗ Dokploy PostgreSQL läuft nicht!"
        all_ok=false
    fi

    if docker ps --format '{{.Names}}' | grep -qx "dokploy-redis"; then
        log "SUCCESS" "✓ Dokploy Redis läuft"
    else
        log "WARNING" "✗ Dokploy Redis läuft nicht!"
        all_ok=false
    fi

    if docker ps --format '{{.Names}}' | grep -qx "dokploy"; then
        log "SUCCESS" "✓ Dokploy Hauptservice läuft"
    else
        log "ERROR" "✗ Dokploy Hauptservice läuft nicht!"
        all_ok=false
    fi

    if docker ps --format '{{.Names}}' | grep -qx "dokploy-traefik"; then
        log "SUCCESS" "✓ Traefik Proxy läuft"
    else
        log "WARNING" "✗ Traefik Proxy läuft nicht!"
        all_ok=false
    fi
    
    [[ "$all_ok" == true ]] && log "SUCCESS" "Dokploy-Stack vollständig gestartet"
}

start_other_containers() {
    log "INFO" "Starte andere Container mit Restart-Policy..."
    
    local system_prefix
    case "$DEPLOYMENT_SYSTEM" in
        coolify) system_prefix="coolify" ;;
        dokploy) system_prefix="dokploy" ;;
        *) system_prefix="nonexistent" ;;
    esac
    
    docker ps -a --format '{{.Names}}\t{{.State}}' | grep -v "^${system_prefix}" | while IFS=$'\t' read -r name state; do
        if [[ "$state" != "running" ]] && [[ -n "$name" ]]; then
            local restart_policy
            restart_policy=$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$name" 2>/dev/null || echo "")
            
            if [[ "$restart_policy" == "always" ]] || [[ "$restart_policy" == "unless-stopped" ]]; then
                log "INFO" "Starte Container: $name"
                docker start "$name" 2>/dev/null || log "WARNING" "Konnte $name nicht starten"
            fi
        fi
    done
    
    log "SUCCESS" "Andere Container gestartet"
}

check_reboot_required() {
    log "INFO" "Prüfe ob Neustart erforderlich..."
    
    if [[ -f /var/run/reboot-required ]]; then
        log "WARNING" "=== NEUSTART ERFORDERLICH ==="
        log "WARNING" "Gründe:"
        while read -r pkg; do
            log "WARNING" "  - $pkg"
        done < <(cat /var/run/reboot-required.pkgs 2>/dev/null)
        
        # Prüfe ob wir in einem Terminal laufen (nicht cron)
        if [[ -t 0 ]]; then
            log "INFO" "Neustart in ${REBOOT_DELAY} Sekunden... (Ctrl+C zum Abbrechen)"
            sleep "$REBOOT_DELAY"
            log "INFO" "Starte Neustart..."
            reboot
        else
            log "WARNING" "Automatischer Reboot übersprungen (kein Terminal)"
            log "WARNING" "Bitte manuell neustarten: reboot"
        fi
    else
        log "INFO" "Kein Neustart erforderlich"
    fi
}

show_final_status() {
    log "INFO" "=== Finale Container-Status ==="
    docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | head -20 | tee -a "$LOGFILE"
}

# =====================================
# Hauptprogramm
# =====================================
main() {
    log "INFO" "========================================="
    log "INFO" "VPS Auto-Update v2.0 gestartet"
    log "INFO" "========================================="
    log "INFO" "Datum: $(date)"
    log "INFO" "Server: $(hostname)"
    
    # Voraussetzungen prüfen & System erkennen
    check_prerequisites
    
    log "INFO" "Erkanntes System: ${DEPLOYMENT_SYSTEM^^}"
    [[ -n "$DEPLOYMENT_PATH" ]] && log "INFO" "Pfad: $DEPLOYMENT_PATH"
    
    # Docker-Container stoppen
    stop_docker_containers
    
    # System aktualisieren (mit Error-Recovery)
    if ! update_system; then
        log "ERROR" "System-Update fehlgeschlagen — starte Container als Notfall-Maßnahme neu..."
        emergency_restart
        show_final_status
        log "ERROR" "VPS Auto-Update mit Fehlern abgebrochen"
        exit 1
    fi
    
    # Deployment-Stack starten
    start_deployment_stack
    
    # Andere Container starten
    start_other_containers
    
    # Status anzeigen
    show_final_status
    
    # Reboot prüfen
    check_reboot_required
    
    log "SUCCESS" "========================================="
    log "SUCCESS" "VPS Auto-Update abgeschlossen"
    log "SUCCESS" "========================================="
}

# Skript ausführen
main "$@"
