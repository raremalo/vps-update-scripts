#!/usr/bin/env bash
# Debug Script für Container Restart Policy Problem

set -euo pipefail

# Farben
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${2-}${1}${NC}"; }

log "======== DEBUG: Container Restart Policies ========" "$GREEN"

# Test 1: Docker Befehle
log "Test 1: Docker ps -a" "$BLUE"
docker ps -a --format '{{.Names}}' || { log "FEHLER bei docker ps" "$RED"; exit 1; }

log "\nTest 2: Mapfile Test" "$BLUE"
mapfile -t CONTAINERS < <(docker ps -a --format '{{.Names}}' 2>/dev/null || true)
log "Anzahl Container in Array: ${#CONTAINERS[@]}" "$YELLOW"

log "\nTest 3: Array Inhalt" "$BLUE"
for i in "${!CONTAINERS[@]}"; do
    log "Container[$i]: '${CONTAINERS[$i]}'" "$YELLOW"
done

log "\nTest 4: Einzelne Container prüfen" "$BLUE"
for container_name in "${CONTAINERS[@]}"; do
    if [[ -n "$container_name" ]]; then
        log "Prüfe Container: $container_name" "$YELLOW"
        
        # Test docker inspect
        if CURRENT_RESTART=$(docker inspect "$container_name" --format='{{.HostConfig.RestartPolicy.Name}}' 2>/dev/null); then
            log "  Restart Policy: $CURRENT_RESTART" "$GREEN"
        else
            log "  FEHLER beim Inspect von $container_name" "$RED"
        fi
        
        # Test docker update (dry run)
        if [[ "$CURRENT_RESTART" != "unless-stopped" ]] && [[ "$CURRENT_RESTART" != "always" ]]; then
            log "  Würde setzen: $container_name -> unless-stopped" "$BLUE"
        else
            log "  Bereits konfiguriert: $container_name ($CURRENT_RESTART)" "$GREEN"
        fi
    else
        log "Leerer Container Name gefunden!" "$RED"
    fi
done

log "\n======== DEBUG Abgeschlossen ========" "$GREEN"