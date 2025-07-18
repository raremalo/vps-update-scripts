#!/usr/bin/env bash
# ==============================================================
# Fix Container Restart Policies Script
# Basierend auf der Analyse der script.txt - setzt alle Container auf unless-stopped
# ==============================================================

set -eo pipefail

# Farben
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${2-}${1}${NC}"; }

# Prüfe ob Docker läuft
if ! command -v docker &>/dev/null; then
    log "Docker ist nicht installiert!" "$RED"
    exit 1
fi

if ! docker info &>/dev/null; then
    log "Docker läuft nicht - starte Docker Service..." "$YELLOW"
    systemctl start docker
    sleep 5
fi

log "======== Container Restart Policies Fix ========" "$GREEN"
log "Basierend auf script.txt Analyse - alle Container auf unless-stopped setzen" "$BLUE"

# Alle Container auflisten und restart policies prüfen/setzen
log "Analysiere alle Container..." "$BLUE"

# Alle Container automatisch erkennen und konfigurieren
log "Erkenne alle vorhandenen Container..." "$BLUE"

# Zähler für Statistik
TOTAL_CONTAINERS=0
CONFIGURED_CONTAINERS=0
ALREADY_CONFIGURED=0
FAILED_CONTAINERS=0

# Alle Container in Array einlesen (vermeidet Subshell-Problem)
mapfile -t CONTAINERS < <(docker ps -a --format '{{.Names}}' 2>/dev/null || true)

# Prüfe ob Container gefunden wurden
if [[ ${#CONTAINERS[@]} -eq 0 ]] || [[ -z "${CONTAINERS[0]:-}" ]]; then
    log "Keine Container gefunden!" "$YELLOW"
    log "Script beendet." "$GREEN"
    exit 0
fi

log "Gefundene Container: ${#CONTAINERS[@]}" "$BLUE"

# Alle Container durchgehen
log "Starte Container-Verarbeitung..." "$BLUE"
for container_name in "${CONTAINERS[@]}"; do
    if [[ -n "$container_name" ]]; then
        log "Verarbeite: $container_name" "$YELLOW"
        TOTAL_CONTAINERS=$((TOTAL_CONTAINERS + 1))
        
        # Restart Policy prüfen
        CURRENT_RESTART="none"
        if CURRENT_RESTART=$(docker inspect "$container_name" --format='{{.HostConfig.RestartPolicy.Name}}' 2>/dev/null); then
            log "  Aktuelle Policy: $CURRENT_RESTART" "$BLUE"
        else
            log "  Fehler beim Lesen der Policy" "$RED"
            CURRENT_RESTART="none"
        fi
        
        # Policy setzen falls nötig
        if [[ "$CURRENT_RESTART" != "unless-stopped" ]] && [[ "$CURRENT_RESTART" != "always" ]]; then
            log "  Setze $container_name: $CURRENT_RESTART → unless-stopped" "$YELLOW"
            if docker update --restart=unless-stopped "$container_name" >/dev/null 2>&1; then
                log "    ✓ $container_name erfolgreich konfiguriert" "$GREEN"
                CONFIGURED_CONTAINERS=$((CONFIGURED_CONTAINERS + 1))
            else
                log "    ⚠ $container_name Konfiguration fehlgeschlagen" "$RED"
                FAILED_CONTAINERS=$((FAILED_CONTAINERS + 1))
            fi
        else
            log "  ✓ $container_name bereits konfiguriert ($CURRENT_RESTART)" "$GREEN"
            ALREADY_CONFIGURED=$((ALREADY_CONFIGURED + 1))
        fi
    fi
done
log "Container-Verarbeitung abgeschlossen" "$GREEN"

# Statistik anzeigen
log "\n======== Konfiguration Abgeschlossen ========" "$GREEN"
log "Gesamt Container: $TOTAL_CONTAINERS" "$BLUE"
log "Neu konfiguriert: $CONFIGURED_CONTAINERS" "$GREEN"
log "Bereits konfiguriert: $ALREADY_CONFIGURED" "$GREEN"
log "Fehlgeschlagen: $FAILED_CONTAINERS" "$([ $FAILED_CONTAINERS -eq 0 ] && echo "$GREEN" || echo "$RED")"

# Finaler Status-Report
log "\n======== Finaler Status Report ========" "$GREEN"
log "Container Status und Restart Policies:" "$BLUE"
echo "---------------------------------------- --------------- --------------------"
echo "CONTAINER                                STATUS          RESTART POLICY"
echo "---------------------------------------- --------------- --------------------"

for name in "${CONTAINERS[@]}"; do
    if [[ -n "$name" ]]; then
        STATUS=$(docker inspect --format '{{.State.Status}}' "$name" 2>/dev/null || echo "unknown")
        RESTART_POLICY=$(docker inspect --format '{{.HostConfig.RestartPolicy.Name}}' "$name" 2>/dev/null || echo "unknown")
        printf "%-40s %-15s %-20s\n" "$name" "$STATUS" "$RESTART_POLICY" 2>/dev/null || echo "$name $STATUS $RESTART_POLICY"
    fi
done

log "\n======== Empfehlungen ========" "$BLUE"
log "1. Teste den Autostart mit: sudo systemctl restart docker" "$YELLOW"
log "2. Prüfe danach mit: docker ps -a" "$YELLOW"
log "3. Alle Container sollten automatisch starten" "$YELLOW"
log "\nScript abgeschlossen!" "$GREEN"