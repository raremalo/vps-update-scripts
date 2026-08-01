#!/usr/bin/env bash
# ==============================================================
# VPS-Update-Script 2.2 – Ubuntu 24.04 LTS + Coolify + Docker
# Mit integrierter Backup-Funktion
# ==============================================================

set -euo pipefail
shopt -s nullglob

# -------------------- Konfigurierbare Variablen ----------------
LOG_DIR="${VPS_UPDATE_LOG_DIR:-/var/log/vps-updates}"
LOCK_FILE="/var/run/vps-update.lock"
DOCKER_STOP_TIMEOUT="${DOCKER_STOP_TIMEOUT:-30}"
HOLD_PKGS=(snapd ubuntu-advantage-tools landscape-common)

# Backup-Konfiguration
BACKUP_ENABLED="${VPS_UPDATE_BACKUP_ENABLED:-true}"
BACKUP_FUNCTIONS_PATH="/usr/local/lib/vps-script/backup-functions.sh"
# Bei Backup-Fehler abbrechen? (true zum Fortfahren, false zum Abbrechen)
CONTINUE_ON_BACKUP_FAIL="${VPS_UPDATE_ON_BACKUP_FAIL:-false}"
# ---------------------------------------------------------------

# Farben
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; NC='\033[0m'

mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/vps_update_$(date +%Y%m%d_%H%M%S).log"

log() { echo -e "${2-}${1}${NC}"; echo "[$(date '+%F %T')] ${1//${NC}/}" >>"$LOG_FILE"; }
err() { log "$*" "$RED"; }

cleanup() { rm -f "$LOCK_FILE"; }
trap cleanup EXIT

[[ $EUID -eq 0 ]] || { err "Dieses Script muss als root laufen!"; exit 1; }
exec 9>"$LOCK_FILE"
flock -n 9 || { err "Script läuft bereits (Lock: $LOCK_FILE)."; exit 1; }

# Backup-Funktionen einbinden (wenn Backups aktiviert sind)
if [[ "$BACKUP_ENABLED" != "false" ]]; then
    if [[ -f "$BACKUP_FUNCTIONS_PATH" ]]; then
        # shellcheck source=/dev/null
        source "$BACKUP_FUNCTIONS_PATH"
    else
        err "FEHLER: Backup-Funktionen nicht gefunden unter $BACKUP_FUNCTIONS_PATH"
        err "Bitte stellen Sie sicher, dass die Suite korrekt installiert ist."
        exit 1
    fi
fi

log "======== VPS-Update gestartet ========" "$GREEN"
log "Hostname: $(hostname) | Kernel: $(uname -r) | Uptime: $(uptime -p)" "$BLUE"

# Docker Autostart sicherstellen
AUTOSTART_SCRIPT="/usr/local/lib/vps-script/ensure-docker-autostart.sh"
if [[ -f "$AUTOSTART_SCRIPT" ]]; then
    log "Überprüfe Docker Autostart-Konfiguration..." "$BLUE"
    bash "$AUTOSTART_SCRIPT"
fi

# ---------- 0. Backup durchführen (wenn aktiviert) ----------
# Führe Backup durch, es sei denn, es ist explizit auf "false" gesetzt.
if [[ "$BACKUP_ENABLED" != "false" ]]; then
    if type -t perform_backup &>/dev/null; then
        if ! perform_backup; then
            if [[ "$CONTINUE_ON_BACKUP_FAIL" == "true" ]]; then
                log "WARNUNG: Backup fehlgeschlagen, fahre aber aufgrund der Konfiguration fort." "$YELLOW"
            else
                err "FEHLER: Backup fehlgeschlagen. Breche das Update ab."
                exit 1
            fi
        fi
    else
        err "FEHLER: Backup-Funktion 'perform_backup' nicht verfügbar."
        exit 1
    fi
else
    log "Backup explizit deaktiviert (VPS_UPDATE_BACKUP_ENABLED=false)." "$YELLOW"
fi

# ---------- 1. Docker + Coolify sicher anhalten ----------
if command -v docker &>/dev/null; then
  RUNNING=$(docker ps -q || true)
  if [[ -n $RUNNING ]]; then
    log "Stoppe $(( $(wc -l <<<"$RUNNING") )) Container (Timeout ${DOCKER_STOP_TIMEOUT}s) …" "$YELLOW"
    docker stop --time="$DOCKER_STOP_TIMEOUT" $RUNNING || log "Einige Container stoppten nicht sauber." "$YELLOW"
  fi
  docker stop coolify 2>/dev/null || true
  systemctl stop docker     || err "Docker ließ sich nicht stoppen"
else
  log "Docker nicht installiert – Schritt übersprungen." "$YELLOW"
fi

# ---------- 2. System-Updates ----------
log "Aktualisiere Paketlisten …" "$BLUE"
apt-get update -qq

SEC=$(apt list --upgradable 2>/dev/null | grep -ci security || true)
TOT=$(apt list --upgradable 2>/dev/null | tail -n +2 | wc -l)
log "Gefundene Updates: $TOT (davon $SEC Sicherheitsupdates)" "$BLUE"

if (( TOT )); then
  # Temporär blockierte Pakete halten
  apt-mark hold "${HOLD_PKGS[@]}" >/dev/null
  # Volles dist-upgrade, damit Kernel & Abhängigkeitswechsel abgedeckt sind
  DEBIAN_FRONTEND=noninteractive \
  apt-get -y dist-upgrade -o Dpkg::Options::="--force-confdef" \
                           -o Dpkg::Options::="--force-confold"
  apt-mark unhold "${HOLD_PKGS[@]}" >/dev/null
else
  log "System bereits aktuell." "$GREEN"
fi

# ---------- 3. Aufräumen ----------
log "Führe autoremove, autoclean & Snap-Cleanup aus …" "$BLUE"
apt-get -y autoremove
apt-get autoclean -qq
if command -v snap &>/dev/null; then
  snap list --all | awk '/disabled/{print $1,$3}' | \
     while read s r; do snap remove "$s" --revision="$r" || true; done
fi

# ---------- 4. Reboot-Entscheidung ----------
NEED_REBOOT=false
LATEST_KERNEL=$(dpkg-query -W -f='${Version}\n' "linux-image-$(uname -r | cut -d'-' -f1-2)" 2>/dev/null || echo "")
if [ -f /var/run/reboot-required ] || [[ -z $LATEST_KERNEL ]]; then
  NEED_REBOOT=true
fi

# KEEP IN SYNC: verify_ssh_before_reboot() existiert in allen 7 Update-Skripten
# (vps-update-auto.sh, vps-update-complete.sh, coolify/, dokploy/, vps-update.sh,
# vps-update-with-backup.sh, vps-update-simple.sh) — bei Änderungen ALLE pflegen.
verify_ssh_before_reboot() {
    log "=== SSH Pre-Flight Prüfung (vor Reboot) ===" "$BLUE"

    # sshd-Binary im PATH? (cron/systemd haben evtl. kein /usr/sbin)
    command -v sshd >/dev/null 2>&1 || {
        err "sshd nicht im PATH — Reboot BLOCKIERT."
        err "Reparatur: Pfad prüfen oder /usr/sbin/sshd nutzen."
        return 1
    }

    # 1. sshd -t: Config-Syntax gültig? (short-circuit vor -T)
    if ! sshd -t >/dev/null 2>&1; then
        err "sshd-Config ungültig (sshd -t ≠ 0) — Reboot BLOCKIERT."
        err "Manuelle Prüfung: sshd -t"
        return 1
    fi

    # 2. sshd -T: effektiven Port ermitteln (auto-detect, NICHT hartkodiert 22)
    local ssh_ports
    if ! ssh_ports=$(sshd -T 2>/dev/null | awk '$1=="port"{print $2}' | sort -u); then
        err "sshd -T fehlgeschlagen — Reboot BLOCKIERT."
        return 1
    fi
    [[ -n "$ssh_ports" ]] || {
        err "Kein SSH-Port via sshd -T ermittelbar — Reboot BLOCKIERT."
        return 1
    }

    # 3. Lauscher-Check: jeder SSH-Port aktiv? (reuse ss -tlnp-Idiom :786-793)
    local listening
    listening=$(ss -tlnp 2>/dev/null | grep "LISTEN" | awk '{print $4}' | sed 's/.*://' | sort -un)
    local p
    for p in $ssh_ports; do
        grep -qx "$p" <<<"$listening" || {
            err "SSH-Port ${p} lauscht nicht — Reboot BLOCKIERT."
            err "Reparatur: systemctl status ssh.socket ssh.service"
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
                    log "ssh.socket='${socket_state:-<leer>}' — ssh.service='${svc_state}' übernimmt Boot-Persistenz (OK)." "$BLUE" ;;
                *)
                    err "ssh.socket='${socket_state:-<leer>}' und ssh.service='${svc_state:-<leer>}' — Reboot BLOCKIERT."
                    err "Reparatur: systemctl enable ssh.socket  ODER  systemctl enable ssh.service"
                    return 1 ;;
            esac ;;
        *)
            err "ssh.socket: unbekannter Zustand '${socket_state}' — Reboot BLOCKIERT."
            return 1 ;;
    esac

    log "✓ SSH Pre-Flight OK (Port(s): $(echo "$ssh_ports" | tr '\n' ' '))" "$GREEN"
    return 0
}

if $NEED_REBOOT; then
  # SSH Pre-Flight: reboot-safe? Sonst nicht rebooten (Fall-through zu Section 5).
  if verify_ssh_before_reboot; then
    log "Reboot nötig – Container werden nach dem Neustart automatisch gestartet..." "$YELLOW"
    log "System startet in 10 s neu ..." "$YELLOW"
    sleep 10
    reboot
  else
    err "Reboot wegen SSH-Pre-Flight blockiert — System bleibt oben."
    err "SSH reparieren, dann manuell: reboot"
    # Klärend: Section 5 startet Services neu, obwohl ein Reboot nötig war (blockiert).
    log "Starte Services neu (Reboot war nötig, wurde aber blockiert)..." "$YELLOW"
  fi
fi

# ---------- 5. Services neu starten (nur wenn kein Reboot nötig) ----------
log "Kein Reboot nötig – starte Services neu..." "$BLUE"
systemctl start docker 2>/dev/null || err "Docker konnte nicht neu starten"
log "Warte 15s auf die Docker-Initialisierung..." "$BLUE"
sleep 15

# Docker Autostart nach Service-Neustart erneut sicherstellen
if [[ -f "$AUTOSTART_SCRIPT" ]]; then
    log "Konfiguriere Docker Autostart nach Service-Neustart..." "$BLUE"
    bash "$AUTOSTART_SCRIPT"
fi

log "Starte Coolify neu, um alle Projekte zu reaktivieren..." "$BLUE"
docker restart coolify 2>/dev/null || log "Coolify neustarten fehlgeschlagen." "$YELLOW"

log "======== Update abgeschlossen ========" "$GREEN"
