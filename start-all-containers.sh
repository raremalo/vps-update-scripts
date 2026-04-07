#!/usr/bin/env bash
# ==============================================================
# Start All Containers Script
# Startet alle Container in der richtigen Reihenfolge
# Basierend auf der script.txt Analyse
# ==============================================================

set -euo pipefail

# Farben
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${2-}${1}${NC}"; }

# Prüfe ob Docker läuft
if ! docker info &>/dev/null; then
    log "Docker läuft nicht - starte Docker Service..." "$YELLOW"
    systemctl start docker
    sleep 5
fi

log "======== Container Start Script ========" "$GREEN"
log "Startet alle Container in der richtigen Reihenfolge" "$BLUE"

# Automatische Container-Erkennung und intelligente Gruppierung
# Erkenne Container-Typen basierend auf Namen-Mustern

get_container_priority() {
    local container_name="$1"
    
    # Priorität 1: Datenbanken (höchste Priorität)
    if [[ "$container_name" =~ (postgres|postgresql|mysql|mariadb|mongo|redis|db)(-|$) ]]; then
        echo "1"
    # Priorität 2: Coolify Core
    elif [[ "$container_name" =~ ^coolify$ ]]; then
        echo "2"
    # Priorität 3: Coolify Services
    elif [[ "$container_name" =~ ^coolify- ]]; then
        echo "3"
    # Priorität 4: Proxy/Load Balancer
    elif [[ "$container_name" =~ (proxy|nginx|traefik|haproxy)(-|$) ]]; then
        echo "4"
    # Priorität 5: Alle anderen Anwendungen
    else
        echo "5"
    fi
}

# Container nach Priorität sortieren
log "Erkenne und sortiere Container nach Start-Priorität..." "$BLUE"

# Arrays für verschiedene Prioritäten
declare -a PRIORITY_1_CONTAINERS  # Datenbanken
declare -a PRIORITY_2_CONTAINERS  # Coolify Core
declare -a PRIORITY_3_CONTAINERS  # Coolify Services
declare -a PRIORITY_4_CONTAINERS  # Proxies
declare -a PRIORITY_5_CONTAINERS  # Anwendungen

# Container kategorisieren
while IFS= read -r container_name; do
    if [[ -n "$container_name" ]]; then
        priority=$(get_container_priority "$container_name")
        case "$priority" in
            1) PRIORITY_1_CONTAINERS+=("$container_name") ;;
            2) PRIORITY_2_CONTAINERS+=("$container_name") ;;
            3) PRIORITY_3_CONTAINERS+=("$container_name") ;;
            4) PRIORITY_4_CONTAINERS+=("$container_name") ;;
            5) PRIORITY_5_CONTAINERS+=("$container_name") ;;
        esac
    fi
done < <(docker ps -a --format '{{.Names}}')

start_container_group() {
    local group_name="$1"
    shift
    local containers=("$@")
    
    log "\nStarte $group_name..." "$BLUE"
    
    for container in "${containers[@]}"; do
        if docker ps -a --format '{{.Names}}' | grep -q "^${container}$"; then
            STATUS=$(docker inspect --format '{{.State.Status}}' "$container" 2>/dev/null || echo "unknown")
            if [[ "$STATUS" != "running" ]]; then
                log "  Starte $container (Status: $STATUS)..." "$YELLOW"
                if docker start "$container" &>/dev/null; then
                    log "    ✓ $container erfolgreich gestartet" "$GREEN"
                else
                    log "    ⚠ $container Start fehlgeschlagen" "$RED"
                fi
            else
                log "  ✓ $container läuft bereits" "$GREEN"
            fi
        else
            log "  - $container nicht gefunden" "$YELLOW"
        fi
    done
    
    # Kurze Pause zwischen Gruppen
    sleep 3
}

# Zeige erkannte Container-Kategorien
log "\nErkannte Container-Kategorien:" "$BLUE"
log "  Datenbanken (${#PRIORITY_1_CONTAINERS[@]}): ${PRIORITY_1_CONTAINERS[*]}" "$CYAN"
log "  Coolify Core (${#PRIORITY_2_CONTAINERS[@]}): ${PRIORITY_2_CONTAINERS[*]}" "$CYAN"
log "  Coolify Services (${#PRIORITY_3_CONTAINERS[@]}): ${PRIORITY_3_CONTAINERS[*]}" "$CYAN"
log "  Proxies (${#PRIORITY_4_CONTAINERS[@]}): ${PRIORITY_4_CONTAINERS[*]}" "$CYAN"
log "  Anwendungen (${#PRIORITY_5_CONTAINERS[@]}): ${PRIORITY_5_CONTAINERS[*]}" "$CYAN"

# Starte Container-Gruppen in Prioritäts-Reihenfolge
if [[ ${#PRIORITY_1_CONTAINERS[@]} -gt 0 ]]; then
    start_container_group "Datenbanken" "${PRIORITY_1_CONTAINERS[@]}"
fi

if [[ ${#PRIORITY_2_CONTAINERS[@]} -gt 0 ]]; then
    start_container_group "Coolify Core" "${PRIORITY_2_CONTAINERS[@]}"
fi

if [[ ${#PRIORITY_3_CONTAINERS[@]} -gt 0 ]]; then
    start_container_group "Coolify Services" "${PRIORITY_3_CONTAINERS[@]}"
fi

if [[ ${#PRIORITY_4_CONTAINERS[@]} -gt 0 ]]; then
    start_container_group "Proxies" "${PRIORITY_4_CONTAINERS[@]}"
fi

if [[ ${#PRIORITY_5_CONTAINERS[@]} -gt 0 ]]; then
    start_container_group "Anwendungen" "${PRIORITY_5_CONTAINERS[@]}"
fi

# Warte auf Container-Initialisierung
log "\nWarte auf Container-Initialisierung..." "$BLUE"
sleep 10

# Finaler Status
log "\n======== Container Status ========" "$GREEN"
printf "%-40s %-15s %-15s\n" "CONTAINER" "STATUS" "HEALTH"
printf "%-40s %-15s %-15s\n" "$(printf '%0.s-' {1..40})" "$(printf '%0.s-' {1..15})" "$(printf '%0.s-' {1..15})"

while read -r name; do
    if [[ -n "$name" ]]; then
        STATUS=$(docker inspect --format '{{.State.Status}}' "$name" 2>/dev/null || echo "unknown")
        HEALTH=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}no-check{{end}}' "$name" 2>/dev/null || echo "unknown")
        printf "%-40s %-15s %-15s\n" "$name" "$STATUS" "$HEALTH"
    fi
done < <(docker ps -a --format '{{.Names}}')

log "\nContainer-Start abgeschlossen!" "$GREEN"
log "Prüfe die Logs mit: docker logs <container-name>" "$YELLOW"