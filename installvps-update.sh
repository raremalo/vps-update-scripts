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
if docker ps -a 2>/dev/null | grep -q "coolify"; then
    DETECTED="coolify"
    log "✓ Coolify erkannt" "$GREEN"
elif docker ps -a 2>/dev/null | grep -q "dokploy"; then
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
    
    # Systemd Service
    if [[ -f "$SCRIPT_DIR/docker-autostart-auto.service" ]]; then
        log "→ Autostart Service" "$GREEN"
        install -Dm644 "$SCRIPT_DIR/docker-autostart-auto.service" "/etc/systemd/system/docker-autostart-auto.service"
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

# Status-Script (optional)
if [[ -f "$SCRIPT_DIR/vps-status.sh" ]]; then
    log "→ vps-status" "$GREEN"
    install -Dm755 "$SCRIPT_DIR/vps-status.sh" "$BIN_DIR/vps-status"
fi

log "✓ Scripts installiert" "$GREEN"

# --- Timer konfigurieren ---
echo ""
read -r -p "Automatische wöchentliche Updates aktivieren? [Y/n] " REPLY
if [[ ${REPLY,,} != n* ]]; then
    log "→ Richte Systemd-Timer ein..." "$GREEN"
    
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
    systemctl enable vps-update.timer
    systemctl start vps-update.timer
    
    log "✓ Timer aktiviert (Sonntag 02:00)" "$GREEN"
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
