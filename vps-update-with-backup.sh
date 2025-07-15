#!/usr/bin/env bash
# ==============================================================
# VPS-Update-Script 2.2 – Ubuntu 24.04 LTS + Coolify + Docker
# Mit integrierter Backup-Funktion
# ==============================================================

set -euo pipefail
shopt -s nullglob

# -------------------- Konfigurierbare Variablen ----------------
LOG_DIR="${VPS_UPDATE_LOG_DIR:-/var/log/vps-updates}"
LOCK_FILE="/tmp/vps_update.lock"
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
[[ ! -e $LOCK_FILE ]] || { err "Lock-File existiert – Script läuft bereits."; exit 1; }
touch "$LOCK_FILE"

# Backup-Funktionen einbinden (wenn Backups aktiviert sind)
if [[ "$BACKUP_ENABLED" == "true" ]]; then
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

# ---------- 0. Backup durchführen (wenn aktiviert) ----------
if [[ "$BACKUP_ENABLED" == "true" ]]; then
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
    log "Backup deaktiviert (VPS_UPDATE_BACKUP_ENABLED != true)." "$YELLOW"
fi

# ---------- 1. Docker + Coolify sicher anhalten ----------
if command -v docker &>/dev/null; then
  RUNNING=$(docker ps -q || true)
  if [[ -n $RUNNING ]]; then
    log "Stoppe $(( $(wc -l <<<"$RUNNING") )) Container (Timeout ${DOCKER_STOP_TIMEOUT}s) …" "$YELLOW"
    docker stop --time="$DOCKER_STOP_TIMEOUT" $RUNNING || log "Einige Container stoppten nicht sauber." "$YELLOW"
  fi
  systemctl stop coolify 2>/dev/null || true
  systemctl stop docker     || err "Docker ließ sich nicht stoppen"
else
  log "Docker nicht installiert – Schritt übersprungen." "$YELLOW"
fi

# ---------- 2. System-Updates ----------
log "Aktualisiere Paketlisten …" "$BLUE"
apt-get update -qq

SEC=$(apt list --upgradable 2>/dev/null | grep -ci security)
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

# ---------- 4. Services neu starten ----------
systemctl start docker 2>/dev/null || err "Docker konnte nicht neu starten"
systemctl start coolify 2>/dev/null || true

# ---------- 5. Reboot-Entscheidung ----------
NEED_REBOOT=false
LATEST_KERNEL=$(dpkg-query -W -f='${Version}\n' "linux-image-$(uname -r | cut -d'-' -f1-2)" 2>/dev/null || echo "")
if [ -f /var/run/reboot-required ] || [[ -z $LATEST_KERNEL ]]; then
  NEED_REBOOT=true
fi

if $NEED_REBOOT; then
  log "Reboot nötig – System startet in 10 s …" "$YELLOW"
  sleep 10
  reboot
fi

log "======== Update abgeschlossen – kein Reboot nötig ========" "$GREEN"

