#!/usr/bin/env bash
# ==============================================================
# Coolify Projekte Autostart-Konfiguration
# Stellt sicher, dass alle Coolify Projekte nach einem Reboot automatisch starten
# ==============================================================

set -euo pipefail

# Farben
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${2-}${1}${NC}"; }

# Prüfe ob Docker und Coolify installiert sind
if ! command -v docker &>/dev/null; then
    log "Docker ist nicht installiert - überspringe Coolify Projekte Autostart" "$YELLOW"
    exit 0
fi

if ! docker ps -a --format '{{.Names}}' | grep -q "^coolify$"; then
    log "Coolify ist nicht installiert - überspringe Coolify Projekte Autostart" "$YELLOW"
    exit 0
fi

log "Konfiguriere Coolify Projekte Autostart..." "$BLUE"

# Coolify Traefik Container (für Reverse Proxy)
if docker ps -a --format '{{.Names}}' | grep -q "^coolify-traefik$"; then
    log "Coolify Traefik gefunden - konfiguriere Autostart..." "$BLUE"
    docker update --restart=unless-stopped coolify-traefik
    log "✓ Coolify Traefik Autostart aktiviert" "$GREEN"
fi

# Coolify Realtime Container (für Live Updates)
if docker ps -a --format '{{.Names}}' | grep -q "^coolify-realtime$"; then
    log "Coolify Realtime gefunden - konfiguriere Autostart..." "$BLUE"
    docker update --restart=unless-stopped coolify-realtime
    log "✓ Coolify Realtime Autostart aktiviert" "$GREEN"
fi

# Alle Coolify Projekte Container finden und konfigurieren
log "Suche nach Coolify Projekten..." "$BLUE"

# Container mit Coolify Labels finden
COOLIFY_PROJECTS=$(docker ps -a --filter "label=coolify.managed=true" --format '{{.Names}}' || true)

if [[ -n "$COOLIFY_PROJECTS" ]]; then
    log "Gefundene Coolify Projekte:" "$GREEN"
    echo "$COOLIFY_PROJECTS" | while read -r project_name; do
        if [[ -n "$project_name" ]]; then
            log "  - $project_name" "$BLUE"
            docker update --restart=unless-stopped "$project_name"
            log "    ✓ Autostart aktiviert" "$GREEN"
        fi
    done
else
    log "Keine Coolify Projekte gefunden" "$YELLOW"
fi

# Alternative: Alle Container mit restart policy konfigurieren
log "Konfiguriere alle verbleibenden Container auf Autostart..." "$BLUE"
docker ps -a --format '{{.Names}}' | while read -r container_name; do
    if [[ -n "$container_name" ]]; then
        # Überspringe System Container
        if [[ "$container_name" == "coolify" ]] || [[ "$container_name" == "coolify-traefik" ]] || [[ "$container_name" == "coolify-realtime" ]]; then
            continue
        fi
        
        # Prüfe ob es ein Projekt Container ist
        if docker inspect "$container_name" --format='{{.Config.Labels}}' 2>/dev/null | grep -q "coolify"; then
            docker update --restart=unless-stopped "$container_name"
            log "  ✓ $container_name Autostart aktiviert" "$GREEN"
        fi
    fi
done

log "Coolify Projekte Autostart-Konfiguration abgeschlossen" "$GREEN"

# Status anzeigen
log "Aktueller Status der Container:" "$BLUE"
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.RestartPolicy}}" | grep -E "(coolify|PROJECT)" || docker ps --format "table {{.Names}}\t{{.Status}}\t{{.RestartPolicy}}"