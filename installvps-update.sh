#!/usr/bin/env bash
# ==============================================================
# Installer für vps-update-Suite v2.1
# ==============================================================

set -euo pipefail

# Farben für die Ausgabe
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${2-}${1}${NC}"; }

# --- Pfad-Definitionen ---
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

# Zielpfade
BIN_DIR="/usr/local/bin"
LIB_DIR="/usr/local/lib/vps-script"
UPDATE_SCRIPT_DEST="$BIN_DIR/vps-update"
STATUS_SCRIPT_DEST="$BIN_DIR/vps-status"
BACKUP_FUNCTIONS_DEST="$LIB_DIR/backup-functions.sh"

# Quelldateien
UPDATE_SCRIPT_SRC="$SCRIPT_DIR/vps-update.sh"
UPDATE_WITH_BACKUP_SRC="$SCRIPT_DIR/vps-update-with-backup.sh"
BACKUP_FUNCTIONS_SRC="$SCRIPT_DIR/backup-functions.sh"
STATUS_SCRIPT_SRC="$SCRIPT_DIR/vps-status.sh"

# --- Vorab-Prüfungen ---
[[ $EUID -eq 0 ]] || { echo -e "${RED}Fehler: Bitte dieses Skript mit sudo oder als root ausführen.${NC}"; exit 1; }

for f in "$UPDATE_SCRIPT_SRC" "$UPDATE_WITH_BACKUP_SRC" "$BACKUP_FUNCTIONS_SRC" "$STATUS_SCRIPT_SRC"; do
    [[ -f "$f" ]] || { echo -e "${RED}Fehler: Quelldatei nicht gefunden: $(basename "$f")${NC}"; exit 1; }
done

echo -e "${BLUE}--- VPS Update Suite Installer ---${NC}"

# --- Interaktive Auswahl --- 
read -r -p "Möchten Sie die Version mit automatischer Backup-Funktion installieren? [Y/n] " REPLY
INSTALL_WITH_BACKUP=true
if [[ ${REPLY,,} == n* ]]; then
    INSTALL_WITH_BACKUP=false
fi

# --- Installation der Skripte ---
echo -e "\n${BLUE}Installiere Skripte...${NC}"

if $INSTALL_WITH_BACKUP; then
    echo "Installiere vps-update mit Backup-Funktion..."
    install -Dm755 "$UPDATE_WITH_BACKUP_SRC" "$UPDATE_SCRIPT_DEST"
    
    echo "Installiere Backup-Funktionsbibliothek..."
    install -d -m755 "$LIB_DIR"
    install -Dm644 "$BACKUP_FUNCTIONS_SRC" "$BACKUP_FUNCTIONS_DEST"
else
    echo "Installiere vps-update (Standard)..."
    install -Dm755 "$UPDATE_SCRIPT_SRC" "$UPDATE_SCRIPT_DEST"
fi

echo "Installiere vps-status..."
install -Dm755 "$STATUS_SCRIPT_SRC" "$STATUS_SCRIPT_DEST"

echo -e "${GREEN}✓ Skripte erfolgreich installiert.${NC}"

# --- System-Konfiguration ---
echo -e "\n${BLUE}Konfiguriere System...${NC}"

# Log-Verzeichnis
echo "Erstelle Log-Verzeichnis..."
install -d -m755 /var/log/vps-updates

# Systemd-Timer oder Cronjob
read -r -p "Systemd-Timer (empfohlen) statt Cron anlegen? [Y/n] " TIMER_REPLY
if [[ ${TIMER_REPLY,,} != n* ]]; then
    echo "Richte Systemd-Timer ein..."
    cat >/etc/systemd/system/vps-update.service <<'EOF'
[Unit]
Description=VPS – wöchentliches Update inkl. Docker/Coolify
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/vps-update
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=6
EOF

    cat >/etc/systemd/system/vps-update.timer <<'EOF'
[Unit]
Description=Starte vps-update jeden Sonntag 02:00

[Timer]
OnCalendar=Sun *-*-* 02:00:00
RandomizedDelaySec=30min
Persistent=true

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now vps-update.timer
    echo -e "${GREEN}✓ Systemd-Timer aktiviert (läuft jeden Sonntag ~02:00).${NC}"
else
    echo "Richte Cron-Job ein..."
    (crontab -l 2>/dev/null | grep -v -F "$UPDATE_SCRIPT_DEST"; echo "0 2 * * 0 PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin $UPDATE_SCRIPT_DEST") | crontab -
    echo -e "${GREEN}✓ Cron-Job eingerichtet (läuft jeden Sonntag 02:00).${NC}"
fi

# Logrotate
echo "Richte Log-Rotation ein..."
cat >/etc/logrotate.d/vps-update <<'EOF'
/var/log/vps-updates/vps_update_*.log {
    daily
    rotate 30
    missingok
    compress
    notifempty
    create 0644 root root
}
EOF

# Docker Autostart-Scripts installieren
echo "Installiere Docker Autostart-Scripts..."
AUTOSTART_SCRIPT_SRC="$SCRIPT_DIR/ensure-docker-autostart.sh"
AUTOSTART_SCRIPT_DEST="$LIB_DIR/ensure-docker-autostart.sh"
COOLIFY_AUTOSTART_SCRIPT_SRC="$SCRIPT_DIR/ensure-coolify-projects-autostart.sh"
COOLIFY_AUTOSTART_SCRIPT_DEST="$LIB_DIR/ensure-coolify-projects-autostart.sh"

if [[ -f "$AUTOSTART_SCRIPT_SRC" ]]; then
    install -Dm755 "$AUTOSTART_SCRIPT_SRC" "$AUTOSTART_SCRIPT_DEST"
    log "✓ Docker Autostart-Script installiert" "$GREEN"
else
    log "⚠ Docker Autostart-Script nicht gefunden - übersprungen" "$YELLOW"
fi

if [[ -f "$COOLIFY_AUTOSTART_SCRIPT_SRC" ]]; then
    install -Dm755 "$COOLIFY_AUTOSTART_SCRIPT_SRC" "$COOLIFY_AUTOSTART_SCRIPT_DEST"
    log "✓ Coolify Projekte Autostart-Script installiert" "$GREEN"
else
    log "⚠ Coolify Projekte Autostart-Script nicht gefunden - übersprungen" "$YELLOW"
fi

echo -e "\n${GREEN}Installation abgeschlossen!${NC}"
echo -e "Sie können die Skripte jetzt verwenden:\n- Manuelles Update: ${YELLOW}sudo vps-update${NC}\n- Status prüfen:    ${YELLOW}sudo vps-status${NC}"

