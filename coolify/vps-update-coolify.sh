#!/bin/bash
# vps-update-coolify.sh
# VPS Update-Skript optimiert für Coolify
# Version 1.0

set -euo pipefail

# =====================================
# Konfiguration
# =====================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGFILE="/var/log/vps-update.log"
LOCKFILE="/var/run/vps-update.lock"

# Coolify-spezifische Konfiguration
COOLIFY_PATH="/data/coolify/source"  # Standardpfad, wird automatisch erkannt

# =====================================
# Hilfsfunktionen
# =====================================
log() {
    local level="$1"
    shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*" | tee -a "$LOGFILE"
}

cleanup() {
    rm -f "$LOCKFILE"
}

trap cleanup EXIT

# =====================================
# Hauptfunktionen
# =====================================
check_prerequisites() {
    # Root-Check
    if [[ $EUID -ne 0 ]]; then
        log "ERROR" "Dieses Skript muss als root ausgeführt werden"
        exit 1
    fi

    # Lock-File Check
    if [[ -f "$LOCKFILE" ]]; then
        log "ERROR" "Update läuft bereits (Lockfile: $LOCKFILE)"
        exit 1
    fi
    
    touch "$LOCKFILE"
    
    # Finde Coolify-Installationspfad
    detect_coolify_path
}

detect_coolify_path() {
    log "INFO" "Suche Coolify-Installation..."
    
    # Mögliche Installationspfade
    local possible_paths=(
        "/data/coolify/source"
        "/opt/coolify/source"
        "/root/coolify/source"
    )
    
    for path in "${possible_paths[@]}"; do
        if [[ -d "$path" ]] && [[ -f "$path/docker-compose.yml" ]]; then
            COOLIFY_PATH="$path"
            log "SUCCESS" "Coolify gefunden: $COOLIFY_PATH"
            return 0
        fi
    done
    
    # Falls nicht gefunden, prüfe ob Coolify-Container laufen
    if docker ps | grep -q "coolify"; then
        log "WARNING" "Coolify-Container laufen, aber docker-compose.yml nicht gefunden"
        log "INFO" "Verwende Docker-Befehle statt docker-compose"
        COOLIFY_PATH=""
        return 0
    fi
    
    log "ERROR" "Coolify-Installation nicht gefunden"
    exit 1
}

stop_docker_containers() {
    log "INFO" "Stoppe Docker-Container..."
    
    if docker ps | grep -q coolify; then
        log "INFO" "Coolify erkannt - stoppe in korrekter Reihenfolge..."
        
        # 1. Stoppe zuerst Proxy
        docker stop coolify-proxy 2>/dev/null || true
        sleep 2
        
        # 2. Dann Hauptcontainer
        docker stop coolify 2>/dev/null || true
        sleep 2
        
        # 3. Dann Soketi (WICHTIG: Muss VOR DB gestoppt werden)
        docker stop coolify-realtime 2>/dev/null || true
        sleep 2
        
        # 4. Zuletzt Datenbank und Redis
        docker stop coolify-redis 2>/dev/null || true
        docker stop coolify-db 2>/dev/null || true
        sleep 2
    fi
    
    # Stoppe alle anderen Container
    local containers=$(docker ps -q)
    if [[ -n "$containers" ]]; then
        log "INFO" "Stoppe verbleibende Container..."
        docker stop $containers 2>/dev/null || true
    fi
    
    log "SUCCESS" "Alle Container gestoppt"
}

update_system() {
    log "INFO" "Starte System-Updates..."
    
    # Update Paketlisten
    apt-get update || {
        log "ERROR" "apt-get update fehlgeschlagen"
        return 1
    }
    
    # Halte problematische Pakete zurück (falls vorhanden)
    log "INFO" "Halte problematische Pakete zurück..."
    apt-mark hold snapd ubuntu-advantage-tools 2>/dev/null || true
    
    # Führe Updates durch
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y || {
        log "ERROR" "apt-get upgrade fehlgeschlagen"
        return 1
    }
    
    # Kernel-Updates
    DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y || {
        log "ERROR" "apt-get dist-upgrade fehlgeschlagen"
        return 1
    }
    
    # Aufräumen
    apt-get autoremove -y
    apt-get autoclean
    
    log "SUCCESS" "System-Updates abgeschlossen"
}

start_coolify_stack() {
    if ! docker ps -a | grep -q coolify; then
        log "ERROR" "Coolify nicht installiert"
        exit 1
    fi
    
    log "INFO" "Starte Coolify-Stack in korrekter Reihenfolge..."
    
    # Wenn docker-compose.yml vorhanden, nutze es
    if [[ -n "$COOLIFY_PATH" ]] && [[ -f "$COOLIFY_PATH/docker-compose.yml" ]]; then
        cd "$COOLIFY_PATH"
        
        # 1. Datenbank und Cache zuerst
        log "INFO" "Starte Datenbank und Redis..."
        docker compose up -d coolify-db coolify-redis 2>/dev/null || {
            # Fallback auf docker-compose (ältere Version)
            docker-compose up -d coolify-db coolify-redis
        }
        sleep 10  # Warte auf Initialisierung
        
        # 2. SOKETI (Realtime) - MUSS VOR Coolify starten!
        log "INFO" "Starte Soketi (Realtime Service)..."
        docker compose up -d coolify-realtime 2>/dev/null || docker-compose up -d coolify-realtime
        sleep 10  # Wichtig: Warte bis Soketi bereit ist
        
        # 3. Hauptcontainer
        log "INFO" "Starte Coolify Hauptservice..."
        docker compose up -d coolify 2>/dev/null || docker-compose up -d coolify
        sleep 10
        
        # 4. Proxy
        log "INFO" "Starte Coolify Proxy..."
        docker compose up -d coolify-proxy 2>/dev/null || docker-compose up -d coolify-proxy
        sleep 5
        
    else
        # Fallback: Starte Container direkt mit Docker
        log "INFO" "Starte Container direkt (ohne docker-compose)..."
        
        # 1. Datenbank und Redis
        docker start coolify-db 2>/dev/null || true
        docker start coolify-redis 2>/dev/null || true
        sleep 10
        
        # 2. Soketi (WICHTIG!)
        docker start coolify-realtime 2>/dev/null || true
        sleep 10
        
        # 3. Hauptcontainer
        docker start coolify 2>/dev/null || true
        sleep 10
        
        # 4. Proxy
        docker start coolify-proxy 2>/dev/null || true
        sleep 5
    fi
    
    # Verifiziere dass Services laufen
    log "INFO" "Verifiziere Coolify-Services..."
    
    if docker ps | grep -q "coolify-db"; then
        log "SUCCESS" "✓ Coolify Database läuft"
    else
        log "WARNING" "✗ Coolify Database läuft nicht!"
    fi
    
    if docker ps | grep -q "coolify-redis"; then
        log "SUCCESS" "✓ Coolify Redis läuft"
    else
        log "WARNING" "✗ Coolify Redis läuft nicht!"
    fi
    
    if docker ps | grep -q "coolify-realtime"; then
        log "SUCCESS" "✓ Coolify Soketi (Realtime) läuft"
    else
        log "ERROR" "✗ Coolify Soketi läuft nicht! KRITISCH!"
    fi
    
    if docker ps | grep "^coolify" | grep -qv "coolify-"; then
        log "SUCCESS" "✓ Coolify Hauptservice läuft"
    else
        log "ERROR" "✗ Coolify Hauptservice läuft nicht!"
    fi
    
    if docker ps | grep -q "coolify-proxy"; then
        log "SUCCESS" "✓ Coolify Proxy läuft"
    else
        log "WARNING" "✗ Coolify Proxy läuft nicht!"
    fi
    
    log "SUCCESS" "Coolify-Stack gestartet"
}

start_other_containers() {
    log "INFO" "Starte andere Container..."
    
    # Finde alle gestoppten Container mit restart policy
    docker ps -a --format '{{.Names}}\t{{.State}}' | grep -v "coolify" | while IFS=$'\t' read -r name state; do
        if [[ "$state" != "running" ]] && [[ -n "$name" ]]; then
            local restart_policy=$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$name" 2>/dev/null || echo "")
            
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
        cat /var/run/reboot-required.pkgs 2>/dev/null | while read -r pkg; do
            log "WARNING" "  - $pkg"
        done
        
        log "INFO" "Starte Neustart in 30 Sekunden..."
        log "INFO" "Drücken Sie Ctrl+C zum Abbrechen"
        sleep 30
        log "INFO" "Starte Neustart..."
        reboot
    else
        log "INFO" "Kein Neustart erforderlich"
    fi
}

show_final_status() {
    log "INFO" "=== Finale Container-Status ==="
    docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep -E "(coolify|NAMES)" || true
}

# =====================================
# Hauptprogramm
# =====================================
main() {
    log "INFO" "=== VPS Update für Coolify gestartet ==="
    log "INFO" "Datum: $(date)"
    log "INFO" "Server: $(hostname)"
    
    # Voraussetzungen prüfen
    check_prerequisites
    
    # Docker-Container stoppen
    stop_docker_containers
    
    # System aktualisieren
    update_system
    
    # Coolify-Stack starten
    start_coolify_stack
    
    # Andere Container starten
    start_other_containers
    
    # Status anzeigen
    show_final_status
    
    # Reboot prüfen
    check_reboot_required
    
    log "SUCCESS" "=== VPS Update abgeschlossen ==="
}

# Skript ausführen
main "$@"
