#!/bin/bash
# vps-update-simple.sh
# Vereinfachtes VPS Update-Skript ohne Backup
# Features: Minimale Komplexität, Coolify-Start-Reihenfolge, Fokus auf Stabilität

set -euo pipefail

# =====================================
# Konfiguration
# =====================================
LOGFILE="/var/log/vps-update-simple.log"
LOCKFILE="/var/run/vps-update.lock"

# =====================================
# Farben für Terminal-Output
# =====================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# =====================================
# Logging-Funktionen
# =====================================
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOGFILE"
}

log_success() {
    echo -e "${GREEN}[✓]${NC} $*" | tee -a "$LOGFILE"
}

log_warning() {
    echo -e "${YELLOW}[!]${NC} $*" | tee -a "$LOGFILE"
}

log_error() {
    echo -e "${RED}[✗]${NC} $*" | tee -a "$LOGFILE"
}

# =====================================
# Cleanup
# =====================================
cleanup() {
    rm -f "$LOCKFILE"
}

trap cleanup EXIT

# =====================================
# Hauptfunktionen
# =====================================
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Dieses Skript muss als root ausgeführt werden"
        exit 1
    fi
}

check_lock() {
    if [[ -f "$LOCKFILE" ]]; then
        log_error "Update läuft bereits (Lockfile: $LOCKFILE)"
        exit 1
    fi
    touch "$LOCKFILE"
}

stop_containers() {
    log "Stoppe Docker-Container..."
    
    # Coolify-spezifische Behandlung
    if docker ps | grep -q coolify; then
        log "Coolify erkannt - stoppe in korrekter Reihenfolge..."
        
        # Stoppe Services in umgekehrter Abhängigkeitsreihenfolge
        for service in coolify-proxy coolify coolify-realtime coolify-redis coolify-db; do
            if docker ps | grep -q "$service"; then
                log "Stoppe $service..."
                docker stop "$service" 2>/dev/null || log_warning "Konnte $service nicht stoppen"
            fi
        done
    fi
    
    # Stoppe alle anderen laufenden Container
    local other_containers=$(docker ps -q --filter "name=^(?!coolify).*")
    if [[ -n "$other_containers" ]]; then
        log "Stoppe andere Container..."
        docker stop $other_containers 2>/dev/null || true
    fi
    
    log_success "Container gestoppt"
}

update_system() {
    log "Starte System-Updates..."
    
    # Update Paketlisten
    log "Aktualisiere Paketlisten..."
    if ! apt-get update; then
        log_error "apt-get update fehlgeschlagen"
        return 1
    fi
    
    # Führe Updates durch
    log "Installiere Updates..."
    if ! DEBIAN_FRONTEND=noninteractive apt-get upgrade -y; then
        log_warning "apt-get upgrade hatte Probleme"
    fi
    
    # Kernel-Updates nur wenn nötig
    if apt list --upgradable 2>/dev/null | grep -q linux-image; then
        log "Kernel-Update verfügbar - führe dist-upgrade durch..."
        DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y || true
    fi
    
    # Aufräumen
    log "Räume auf..."
    apt-get autoremove -y 2>/dev/null || true
    apt-get autoclean 2>/dev/null || true
    
    log_success "System-Updates abgeschlossen"
}

start_coolify() {
    if [[ ! -d "/data/coolify/source" ]]; then
        log "Coolify nicht installiert"
        return 0
    fi
    
    log "Starte Coolify-Stack..."
    cd /data/coolify/source
    
    # Nutze docker-compose für korrekte Reihenfolge
    if docker compose up -d 2>&1 | tee -a "$LOGFILE"; then
        log_success "Coolify gestartet"
    else
        log_error "Fehler beim Starten von Coolify"
        return 1
    fi
    
    # Warte auf Services
    log "Warte auf Coolify-Services..."
    sleep 20
    
    # Verifiziere wichtige Services
    local all_running=true
    for service in coolify-db coolify-redis coolify-realtime coolify coolify-proxy; do
        if docker ps | grep -q "$service"; then
            log_success "$service läuft"
        else
            log_warning "$service läuft nicht"
            all_running=false
        fi
    done
    
    if [[ "$all_running" == "true" ]]; then
        log_success "Alle Coolify-Services laufen"
    else
        log_warning "Einige Coolify-Services fehlen"
    fi
}

start_other_containers() {
    log "Starte andere Container..."
    
    local count=0
    docker ps -a --format '{{.Names}}' | grep -v "^coolify" | while read -r container; do
        if [[ -z "$container" ]]; then
            continue
        fi
        
        local restart_policy=$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$container" 2>/dev/null)
        
        if [[ "$restart_policy" == "always" ]] || [[ "$restart_policy" == "unless-stopped" ]]; then
            if docker start "$container" 2>/dev/null; then
                log_success "Gestartet: $container"
                ((count++))
            else
                log_warning "Fehler bei: $container"
            fi
        fi
    done
    
    log_success "Container-Start abgeschlossen"
}

check_services() {
    log "Führe Service-Check durch..."
    
    # Docker Status
    if systemctl is-active docker >/dev/null 2>&1; then
        log_success "Docker läuft"
    else
        log_error "Docker läuft nicht!"
    fi
    
    # Container Statistik
    local running=$(docker ps -q | wc -l)
    local total=$(docker ps -aq | wc -l)
    log "Container: $running von $total laufen"
    
    # Disk Space
    local disk_usage=$(df -h / | awk 'NR==2{print $5}')
    log "Festplatte: $disk_usage belegt"
    
    # Memory
    local mem_available=$(free -m | awk 'NR==2{print $7}')
    log "Verfügbarer Speicher: ${mem_available}MB"
}

check_reboot() {
    if [[ -f /var/run/reboot-required ]]; then
        log_warning "NEUSTART ERFORDERLICH!"
        echo ""
        echo -e "${YELLOW}Ein Neustart ist erforderlich!${NC}"
        echo "Möchten Sie jetzt neustarten? (j/n)"
        read -r -n 1 answer
        echo ""
        if [[ "$answer" == "j" ]] || [[ "$answer" == "J" ]]; then
            log "Starte Neustart..."
            reboot
        else
            log "Neustart verschoben - bitte manuell durchführen"
        fi
    else
        log_success "Kein Neustart erforderlich"
    fi
}

# =====================================
# Hauptprogramm
# =====================================
main() {
    echo ""
    echo "================================="
    echo "   VPS Update Script (Simple)"
    echo "================================="
    echo ""
    
    log "=== VPS Update gestartet ==="
    
    # Checks
    check_root
    check_lock
    
    # Update-Prozess
    stop_containers
    update_system
    start_coolify
    start_other_containers
    
    # Verifizierung
    check_services
    
    # Reboot-Check
    check_reboot
    
    log_success "=== VPS Update abgeschlossen ==="
    echo ""
    echo "Update erfolgreich abgeschlossen!"
    echo "Log-Datei: $LOGFILE"
    echo ""
}

# Führe Hauptprogramm aus
main "$@"