#!/usr/bin/env bash
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
    exec 9>"$LOCKFILE"
    flock -n 9 || { log_error "Script läuft bereits (Lock: $LOCKFILE)"; exit 1; }
}

stop_containers() {
    log "Stoppe Docker-Container..."
    
    # Coolify-spezifische Behandlung
    if docker ps --format '{{.Names}}' | grep -q "coolify"; then
        log "Coolify erkannt - stoppe in korrekter Reihenfolge..."

        # Stoppe Services in umgekehrter Abhängigkeitsreihenfolge
        for service in coolify-proxy coolify coolify-realtime coolify-redis coolify-db; do
            if docker ps --format '{{.Names}}' | grep -qx "$service"; then
                log "Stoppe $service..."
                docker stop "$service" 2>/dev/null || log_warning "Konnte $service nicht stoppen"
            fi
        done
    fi
    
    # Stoppe alle anderen laufenden Container (nicht-Coolify)
    local other_containers
    other_containers=$(docker ps -q | while read -r cid; do
        cname=$(docker inspect --format '{{.Name}}' "$cid" | sed 's/^\///')
        [[ "$cname" != coolify* ]] && echo "$cid"
    done)
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
        if docker ps --format '{{.Names}}' | grep -qx "$service"; then
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
    while read -r container; do
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
    done < <(docker ps -a --format '{{.Names}}' | grep -v "^coolify")

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

# KEEP IN SYNC: verify_ssh_before_reboot() existiert in allen 7 Update-Skripten
# (vps-update-auto.sh, vps-update-complete.sh, coolify/, dokploy/, vps-update.sh,
# vps-update-with-backup.sh, vps-update-simple.sh) — bei Änderungen ALLE pflegen.
verify_ssh_before_reboot() {
    log "=== SSH Pre-Flight Prüfung (vor Reboot) ==="

    # sshd-Binary im PATH? (cron/systemd haben evtl. kein /usr/sbin)
    command -v sshd >/dev/null 2>&1 || {
        log_error "sshd nicht im PATH — Reboot BLOCKIERT."
        log_error "Reparatur: Pfad prüfen oder /usr/sbin/sshd nutzen."
        return 1
    }

    # 1. sshd -t: Config-Syntax gültig? (short-circuit vor -T)
    if ! sshd -t >/dev/null 2>&1; then
        log_error "sshd-Config ungültig (sshd -t ≠ 0) — Reboot BLOCKIERT."
        log_error "Manuelle Prüfung: sshd -t"
        return 1
    fi

    # 2. sshd -T: effektiven Port ermitteln (auto-detect, NICHT hartkodiert 22)
    local ssh_ports
    if ! ssh_ports=$(sshd -T 2>/dev/null | awk '$1=="port"{print $2}' | sort -u); then
        log_error "sshd -T fehlgeschlagen — Reboot BLOCKIERT."
        return 1
    fi
    [[ -n "$ssh_ports" ]] || {
        log_error "Kein SSH-Port via sshd -T ermittelbar — Reboot BLOCKIERT."
        return 1
    }

    # 3. Lauscher-Check: jeder SSH-Port aktiv? (reuse ss -tlnp-Idiom)
    local listening
    listening=$(ss -tlnp 2>/dev/null | grep "LISTEN" | awk '{print $4}' | sed 's/.*://' | sort -un)
    local p
    for p in $ssh_ports; do
        grep -qx "$p" <<<"$listening" || {
            log_error "SSH-Port ${p} lauscht nicht — Reboot BLOCKIERT."
            log_error "Reparatur: systemctl status ssh.socket ssh.service"
            return 1
        }
    done

    # 4. ssh.socket is-enabled (Boot-Persistenz), String-Dispatch + ssh.service-Fallback
    local socket_state svc_state
    socket_state=$(systemctl is-enabled ssh.socket 2>/dev/null) || true
    case "$socket_state" in
        enabled|static) : ;;
        disabled|masked|not-found|"")
            svc_state=$(systemctl is-enabled ssh.service 2>/dev/null) || true
            case "$svc_state" in
                enabled|static)
                    log_warning "ssh.socket='${socket_state:-<leer>}' — ssh.service='${svc_state}' übernimmt Boot-Persistenz (OK)." ;;
                *)
                    log_error "ssh.socket='${socket_state:-<leer>}' und ssh.service='${svc_state:-<leer>}' — Reboot BLOCKIERT."
                    log_error "Reparatur: systemctl enable ssh.socket  ODER  systemctl enable ssh.service"
                    return 1 ;;
            esac ;;
        *)
            log_error "ssh.socket: unbekannter Zustand '${socket_state}' — Reboot BLOCKIERT."
            return 1 ;;
    esac

    log_success "SSH Pre-Flight OK (Port(s): $(echo "$ssh_ports" | tr '\n' ' '))"
    return 0
}

check_reboot() {
    if [[ -f /var/run/reboot-required ]]; then
        log_warning "NEUSTART ERFORDERLICH!"
        # SSH Pre-Flight: reboot-safe? Sonst gar nicht erst fragen (fail-fast, SUCCESS-mit-Caveat).
        if ! verify_ssh_before_reboot; then
            log_error "Reboot wegen SSH-Pre-Flight blockiert — System bleibt oben."
            log_error "SSH reparieren, dann manuell: reboot"
            return 0
        fi
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