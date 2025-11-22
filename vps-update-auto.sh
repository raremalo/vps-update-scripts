#!/bin/bash
# vps-update-auto.sh
# Intelligentes VPS Update-Skript das automatisch Coolify oder Dokploy erkennt
# Version 1.0

set -euo pipefail

# =====================================
# Konfiguration
# =====================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGFILE="/var/log/vps-update.log"
LOCKFILE="/var/run/vps-update.lock"

# Wird automatisch erkannt
DEPLOYMENT_SYSTEM=""
DEPLOYMENT_PATH=""

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
# Auto-Detection
# =====================================
detect_deployment_system() {
    log "INFO" "Erkenne Deployment-System..."
    
    # Prüfe auf Coolify
    if docker ps -a 2>/dev/null | grep -q "coolify"; then
        DEPLOYMENT_SYSTEM="coolify"
        
        # Finde Coolify-Pfad
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
    if docker ps -a 2>/dev/null | grep -q "dokploy"; then
        DEPLOYMENT_SYSTEM="dokploy"
        
        # Finde Dokploy-Pfad
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

    # Lock-File Check
    if [[ -f "$LOCKFILE" ]]; then
        log "ERROR" "Update läuft bereits (Lockfile: $LOCKFILE)"
        exit 1
    fi
    
    touch "$LOCKFILE"
    
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
    local containers=$(docker ps -q)
    if [[ -n "$containers" ]]; then
        docker stop $containers 2>/dev/null || true
    fi
}

update_system() {
    log "INFO" "Starte System-Updates..."
    
    # Update Paketlisten
    apt-get update || {
        log "ERROR" "apt-get update fehlgeschlagen"
        return 1
    }
    
    # Halte problematische Pakete zurück
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
    
    if [[ -n "$DEPLOYMENT_PATH" ]] && [[ -f "$DEPLOYMENT_PATH/docker-compose.yml" ]]; then
        cd "$DEPLOYMENT_PATH"
        
        # 1. Datenbank und Cache
        log "INFO" "Starte Datenbank und Redis..."
        docker compose up -d coolify-db coolify-redis 2>/dev/null || docker-compose up -d coolify-db coolify-redis
        sleep 10
        
        # 2. Soketi (Realtime)
        # HINWEIS: Ältere Coolify-Versionen verwenden "soketi", neuere "coolify-realtime"
        # docker-compose up -d versucht beide Namen falls vorhanden
        log "INFO" "Starte Soketi (Realtime Service)..."
        docker compose up -d coolify-realtime 2>/dev/null || docker-compose up -d coolify-realtime
        sleep 10
        
        # 3. Hauptcontainer
        log "INFO" "Starte Coolify Hauptservice..."
        docker compose up -d coolify 2>/dev/null || docker-compose up -d coolify
        sleep 10
        
        # 4. Proxy
        log "INFO" "Starte Coolify Proxy..."
        docker compose up -d coolify-proxy 2>/dev/null || docker-compose up -d coolify-proxy
        sleep 5
    else
        # Fallback: Manuelle Container-Starts
        log "INFO" "Starte Container manuell (kein docker-compose.yml gefunden)..."
        docker start coolify-db coolify-redis 2>/dev/null || true
        sleep 10
        docker start coolify-realtime 2>/dev/null || true
        sleep 10
        docker start coolify 2>/dev/null || true
        sleep 10
        docker start coolify-proxy 2>/dev/null || true
        sleep 5
    fi
    
    # Verifizierung
    verify_coolify_services
}

verify_coolify_services() {
    log "INFO" "Verifiziere Coolify-Services..."
    
    local all_ok=true
    
    if docker ps | grep -q "coolify-db"; then
        log "SUCCESS" "✓ Coolify Database läuft"
    else
        log "WARNING" "✗ Coolify Database läuft nicht!"
        all_ok=false
    fi
    
    if docker ps | grep -q "coolify-redis"; then
        log "SUCCESS" "✓ Coolify Redis läuft"
    else
        log "WARNING" "✗ Coolify Redis läuft nicht!"
        all_ok=false
    fi
    
    if docker ps | grep -q "coolify-realtime"; then
        log "SUCCESS" "✓ Coolify Soketi (Realtime) läuft"
    else
        log "WARNING" "✗ Coolify Soketi läuft nicht!"
        all_ok=false
    fi
    
    # Prüfe Hauptcontainer (nicht coolify-db, coolify-redis, etc.)
    if docker ps | grep "^coolify" | grep -qv "coolify-"; then
        log "SUCCESS" "✓ Coolify Hauptservice läuft"
    else
        log "ERROR" "✗ Coolify Hauptservice läuft nicht!"
        all_ok=false
    fi
    
    if docker ps | grep -q "coolify-proxy"; then
        log "SUCCESS" "✓ Coolify Proxy läuft"
    else
        log "WARNING" "✗ Coolify Proxy läuft nicht!"
        all_ok=false
    fi
    
    [[ "$all_ok" == true ]] && log "SUCCESS" "Coolify-Stack vollständig gestartet"
}

start_dokploy_stack() {
    log "INFO" "Starte Dokploy-Stack in korrekter Reihenfolge..."
    
    if [[ -n "$DEPLOYMENT_PATH" ]] && [[ -f "$DEPLOYMENT_PATH/docker-compose.yml" ]]; then
        cd "$DEPLOYMENT_PATH"
        
        # 1. Datenbank und Redis
        log "INFO" "Starte PostgreSQL und Redis..."
        docker compose up -d dokploy-postgres dokploy-redis 2>/dev/null || docker-compose up -d dokploy-postgres dokploy-redis
        sleep 10
        
        # 2. Hauptcontainer (KEIN Soketi bei Dokploy)
        log "INFO" "Starte Dokploy Hauptservice..."
        docker compose up -d dokploy 2>/dev/null || docker-compose up -d dokploy
        sleep 10
        
        # 3. Traefik
        log "INFO" "Starte Traefik Proxy..."
        docker compose up -d dokploy-traefik 2>/dev/null || docker-compose up -d dokploy-traefik
        sleep 5
    else
        # Fallback: Manuelle Container-Starts
        log "INFO" "Starte Container manuell (kein docker-compose.yml gefunden)..."
        docker start dokploy-postgres dokploy-redis 2>/dev/null || true
        sleep 10
        docker start dokploy 2>/dev/null || true
        sleep 10
        docker start dokploy-traefik 2>/dev/null || true
        sleep 5
    fi
    
    # Verifizierung
    verify_dokploy_services
}

verify_dokploy_services() {
    log "INFO" "Verifiziere Dokploy-Services..."
    
    local all_ok=true
    
    if docker ps | grep -q "dokploy-postgres"; then
        log "SUCCESS" "✓ Dokploy PostgreSQL läuft"
    else
        log "WARNING" "✗ Dokploy PostgreSQL läuft nicht!"
        all_ok=false
    fi
    
    if docker ps | grep -q "dokploy-redis"; then
        log "SUCCESS" "✓ Dokploy Redis läuft"
    else
        log "WARNING" "✗ Dokploy Redis läuft nicht!"
        all_ok=false
    fi
    
    if docker ps | grep -q "dokploy/dokploy"; then
        log "SUCCESS" "✓ Dokploy Hauptservice läuft"
    else
        log "ERROR" "✗ Dokploy Hauptservice läuft nicht!"
        all_ok=false
    fi
    
    if docker ps | grep -q "dokploy-traefik"; then
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
    docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | head -20 | tee -a "$LOGFILE"
}

# =====================================
# Hauptprogramm
# =====================================
main() {
    log "INFO" "========================================="
    log "INFO" "VPS Auto-Update gestartet"
    log "INFO" "========================================="
    log "INFO" "Datum: $(date)"
    log "INFO" "Server: $(hostname)"
    
    # Voraussetzungen prüfen & System erkennen
    check_prerequisites
    
    log "INFO" "Erkanntes System: ${DEPLOYMENT_SYSTEM^^}"
    [[ -n "$DEPLOYMENT_PATH" ]] && log "INFO" "Pfad: $DEPLOYMENT_PATH"
    
    # Docker-Container stoppen
    stop_docker_containers
    
    # System aktualisieren
    update_system
    
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
