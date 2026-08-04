#!/usr/bin/env bash
# ==============================================================
# Installer für vps-update-Suite v3.0
# Mit Auto-Detection für Coolify und Dokploy
# ==============================================================

set -euo pipefail

# Farben
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${2-}${1}${NC}"; }

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

# Zielpfade
BIN_DIR="/usr/local/bin"
LIB_DIR="/usr/local/lib/vps-script"

# --- Root-Check ---
[[ $EUID -eq 0 ]] || { 
    log "Fehler: Bitte als root ausführen (sudo)" "$RED"
    exit 1
}

echo -e "${BLUE}╔════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║  VPS Update Suite Installer v3.0              ║${NC}"
echo -e "${BLUE}║  Auto-Detection: Coolify & Dokploy            ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════╝${NC}"
echo ""

# --- System-Erkennung ---
log "Erkenne Deployment-System..." "$BLUE"

DETECTED="none"
if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "coolify"; then
    DETECTED="coolify"
    log "✓ Coolify erkannt" "$GREEN"
elif docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "dokploy"; then
    DETECTED="dokploy"
    log "✓ Dokploy erkannt" "$GREEN"
else
    log "⚠ Kein System erkannt (wird trotzdem installiert)" "$YELLOW"
fi

echo ""

# --- Installation ---
log "Installiere Skripte..." "$BLUE"

# Verzeichnisse erstellen
install -d -m755 "$LIB_DIR"
install -d -m755 /var/log

# Prüfe ob Auto-Detect Scripts vorhanden sind
if [[ -f "$SCRIPT_DIR/vps-update-auto.sh" ]]; then
    # MODERNE INSTALLATION
    log "→ vps-update-auto (mit Auto-Detection)" "$GREEN"
    install -Dm755 "$SCRIPT_DIR/vps-update-auto.sh" "$BIN_DIR/vps-update"
    
    log "→ ensure-docker-autostart-auto" "$GREEN"
    install -Dm755 "$SCRIPT_DIR/ensure-docker-autostart-auto.sh" "$LIB_DIR/ensure-docker-autostart-auto.sh"

    # Symlink für Kompatibilität (vps-update.sh/vps-update-with-backup.sh referenzieren diesen Pfad)
    ln -sf "$LIB_DIR/ensure-docker-autostart-auto.sh" "$LIB_DIR/ensure-docker-autostart.sh"
    log "  → Symlink: ensure-docker-autostart.sh → ensure-docker-autostart-auto.sh" "$GREEN"

    # B1: Die Unit erwartet ExecStart unter /usr/local/bin — der Installer hat
    # dorthin nie installiert (203/EXEC auf allen sechs Hosts, von Hand
    # entschärft). Additiv per Symlink, die Unit-Datei bleibt unverändert.
    ln -sf "$LIB_DIR/ensure-docker-autostart-auto.sh" "$BIN_DIR/ensure-docker-autostart-auto.sh"
    log "  → Symlink: $BIN_DIR/ensure-docker-autostart-auto.sh → $LIB_DIR/" "$GREEN"

    # Systemd Service
    if [[ -f "$SCRIPT_DIR/docker-autostart-auto.service" ]]; then
        log "→ Autostart Service" "$GREEN"
        install -Dm644 "$SCRIPT_DIR/docker-autostart-auto.service" "/etc/systemd/system/docker-autostart-auto.service"
        # B1: eine Unit, deren ExecStart nicht auflösbar ist, wird nicht aktiviert
        if ! test -x "$BIN_DIR/ensure-docker-autostart-auto.sh"; then
            log "✗ $BIN_DIR/ensure-docker-autostart-auto.sh ist nicht ausführbar — Abbruch vor systemctl enable" "$RED"
            exit 1
        fi
        systemctl daemon-reload
        systemctl enable docker-autostart-auto.service
        log "  ✓ Service aktiviert" "$GREEN"
    fi
else
    # LEGACY INSTALLATION
    log "⚠ Auto-Detect Scripts nicht gefunden - Legacy-Modus" "$YELLOW"
    
    if [[ -f "$SCRIPT_DIR/vps-update-complete.sh" ]]; then
        install -Dm755 "$SCRIPT_DIR/vps-update-complete.sh" "$BIN_DIR/vps-update"
        log "→ vps-update-complete (Legacy)" "$YELLOW"
    else
        log "✗ Keine Update-Scripts gefunden!" "$RED"
        exit 1
    fi
fi

# B2: vps-status ist verpflichtend. Eine fehlende Quelldatei ist ein
# Repo-Defekt, kein Zustand, den ein Installer still hinnehmen darf —
# genau so lief vmd185359 jahrelang ohne vps-status.
if [[ ! -f "$SCRIPT_DIR/vps-status.sh" ]]; then
    log "✗ vps-status.sh fehlt im Quellverzeichnis — Abbruch (Repo-Defekt)" "$RED"
    exit 1
fi
log "→ vps-status" "$GREEN"
install -Dm755 "$SCRIPT_DIR/vps-status.sh" "$BIN_DIR/vps-status"

# B2: backup-functions.sh gehört zum Zielzustand — vps-update-with-backup.sh
# erwartet sie unter $LIB_DIR und bricht ohne sie mit Exit 1 ab. Heute fehlt
# sie auf 5 von 6 Hosts; „auf einem vorhanden, auf fünf nicht" ist kein
# definierter Zustand. Wird die Datei in Phase C entfernt, entfällt diese
# Zeile im selben Commit.
if [[ ! -f "$SCRIPT_DIR/backup-functions.sh" ]]; then
    log "✗ backup-functions.sh fehlt im Quellverzeichnis — Abbruch (Repo-Defekt)" "$RED"
    exit 1
fi
log "→ backup-functions.sh" "$GREEN"
install -Dm644 "$SCRIPT_DIR/backup-functions.sh" "$LIB_DIR/backup-functions.sh"

log "✓ Scripts installiert" "$GREEN"

# --- Timer konfigurieren ---
# B0: Der Zustandswechsel „Timer aktiv" hängt nicht mehr an einem Prompt mit
# Default JA. Der Sollwert kommt aus VPS_ENABLE_TIMER (yes|no); ohne Wert und
# ohne Terminal bricht der Installer ab, statt eine Annahme zu treffen.
# „no" schreibt Service- und Timer-Datei trotzdem — der Zielzustand soll
# vollständig sein —, aktiviert aber nichts und deaktiviert nichts Bestehendes
# (ein Installer darf keinen Zustand abschalten, den er nicht angeschaltet hat).
echo ""
TIMER_CHOICE="${VPS_ENABLE_TIMER:-}"
case "$TIMER_CHOICE" in
    yes|no)
        log "→ Timer-Sollwert aus VPS_ENABLE_TIMER: ${TIMER_CHOICE}" "$BLUE"
        ;;
    ?*)
        log "Fehler: VPS_ENABLE_TIMER='${TIMER_CHOICE}' ist ungültig (erlaubt: yes|no)" "$RED"
        exit 1
        ;;
    *)
        if [[ ! -t 0 ]]; then
            log "Fehler: kein Terminal und VPS_ENABLE_TIMER nicht gesetzt." "$RED"
            log "Aufruf: VPS_ENABLE_TIMER=yes|no sudo -E bash installvps-update.sh" "$RED"
            exit 1
        fi
        # Interaktiver Rückfall: Default ist NEIN — nur ein explizites y aktiviert
        read -r -p "Automatische wöchentliche Updates aktivieren? [y/N] " REPLY
        if [[ ${REPLY,,} == y* ]]; then
            TIMER_CHOICE="yes"
        else
            TIMER_CHOICE="no"
        fi
        ;;
esac

log "→ Schreibe Systemd-Units (Service + Timer)..." "$GREEN"

cat > /etc/systemd/system/vps-update.service <<'EOF'
[Unit]
Description=VPS Update (Auto-Detection Coolify/Dokploy)
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/vps-update
StandardOutput=journal
EOF

cat > /etc/systemd/system/vps-update.timer <<'EOF'
[Unit]
Description=Wöchentliches VPS Update (Sonntag 02:00)

[Timer]
OnCalendar=Sun *-*-* 02:00:00
RandomizedDelaySec=30min
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
if [[ "$TIMER_CHOICE" == "yes" ]]; then
    systemctl enable vps-update.timer
    systemctl start vps-update.timer
    log "✓ Timer aktiviert (Sonntag 02:00)" "$GREEN"
else
    log "→ Timer NICHT aktiviert (Sollwert: no) — Dateien liegen bereit," "$YELLOW"
    log "  eine bestehende Aktivierung bleibt unangetastet." "$YELLOW"
fi

# --- Logrotate ---
log "→ Konfiguriere Log-Rotation..." "$GREEN"
cat > /etc/logrotate.d/vps-update <<'EOF'
/var/log/vps-update.log {
    daily
    rotate 30
    missingok
    compress
    notifempty
}
EOF

# --- Fertig ---
echo ""
log "╔════════════════════════════════════════════════╗" "$GREEN"
log "║  Installation erfolgreich!                    ║" "$GREEN"
log "╚════════════════════════════════════════════════╝" "$GREEN"
echo ""
log "Verwendung:" "$BLUE"
log "  Update:        ${YELLOW}sudo vps-update${NC}"
log "  Status:        ${YELLOW}sudo vps-status${NC}"
log "  Timer Status:  ${YELLOW}systemctl status vps-update.timer${NC}"
echo ""
log "System:          ${YELLOW}$DETECTED${NC}"
