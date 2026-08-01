#!/usr/bin/env bash
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

    # Atomic lock
    exec 9>"$LOCKFILE"
    flock -n 9 || { log "ERROR" "Script läuft bereits (Lock: $LOCKFILE)"; exit 1; }
    
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
    if docker ps --format '{{.Names}}' | grep -q "coolify"; then
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
    
    if docker ps --format '{{.Names}}' | grep -q "coolify"; then
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
    if ! docker ps -a --format '{{.Names}}' | grep -q "coolify"; then
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
    
    if docker ps --format '{{.Names}}' | grep -qx "coolify-db"; then
        log "SUCCESS" "✓ Coolify Database läuft"
    else
        log "WARNING" "✗ Coolify Database läuft nicht!"
    fi
    
    if docker ps --format '{{.Names}}' | grep -qx "coolify-redis"; then
        log "SUCCESS" "✓ Coolify Redis läuft"
    else
        log "WARNING" "✗ Coolify Redis läuft nicht!"
    fi
    
    if docker ps --format '{{.Names}}' | grep -qx "coolify-realtime"; then
        log "SUCCESS" "✓ Coolify Soketi (Realtime) läuft"
    else
        log "ERROR" "✗ Coolify Soketi läuft nicht! KRITISCH!"
    fi
    
    if docker ps --format '{{.Names}}' | grep -qx "coolify"; then
        log "SUCCESS" "✓ Coolify Hauptservice läuft"
    else
        log "ERROR" "✗ Coolify Hauptservice läuft nicht!"
    fi
    
    if docker ps --format '{{.Names}}' | grep -qx "coolify-proxy"; then
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

# KEEP IN SYNC: verify_ssh_before_reboot() existiert in allen 7 Update-Skripten
# (vps-update-auto.sh, vps-update-complete.sh, coolify/, dokploy/, vps-update.sh,
# vps-update-with-backup.sh, vps-update-simple.sh) — bei Änderungen ALLE pflegen.
verify_ssh_before_reboot() {
    log "INFO" "=== SSH Pre-Flight Prüfung (vor Reboot) ==="

    # sshd-Binary im PATH? (cron/systemd haben evtl. kein /usr/sbin)
    command -v sshd >/dev/null 2>&1 || {
        log "ERROR" "sshd nicht im PATH — Reboot BLOCKIERT."
        log "ERROR" "Reparatur: Pfad prüfen oder /usr/sbin/sshd nutzen."
        return 1
    }

    # 1. sshd -t: Config-Syntax gültig? (short-circuit vor -T)
    if ! sshd -t >/dev/null 2>&1; then
        log "ERROR" "sshd-Config ungültig (sshd -t ≠ 0) — Reboot BLOCKIERT."
        log "ERROR" "Manuelle Prüfung: sshd -t"
        return 1
    fi

    # 2. sshd -T: effektiven Port ermitteln (auto-detect, NICHT hartkodiert 22)
    local ssh_ports
    if ! ssh_ports=$(sshd -T 2>/dev/null | awk '$1=="port"{print $2}' | sort -u); then
        log "ERROR" "sshd -T fehlgeschlagen — Reboot BLOCKIERT."
        return 1
    fi
    [[ -n "$ssh_ports" ]] || {
        log "ERROR" "Kein SSH-Port via sshd -T ermittelbar — Reboot BLOCKIERT."
        return 1
    }

    # 3. Lauscher-Check: jeder SSH-Port aktiv? (reuse ss -tlnp-Idiom :786-793)
    local listening
    listening=$(ss -tlnp 2>/dev/null | grep "LISTEN" | awk '{print $4}' | sed 's/.*://' | sort -un)
    local p
    for p in $ssh_ports; do
        grep -qx "$p" <<<"$listening" || {
            log "ERROR" "SSH-Port ${p} lauscht nicht — Reboot BLOCKIERT."
            log "ERROR" "Reparatur: systemctl status ssh.socket ssh.service"
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
                    log "INFO" "ssh.socket='${socket_state:-<leer>}' — ssh.service='${svc_state}' übernimmt Boot-Persistenz (OK)." ;;
                *)
                    log "ERROR" "ssh.socket='${socket_state:-<leer>}' und ssh.service='${svc_state:-<leer>}' — Reboot BLOCKIERT."
                    log "ERROR" "Reparatur: systemctl enable ssh.socket  ODER  systemctl enable ssh.service"
                    return 1 ;;
            esac ;;
        *)
            log "ERROR" "ssh.socket: unbekannter Zustand '${socket_state}' — Reboot BLOCKIERT."
            return 1 ;;
    esac

    log "SUCCESS" "SSH Pre-Flight OK (Port(s): $(echo "$ssh_ports" | tr '\n' ' '))"
    return 0
}

check_reboot_required() {
    log "INFO" "Prüfe ob Neustart erforderlich..."
    
    if [[ -f /var/run/reboot-required ]]; then
        log "WARNING" "=== NEUSTART ERFORDERLICH ==="
        log "WARNING" "Gründe:"
        while read -r pkg; do
            log "WARNING" "  - $pkg"
        done < <(cat /var/run/reboot-required.pkgs 2>/dev/null)
        
        # SSH Pre-Flight: reboot-safe? Sonst blockieren (SUCCESS-mit-Caveat).
        if ! verify_ssh_before_reboot; then
            log "ERROR" "Reboot wegen SSH-Pre-Flight blockiert — System bleibt oben."
            log "ERROR" "SSH reparieren, dann manuell: reboot"
            return 0
        fi

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
