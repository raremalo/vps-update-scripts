#!/usr/bin/env bash
# vps-update-dokploy.sh
# VPS Update-Skript optimiert für Dokploy
# Angepasst von vps-update-coolify-optimized.sh

set -euo pipefail

# =====================================
# Konfiguration
# =====================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGFILE="/var/log/vps-update.log"
LOCKFILE="/var/run/vps-update.lock"

# Dokploy-spezifische Konfiguration
DOKPLOY_PATH="/etc/dokploy"  # Standardpfad, wird automatisch erkannt

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

    # Atomic lock
    exec 9>"$LOCKFILE"
    flock -n 9 || { log "ERROR" "Script läuft bereits (Lock: $LOCKFILE)"; exit 1; }
    
    # Finde Dokploy-Installationspfad
    detect_dokploy_path
}

detect_dokploy_path() {
    log "INFO" "Suche Dokploy-Installation..."
    
    # Mögliche Installationspfade
    local possible_paths=(
        "/etc/dokploy"
        "/opt/dokploy"
        "/var/lib/dokploy"
        "/root/dokploy"
    )
    
    for path in "${possible_paths[@]}"; do
        if [[ -d "$path" ]] && [[ -f "$path/docker-compose.yml" ]]; then
            DOKPLOY_PATH="$path"
            log "SUCCESS" "Dokploy gefunden: $DOKPLOY_PATH"
            return 0
        fi
    done
    
    # Falls nicht gefunden, prüfe ob Dokploy-Container laufen
    if docker ps --format '{{.Names}}' | grep -qx "dokploy"; then
        log "WARNING" "Dokploy-Container laufen, aber docker-compose.yml nicht gefunden"
        log "INFO" "Verwende Docker-Befehle statt docker-compose"
        DOKPLOY_PATH=""
        return 0
    fi
    
    log "WARNING" "Dokploy-Installation nicht gefunden"
    DOKPLOY_PATH=""
}

stop_docker_containers() {
    log "INFO" "Stoppe Docker-Container..."
    
    # Dokploy-spezifische Reihenfolge (OHNE Soketi, da nicht vorhanden)
    if docker ps -a --format '{{.Names}}' | grep -q "dokploy"; then
        log "INFO" "Dokploy erkannt - stoppe in korrekter Reihenfolge..."
        
        # 1. Stoppe zuerst Traefik (Proxy)
        docker stop dokploy-traefik 2>/dev/null || true
        sleep 2
        
        # 2. Dann Hauptcontainer
        docker stop dokploy 2>/dev/null || true
        sleep 2
        
        # 3. Zuletzt Datenbank und Redis
        docker stop dokploy-redis 2>/dev/null || true
        docker stop dokploy-postgres 2>/dev/null || true
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

start_dokploy_stack() {
    if ! docker ps -a --format '{{.Names}}' | grep -q "dokploy"; then
        log "INFO" "Dokploy nicht installiert"
        return 0
    fi
    
    log "INFO" "Starte Dokploy-Stack in korrekter Reihenfolge..."
    
    # Wenn docker-compose.yml vorhanden, nutze es
    if [[ -n "$DOKPLOY_PATH" ]] && [[ -f "$DOKPLOY_PATH/docker-compose.yml" ]]; then
        cd "$DOKPLOY_PATH"
        
        # 1. Datenbank und Cache zuerst
        log "INFO" "Starte Datenbank und Redis..."
        docker compose up -d dokploy-postgres dokploy-redis 2>/dev/null || {
            # Fallback auf docker-compose (ältere Version)
            docker-compose up -d dokploy-postgres dokploy-redis
        }
        sleep 10  # Warte auf Initialisierung
        
        # 2. Hauptcontainer (KEIN Soketi bei Dokploy!)
        log "INFO" "Starte Dokploy Hauptservice..."
        docker compose up -d dokploy 2>/dev/null || docker-compose up -d dokploy
        sleep 10
        
        # 3. Proxy (Traefik)
        log "INFO" "Starte Traefik Proxy..."
        docker compose up -d dokploy-traefik 2>/dev/null || docker-compose up -d dokploy-traefik
        sleep 5
        
    else
        # Fallback: Starte Container direkt mit Docker
        log "INFO" "Starte Container direkt (ohne docker-compose)..."
        
        # 1. Datenbank und Redis
        docker start dokploy-postgres 2>/dev/null || true
        docker start dokploy-redis 2>/dev/null || true
        sleep 10
        
        # 2. Hauptcontainer
        docker start dokploy 2>/dev/null || true
        sleep 10
        
        # 3. Traefik
        docker start dokploy-traefik 2>/dev/null || true
        sleep 5
    fi
    
    # Verifiziere dass Services laufen
    log "INFO" "Verifiziere Dokploy-Services..."
    
    if docker ps --format '{{.Names}}' | grep -qx "dokploy-postgres"; then
        log "SUCCESS" "✓ Dokploy PostgreSQL läuft"
    else
        log "WARNING" "✗ Dokploy PostgreSQL läuft nicht!"
    fi
    
    if docker ps --format '{{.Names}}' | grep -qx "dokploy-redis"; then
        log "SUCCESS" "✓ Dokploy Redis läuft"
    else
        log "WARNING" "✗ Dokploy Redis läuft nicht!"
    fi

    if docker ps --format '{{.Names}}' | grep -qx "dokploy"; then
        log "SUCCESS" "✓ Dokploy Hauptservice läuft"
    else
        log "ERROR" "✗ Dokploy Hauptservice läuft nicht!"
    fi

    if docker ps --format '{{.Names}}' | grep -qx "dokploy-traefik"; then
        log "SUCCESS" "✓ Traefik Proxy läuft"
    else
        log "WARNING" "✗ Traefik Proxy läuft nicht!"
    fi
    
    log "SUCCESS" "Dokploy-Stack gestartet"
}

start_other_containers() {
    log "INFO" "Starte andere Container..."
    
    # Finde alle gestoppten Container mit restart policy
    docker ps -a --format '{{.Names}}\t{{.State}}' | grep -v "dokploy" | while IFS=$'\t' read -r name state; do
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
        while read -r pkg; do
            log "WARNING" "  - $pkg"
        done < <(cat /var/run/reboot-required.pkgs 2>/dev/null)
        
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
    docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep -E "(dokploy|NAMES)" || true
}

# =====================================
# Hauptprogramm
# =====================================
main() {
    log "INFO" "=== VPS Update für Dokploy gestartet ==="
    log "INFO" "Datum: $(date)"
    log "INFO" "Server: $(hostname)"
    
    # Voraussetzungen prüfen
    check_prerequisites
    
    # Docker-Container stoppen
    stop_docker_containers
    
    # System aktualisieren
    update_system
    
    # Dokploy-Stack starten
    start_dokploy_stack
    
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
