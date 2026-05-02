#!/usr/bin/env bash
# vps-update-dokploy.sh
# VPS Update-Skript optimiert für Dokploy
# Angepasst von vps-update-coolify-optimized.sh

set -euo pipefail

# =====================================
# Konfiguration
# =====================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGFILE="/var/log/vps-update.log"
LOCKFILE="/var/run/vps-update.lock"

# Dokploy-spezifische Konfiguration
DOKPLOY_PATH="/etc/dokploy"  # Standardpfad, wird automatisch erkannt

# Dynamisch erkannte Container-Namen (werden in detect_dokploy_containers gesetzt)
DOKPLOY_CONTAINER_POSTGRES=""
DOKPLOY_CONTAINER_REDIS=""
DOKPLOY_CONTAINER_MAIN=""
DOKPLOY_CONTAINER_TRAEFIK=""

# =====================================
# Hilfsfunktionen
# =====================================
log() {
    local level="$1"
    shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*" | tee -a "$LOGFILE"
}

cleanup() {
    rm -f "$LOCKFILE"
}

trap cleanup EXIT

# =====================================
# Hauptfunktionen
# =====================================
check_prerequisites() {
    # Root-Check
    if [[ $EUID -ne 0 ]]; then
        log "ERROR" "Dieses Skript muss als root ausgeführt werden"
        exit 1
    fi

    # Atomic lock
    exec 9>"$LOCKFILE"
    flock -n 9 || { log "ERROR" "Script läuft bereits (Lock: $LOCKFILE)"; exit 1; }
    
    # Finde Dokploy-Installationspfad
    detect_dokploy_path
    
    # Erkenne tatsächliche Container-Namen
    detect_dokploy_containers
}

detect_dokploy_path() {
    log "INFO" "Suche Dokploy-Installation..."
    
    # Mögliche Installationspfade
    local possible_paths=(
        "/etc/dokploy"
        "/opt/dokploy"
        "/var/lib/dokploy"
        "/root/dokploy"
    )
    
    for path in "${possible_paths[@]}"; do
        if [[ -d "$path" ]] && [[ -f "$path/docker-compose.yml" ]]; then
            DOKPLOY_PATH="$path"
            log "SUCCESS" "Dokploy gefunden: $DOKPLOY_PATH"
            return 0
        fi
    done
    
    # Falls nicht gefunden, prüfe ob Dokploy-Container laufen
    if docker ps -a --format '{{.Names}}' | grep -qi "dokploy"; then
        log "WARNING" "Dokploy-Container gefunden, aber docker-compose.yml nicht gefunden"
        log "INFO" "Verwende Docker-Befehle statt docker-compose"
        DOKPLOY_PATH=""
        return 0
    fi
    
    log "WARNING" "Dokploy-Installation nicht gefunden"
    DOKPLOY_PATH=""
}

# Erkenne tatsächliche Dokploy-Container-Namen dynamisch
detect_dokploy_containers() {
    log "INFO" "Erkenne Dokploy-Container-Namen..."
    
    local all_containers
    all_containers=$(docker ps -a --format '{{.Names}}')
    
    # Finde PostgreSQL-Container
    DOKPLOY_CONTAINER_POSTGRES=$(echo "$all_containers" | grep -iE '(dokploy.*postgres|postgres.*dokploy)' | head -1) || true
    
    # Finde Redis-Container
    DOKPLOY_CONTAINER_REDIS=$(echo "$all_containers" | grep -iE '(dokploy.*redis|redis.*dokploy)' | head -1) || true
    
    # Finde Traefik-Container
    DOKPLOY_CONTAINER_TRAEFIK=$(echo "$all_containers" | grep -iE '(dokploy.*traefik|traefik.*dokploy)' | head -1) || true
    
    # Finde Haupt-Container (Dokploy selbst, aber nicht postgres/redis/traefik)
    DOKPLOY_CONTAINER_MAIN=$(echo "$all_containers" | grep -i 'dokploy' | grep -viE '(postgres|redis|traefik)' | head -1) || true
    
    # Logge was gefunden wurde
    log "INFO" "Erkannte Container:"
    [[ -n "$DOKPLOY_CONTAINER_POSTGRES" ]] && log "INFO" "  PostgreSQL: $DOKPLOY_CONTAINER_POSTGRES" || log "WARNING" "  PostgreSQL: NICHT GEFUNDEN"
    [[ -n "$DOKPLOY_CONTAINER_REDIS" ]] && log "INFO" "  Redis: $DOKPLOY_CONTAINER_REDIS" || log "WARNING" "  Redis: NICHT GEFUNDEN"
    [[ -n "$DOKPLOY_CONTAINER_MAIN" ]] && log "INFO" "  Hauptservice: $DOKPLOY_CONTAINER_MAIN" || log "WARNING" "  Hauptservice: NICHT GEFUNDEN"
    [[ -n "$DOKPLOY_CONTAINER_TRAEFIK" ]] && log "INFO" "  Traefik: $DOKPLOY_CONTAINER_TRAEFIK" || log "WARNING" "  Traefik: NICHT GEFUNDEN"
}

stop_docker_containers() {
    log "INFO" "Stoppe Docker-Container..."
    
    # Dokploy-spezifische Reihenfolge (OHNE Soketi, da nicht vorhanden)
    if [[ -n "$DOKPLOY_CONTAINER_MAIN" ]] || [[ -n "$DOKPLOY_CONTAINER_POSTGRES" ]]; then
        log "INFO" "Dokploy erkannt - stoppe in korrekter Reihenfolge..."
        
        # 1. Stoppe zuerst Traefik (Proxy)
        [[ -n "$DOKPLOY_CONTAINER_TRAEFIK" ]] && docker stop "$DOKPLOY_CONTAINER_TRAEFIK" 2>/dev/null || true
        sleep 2
        
        # 2. Dann Hauptcontainer
        [[ -n "$DOKPLOY_CONTAINER_MAIN" ]] && docker stop "$DOKPLOY_CONTAINER_MAIN" 2>/dev/null || true
        sleep 2
        
        # 3. Zuletzt Datenbank und Redis
        [[ -n "$DOKPLOY_CONTAINER_REDIS" ]] && docker stop "$DOKPLOY_CONTAINER_REDIS" 2>/dev/null || true
        [[ -n "$DOKPLOY_CONTAINER_POSTGRES" ]] && docker stop "$DOKPLOY_CONTAINER_POSTGRES" 2>/dev/null || true
        sleep 2
    fi
    
    # Stoppe alle anderen Container
    local containers=$(docker ps -q)
    if [[ -n "$containers" ]]; then
        log "INFO" "Stoppe verbleibende Container..."
        docker stop $containers 2>/dev/null || true
    fi
    
    log "SUCCESS" "Alle Container gestoppt"
}

update_system() {
    log "INFO" "Starte System-Updates..."
    
    # Update Paketlisten
    apt-get update || {
        log "ERROR" "apt-get update fehlgeschlagen"
        return 1
    }
    
    # Halte problematische Pakete zurück (falls vorhanden)
    log "INFO" "Halte problematische Pakete zurück..."
    apt-mark hold snapd ubuntu-advantage-tools 2>/dev/null || true
    
    # Führe Updates durch
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y || {
        log "ERROR" "apt-get upgrade fehlgeschlagen"
        return 1
    }
    
    # Kernel-Updates
    DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y || {
        log "ERROR" "apt-get dist-upgrade fehlgeschlagen"
        return 1
    }
    
    # Aufräumen
    apt-get autoremove -y
    apt-get autoclean
    
    log "SUCCESS" "System-Updates abgeschlossen"
}

start_dokploy_stack() {
    if ! docker ps -a --format '{{.Names}}' | grep -q "dokploy"; then
        log "INFO" "Dokploy nicht installiert"
        return 0
    fi
    
    log "INFO" "Starte Dokploy-Stack in korrekter Reihenfolge..."
    
    # Wenn docker-compose.yml vorhanden, nutze es
    if [[ -n "$DOKPLOY_PATH" ]] && [[ -f "$DOKPLOY_PATH/docker-compose.yml" ]]; then
        cd "$DOKPLOY_PATH"
        
        # Ermittle docker-compose Service-Namen aus der yml
        local compose_services
        compose_services=$(docker compose config --services 2>/dev/null || docker-compose config --services 2>/dev/null || echo "")
        
        # Finde Service-Namen für jede Komponente
        local pg_service="" redis_service="" main_service="" traefik_service=""
        if [[ -n "$compose_services" ]]; then
            pg_service=$(echo "$compose_services" | grep -iE '(postgres|database|db)' | head -1) || true
            redis_service=$(echo "$compose_services" | grep -iE '(redis|cache)' | head -1) || true
            traefik_service=$(echo "$compose_services" | grep -iE '(traefik|proxy)' | head -1) || true
            main_service=$(echo "$compose_services" | grep -iE '(dokploy|app|server|api)' | grep -viE '(postgres|database|db|redis|cache|traefik|proxy)' | head -1) || true
        fi
        
        # 1. Datenbank und Cache zuerst
        log "INFO" "Starte Datenbank und Redis..."
        if [[ -n "$pg_service" ]]; then
            docker compose up -d "$pg_service" 2>/dev/null || docker-compose up -d "$pg_service" || true
        fi
        if [[ -n "$redis_service" ]]; then
            docker compose up -d "$redis_service" 2>/dev/null || docker-compose up -d "$redis_service" || true
        fi
        # Fallback: falls keine Service-Namen erkannt wurden
        if [[ -z "$pg_service" ]] && [[ -z "$redis_service" ]]; then
            log "INFO" "Konnte docker-compose Services nicht ermitteln, starte alle..."
            docker compose up -d 2>/dev/null || docker-compose up -d || true
        fi
        sleep 10
        
        # 2. Hauptcontainer (KEIN Soketi bei Dokploy!)
        if [[ -n "$main_service" ]]; then
            log "INFO" "Starte Dokploy Hauptservice..."
            docker compose up -d "$main_service" 2>/dev/null || docker-compose up -d "$main_service" || true
            sleep 10
        fi
        
        # 3. Proxy (Traefik)
        if [[ -n "$traefik_service" ]]; then
            log "INFO" "Starte Traefik Proxy..."
            docker compose up -d "$traefik_service" 2>/dev/null || docker-compose up -d "$traefik_service" || true
            sleep 5
        fi
        
        # Falls Hauptservice oder Traefik nicht erkannt wurden, starte den Rest
        if [[ -z "$main_service" ]] || [[ -z "$traefik_service" ]]; then
            log "INFO" "Starte verbleibende Services..."
            docker compose up -d 2>/dev/null || docker-compose up -d || true
            sleep 5
        fi
        
    else
        # Fallback: Starte Container direkt mit Docker (verwende dynamisch erkannte Namen)
        log "INFO" "Starte Container direkt (ohne docker-compose)..."
        
        # 1. Datenbank und Redis
        [[ -n "$DOKPLOY_CONTAINER_POSTGRES" ]] && docker start "$DOKPLOY_CONTAINER_POSTGRES" 2>/dev/null || true
        [[ -n "$DOKPLOY_CONTAINER_REDIS" ]] && docker start "$DOKPLOY_CONTAINER_REDIS" 2>/dev/null || true
        sleep 10
        
        # 2. Hauptcontainer
        [[ -n "$DOKPLOY_CONTAINER_MAIN" ]] && docker start "$DOKPLOY_CONTAINER_MAIN" 2>/dev/null || true
        sleep 10
        
        # 3. Traefik
        [[ -n "$DOKPLOY_CONTAINER_TRAEFIK" ]] && docker start "$DOKPLOY_CONTAINER_TRAEFIK" 2>/dev/null || true
        sleep 5
    fi
    
    # Verifiziere dass Services laufen (nutze dynamisch erkannte Namen)
    log "INFO" "Verifiziere Dokploy-Services..."
    
    if [[ -n "$DOKPLOY_CONTAINER_POSTGRES" ]]; then
        if docker ps --format '{{.Names}}' | grep -qx "$DOKPLOY_CONTAINER_POSTGRES"; then
            log "SUCCESS" "✓ PostgreSQL ($DOKPLOY_CONTAINER_POSTGRES) läuft"
        else
            log "WARNING" "✗ PostgreSQL ($DOKPLOY_CONTAINER_POSTGRES) läuft nicht!"
        fi
    fi
    
    if [[ -n "$DOKPLOY_CONTAINER_REDIS" ]]; then
        if docker ps --format '{{.Names}}' | grep -qx "$DOKPLOY_CONTAINER_REDIS"; then
            log "SUCCESS" "✓ Redis ($DOKPLOY_CONTAINER_REDIS) läuft"
        else
            log "WARNING" "✗ Redis ($DOKPLOY_CONTAINER_REDIS) läuft nicht!"
        fi
    fi

    if [[ -n "$DOKPLOY_CONTAINER_MAIN" ]]; then
        if docker ps --format '{{.Names}}' | grep -qx "$DOKPLOY_CONTAINER_MAIN"; then
            log "SUCCESS" "✓ Dokploy ($DOKPLOY_CONTAINER_MAIN) läuft"
        else
            log "ERROR" "✗ Dokploy ($DOKPLOY_CONTAINER_MAIN) läuft nicht!"
            # Diagnose: Zeige Logs des Containers
            log "INFO" "Letzte Logs von $DOKPLOY_CONTAINER_MAIN:"
            docker logs --tail 20 "$DOKPLOY_CONTAINER_MAIN" 2>&1 | tee -a "$LOGFILE" || true
        fi
    fi

    if [[ -n "$DOKPLOY_CONTAINER_TRAEFIK" ]]; then
        if docker ps --format '{{.Names}}' | grep -qx "$DOKPLOY_CONTAINER_TRAEFIK"; then
            log "SUCCESS" "✓ Traefik ($DOKPLOY_CONTAINER_TRAEFIK) läuft"
        else
            log "WARNING" "✗ Traefik ($DOKPLOY_CONTAINER_TRAEFIK) läuft nicht!"
        fi
    fi
    
    log "SUCCESS" "Dokploy-Stack gestartet"
}

start_other_containers() {
    log "INFO" "Starte andere Container..."
    
    # Finde alle gestoppten Container mit restart policy
    docker ps -a --format '{{.Names}}\t{{.State}}' | grep -v "dokploy" | while IFS=$'\t' read -r name state; do
        if [[ "$state" != "running" ]] && [[ -n "$name" ]]; then
            local restart_policy=$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$name" 2>/dev/null || echo "")
            
            if [[ "$restart_policy" == "always" ]] || [[ "$restart_policy" == "unless-stopped" ]]; then
                log "INFO" "Starte Container: $name"
                docker start "$name" 2>/dev/null || log "WARNING" "Konnte $name nicht starten"
            fi
        fi
    done
    
    log "SUCCESS" "Andere Container gestartet"
}

check_reboot_required() {
    log "INFO" "Prüfe ob Neustart erforderlich..."
    
    if [[ -f /var/run/reboot-required ]]; then
        log "WARNING" "=== NEUSTART ERFORDERLICH ==="
        log "WARNING" "Gründe:"
        while read -r pkg; do
            log "WARNING" "  - $pkg"
        done < <(cat /var/run/reboot-required.pkgs 2>/dev/null)
        
        log "INFO" "Starte Neustart in 30 Sekunden..."
        log "INFO" "Drücken Sie Ctrl+C zum Abbrechen"
        sleep 30
        log "INFO" "Starte Neustart..."
        reboot
    else
        log "INFO" "Kein Neustart erforderlich"
    fi
}

show_final_status() {
    log "INFO" "=== Finale Container-Status ==="
    docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep -E "(dokploy|NAMES)" || true
}

# =====================================
# Hauptprogramm
# =====================================
main() {
    log "INFO" "=== VPS Update für Dokploy gestartet ==="
    log "INFO" "Datum: $(date)"
    log "INFO" "Server: $(hostname)"
    
    # Voraussetzungen prüfen
    check_prerequisites
    
    # Docker-Container stoppen
    stop_docker_containers
    
    # System aktualisieren
    update_system
    
    # Dokploy-Stack starten
    start_dokploy_stack
    
    # Andere Container starten
    start_other_containers
    
    # Status anzeigen
    show_final_status
    
    # Reboot prüfen
    check_reboot_required
    
    log "SUCCESS" "=== VPS Update abgeschlossen ==="
}

# Skript ausführen
main "$@"
