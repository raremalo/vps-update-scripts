#!/usr/bin/env bash
# ==============================================================
# Docker Autostart-Konfiguration für VPS-Update-Script
# Stellt sicher, dass Docker und Coolify nach einem Reboot automatisch starten
# ==============================================================

set -euo pipefail

# Farben
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${2-}${1}${NC}"; }

# Prüfe ob Docker installiert ist
if ! command -v docker &>/dev/null; then
    log "Docker ist nicht installiert - überspringe Autostart-Konfiguration" "$YELLOW"
    exit 0
fi

log "Konfiguriere Docker Autostart..." "$BLUE"

# Docker Service aktivieren
if systemctl is-enabled docker &>/dev/null; then
    log "✓ Docker Service ist bereits für Autostart konfiguriert" "$GREEN"
else
    log "Aktiviere Docker Service für Autostart..." "$BLUE"
    systemctl enable docker
    log "✓ Docker Service Autostart aktiviert" "$GREEN"
fi

# Coolify Container auf Autostart prüfen
if docker ps -a --format '{{.Names}}' | grep -q "^coolify$"; then
    log "Coolify Container gefunden - prüfe Autostart-Konfiguration..." "$BLUE"
    
    # Prüfe ob Coolify Container restart policy hat
    RESTART_POLICY=$(docker inspect coolify --format='{{.HostConfig.RestartPolicy.Name}}' 2>/dev/null || echo "none")
    
    if [[ "$RESTART_POLICY" == "always" ]] || [[ "$RESTART_POLICY" == "unless-stopped" ]]; then
        log "✓ Coolify Container hat bereits Autostart: $RESTART_POLICY" "$GREEN"
    else
        log "Aktualisiere Coolify Container auf Autostart..." "$YELLOW"
        docker update --restart=unless-stopped coolify
        log "✓ Coolify Container Autostart aktiviert" "$GREEN"
    fi
else
    log "Coolify Container nicht gefunden - überspringe Coolify Autostart-Konfiguration" "$YELLOW"
fi

# Andere wichtige Container auf Autostart prüfen
log "Prüfe weitere Container auf Autostart-Konfiguration..." "$BLUE"
docker ps -a --format '{{.Names}} {{.Status}}' | while read -r name status; do
    # Überspringe coolify und bereits konfigurierte Container
    if [[ "$name" == "coolify" ]]; then
        continue
    fi
    
    # Prüfe restart policy
    RESTART_POLICY=$(docker inspect "$name" --format='{{.HostConfig.RestartPolicy.Name}}' 2>/dev/null || echo "none")
    
    if [[ "$RESTART_POLICY" != "always" ]] && [[ "$RESTART_POLICY" != "unless-stopped" ]]; then
        log "Aktualisiere Container $name auf Autostart..." "$YELLOW"
        docker update --restart=unless-stopped "$name" 2>/dev/null || \
            log "⚠ Konnte Autostart für $name nicht aktivieren" "$YELLOW"
    fi
done

log "Docker Autostart-Konfiguration abgeschlossen" "$GREEN"

# Coolify Projekte Autostart konfigurieren
COOLIFY_SCRIPT="/usr/local/lib/vps-script/ensure-coolify-projects-autostart.sh"
if [[ -f "$COOLIFY_SCRIPT" ]]; then
    log "Konfiguriere Coolify Projekte Autostart..." "$BLUE"
    bash "$COOLIFY_SCRIPT"
fi