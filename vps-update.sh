#!/usr/bin/env bash
# ==============================================================
# VPS-Update-Script 2.0 – Ubuntu 24.04 LTS + Coolify + Docker
# ==============================================================

set -euo pipefail
shopt -s nullglob

# -------------------- Konfigurierbare Variablen ----------------
LOG_DIR="${VPS_UPDATE_LOG_DIR:-/var/log/vps-updates}"
LOCK_FILE="/var/run/vps-update.lock"
DOCKER_STOP_TIMEOUT="${DOCKER_STOP_TIMEOUT:-30}"
HOLD_PKGS=(snapd ubuntu-advantage-tools landscape-common)
# ---------------------------------------------------------------

# Farben
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; NC='\033[0m'

mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/vps_update_$(date +%Y%m%d_%H%M%S).log"

log() { echo -e "${2-}${1}${NC}"; echo "[$(date '+%F %T')] ${1//${NC}/}" >>"$LOG_FILE"; }
err() { log "$*" "$RED"; }

# ---- Compose/Container Helpers ----
has_compose_project() {
  docker compose config >/dev/null 2>&1
}

has_compose_service() {
  local svc="$1"
  docker compose config --services 2>/dev/null | grep -qx "$svc"
}

has_container() {
  local name="$1"
  docker ps -a --format '{{.Names}}' | grep -qx "$name"
}

cleanup() { rm -f "$LOCK_FILE"; }
trap cleanup EXIT

[[ $EUID -eq 0 ]] || { err "Dieses Script muss als root laufen!"; exit 1; }
exec 9>"$LOCK_FILE"
flock -n 9 || { err "Script läuft bereits (Lock: $LOCK_FILE)."; exit 1; }

log "======== VPS-Update gestartet ========" "$GREEN"
log "Hostname: $(hostname) | Kernel: $(uname -r) | Uptime: $(uptime -p)" "$BLUE"

# Docker Autostart sicherstellen
AUTOSTART_SCRIPT="/usr/local/lib/vps-script/ensure-docker-autostart.sh"
if [[ -f "$AUTOSTART_SCRIPT" ]]; then
    log "Überprüfe Docker Autostart-Konfiguration..." "$BLUE"
    bash "$AUTOSTART_SCRIPT"
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
        disabled|masked)
            err "ssh.socket ist '${socket_state}' — Reboot BLOCKIERT."
            err "Reparatur: systemctl enable ssh.socket"
            return 1 ;;
        not-found|"")
            svc_state=$(systemctl is-enabled ssh.service 2>/dev/null) || true
            case "$svc_state" in
                enabled|static) : ;;
                *)
                    err "ssh.socket fehlt und ssh.service='${svc_state:-<leer>}' — Reboot BLOCKIERT."
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

# Robust: Coolify-Stack starten mit Compose-Check und Fallback
start_coolify_stack() {
  if [[ ! -d "/data/coolify/source" ]]; then
    log "Coolify nicht installiert – überspringe Stack-Start." "$YELLOW"
    return 0
  fi
  log "Starte Coolify-Stack in korrekter Reihenfolge..." "$BLUE"
  cd /data/coolify/source || return 0
  if has_compose_project; then
    log "Starte DB/Redis..." "$BLUE"
    docker compose up -d coolify-db coolify-redis || log "Compose: DB/Redis Start meldete Fehler" "$YELLOW"
    sleep 10
    if has_compose_service "coolify-realtime"; then
      log "Starte Realtime (coolify-realtime)..." "$BLUE"
      docker compose up -d coolify-realtime || log "Compose: coolify-realtime meldete Fehler" "$YELLOW"
      sleep 5
    elif has_compose_service "soketi"; then
      log "Starte Legacy Realtime (soketi)..." "$BLUE"
      docker compose up -d soketi || log "Compose: soketi meldete Fehler" "$YELLOW"
      sleep 5
    else
      log "Kein Realtime-Service in Compose gefunden" "$YELLOW"
    fi
    log "Starte Coolify Core..." "$BLUE"
    docker compose up -d coolify || log "Compose: coolify meldete Fehler" "$YELLOW"
    sleep 10
    log "Starte Proxy..." "$BLUE"
    docker compose up -d coolify-proxy || log "Compose: proxy meldete Fehler" "$YELLOW"
  else
    log "Compose-Projekt ungültig – Fallback via docker start" "$YELLOW"
    docker start coolify-db coolify-redis 2>/dev/null || true
    sleep 10
    if has_container "coolify-realtime"; then
      docker start coolify-realtime 2>/dev/null || true
      sleep 5
    elif has_container "soketi"; then
      docker start soketi 2>/dev/null || true
      sleep 5
    fi
    docker start coolify 2>/dev/null || true
    sleep 10
    docker start coolify-proxy 2>/dev/null || true
  fi
  # Verifikation
  sleep 5
  for s in coolify-db coolify-redis coolify-realtime coolify coolify-proxy; do
    if docker ps --format '{{.Names}}' | grep -qx "$s"; then
      log "✓ $s läuft" "$GREEN"
    else
      log "⚠ $s läuft nicht" "$YELLOW"
    fi
  done
}

start_coolify_stack

log "======== Update abgeschlossen ========" "$GREEN"
