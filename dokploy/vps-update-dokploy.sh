#!/usr/bin/env bash
# vps-update-dokploy.sh
# VPS Update-Skript optimiert für Dokploy
# Unterstützt Docker Swarm und reguläre Docker-Installationen

set -euo pipefail

# =====================================
# Konfiguration
# =====================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGFILE="/var/log/vps-update.log"
LOCKFILE="/var/run/vps-update.lock"

# Dokploy-spezifische Konfiguration
DOKPLOY_PATH="/etc/dokploy"  # Standardpfad, wird automatisch erkannt

# Swarm-Erkennung
IS_SWARM=false
DOKPLOY_STACK=""

# Docker Swarm Service-Namen
SERVICE_POSTGRES=""
SERVICE_REDIS=""
SERVICE_MAIN=""
SERVICE_TRAEFIK=""

# Original-Replikas (für Restore nach Update)
declare -A SERVICE_REPLICAS

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
    
    # Prüfe ob Docker Swarm aktiv ist
    detect_swarm_mode
    
    # Erkenne Services/Container
    detect_dokploy_services
}

detect_dokploy_path() {
    log "INFO" "Suche Dokploy-Installation..."
    
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
        log "INFO" "Dokploy-Container gefunden, docker-compose.yml nicht lokalisiert"
        DOKPLOY_PATH=""
        return 0
    fi
    
    log "WARNING" "Dokploy-Installation nicht gefunden"
    DOKPLOY_PATH=""
}

# Prüfe ob Docker Swarm aktiv ist
detect_swarm_mode() {
    local swarm_state
    swarm_state=$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null || echo "inactive")
    
    if [[ "$swarm_state" == "active" ]]; then
        IS_SWARM=true
        log "INFO" "Docker Swarm erkannt"
        
        # Finde den Stack-Namen
        local services
        services=$(docker service ls --format '{{.Name}}' 2>/dev/null | grep -i "dokploy" || true)
        if [[ -n "$services" ]]; then
            # Stack-Name ist der Präfix vor dem ersten Unterstrich
            DOKPLOY_STACK=$(echo "$services" | head -1 | cut -d'_' -f1)
            log "INFO" "Dokploy Swarm-Stack: $DOKPLOY_STACK"
        fi
    else
        IS_SWARM=false
        log "INFO" "Docker Swarm nicht aktiv (regulärer Docker-Modus)"
    fi
}

# Erkenne Dokploy-Services (Swarm) oder Container (regulär)
detect_dokploy_services() {
    log "INFO" "Erkenne Dokploy-Services..."
    
    if [[ "$IS_SWARM" == "true" ]]; then
        # Docker Swarm: Nutze 'docker service ls'
        local all_services
        all_services=$(docker service ls --format '{{.Name}}' 2>/dev/null | grep -i "dokploy" || true)
        
        if [[ -z "$all_services" ]]; then
            log "WARNING" "Keine Dokploy-Swarm-Services gefunden"
            return 0
        fi
        
        log "INFO" "Gefundene Swarm-Services:"
        echo "$all_services" | while read -r svc; do
            log "INFO" "  - $svc"
        done
        
        # Mappe Services zu Rollen
        SERVICE_POSTGRES=$(echo "$all_services" | grep -iE 'postgres' | head -1) || true
        SERVICE_REDIS=$(echo "$all_services" | grep -iE 'redis' | head -1) || true
        SERVICE_TRAEFIK=$(echo "$all_services" | grep -iE 'traefik' | head -1) || true
        # Hauptservice: alles mit dokploy aber ohne postgres/redis/traefik
        SERVICE_MAIN=$(echo "$all_services" | grep -viE '(postgres|redis|traefik)' | head -1) || true
        
        log "INFO" "Zugeordnete Services:"
        [[ -n "$SERVICE_POSTGRES" ]] && log "INFO" "  PostgreSQL: $SERVICE_POSTGRES" || log "WARNING" "  PostgreSQL: NICHT GEFUNDEN"
        [[ -n "$SERVICE_REDIS" ]] && log "INFO" "  Redis: $SERVICE_REDIS" || log "WARNING" "  Redis: NICHT GEFUNDEN"
        [[ -n "$SERVICE_MAIN" ]] && log "INFO" "  Hauptservice: $SERVICE_MAIN" || log "WARNING" "  Hauptservice: NICHT GEFUNDEN"
        [[ -n "$SERVICE_TRAEFIK" ]] && log "INFO" "  Traefik: $SERVICE_TRAEFIK" || log "WARNING" "  Traefik: NICHT GEFUNDEN"
        
        # Speichere aktuelle Replika-Zahlen
        for svc in $SERVICE_POSTGRES $SERVICE_REDIS $SERVICE_MAIN $SERVICE_TRAEFIK; do
            [[ -z "$svc" ]] && continue
            local replicas
            replicas=$(docker service ls --format '{{.Name}} {{.Replicas}}' 2>/dev/null | grep "^${svc} " | awk '{print $2}' | cut -d'/' -f2 || echo "1")
            SERVICE_REPLICAS["$svc"]="${replicas:-1}"
            log "INFO" "  $svc: $replicas Replika(s)"
        done
        
    else
        # Regulärer Docker: Nutze Container-Namen (Pattern-Matching)
        local all_containers
        all_containers=$(docker ps -a --format '{{.Names}}')
        
        SERVICE_POSTGRES=$(echo "$all_containers" | grep -iE '(dokploy.*postgres|postgres.*dokploy)' | head -1) || true
        SERVICE_REDIS=$(echo "$all_containers" | grep -iE '(dokploy.*redis|redis.*dokploy)' | head -1) || true
        SERVICE_TRAEFIK=$(echo "$all_containers" | grep -iE '(dokploy.*traefik|traefik.*dokploy)' | head -1) || true
        SERVICE_MAIN=$(echo "$all_containers" | grep -i 'dokploy' | grep -viE '(postgres|redis|traefik)' | head -1) || true
        
        log "INFO" "Erkannte Container:"
        [[ -n "$SERVICE_POSTGRES" ]] && log "INFO" "  PostgreSQL: $SERVICE_POSTGRES" || log "WARNING" "  PostgreSQL: NICHT GEFUNDEN"
        [[ -n "$SERVICE_REDIS" ]] && log "INFO" "  Redis: $SERVICE_REDIS" || log "WARNING" "  Redis: NICHT GEFUNDEN"
        [[ -n "$SERVICE_MAIN" ]] && log "INFO" "  Hauptservice: $SERVICE_MAIN" || log "WARNING" "  Hauptservice: NICHT GEFUNDEN"
        [[ -n "$SERVICE_TRAEFIK" ]] && log "INFO" "  Traefik: $SERVICE_TRAEFIK" || log "WARNING" "  Traefik: NICHT GEFUNDEN"
    fi
}

stop_docker_containers() {
    log "INFO" "Stoppe Dokploy-Services..."
    
    if [[ "$IS_SWARM" == "true" ]]; then
        # Docker Swarm: Scale Services auf 0
        # Reihenfolge: Traefik → Hauptservice → Redis → PostgreSQL
        
        [[ -n "$SERVICE_TRAEFIK" ]] && { log "INFO" "Stoppe $SERVICE_TRAEFIK..."; docker service scale "$SERVICE_TRAEFIK=0" 2>/dev/null || true; }
        sleep 2
        [[ -n "$SERVICE_MAIN" ]] && { log "INFO" "Stoppe $SERVICE_MAIN..."; docker service scale "$SERVICE_MAIN=0" 2>/dev/null || true; }
        sleep 2
        [[ -n "$SERVICE_REDIS" ]] && { log "INFO" "Stoppe $SERVICE_REDIS..."; docker service scale "$SERVICE_REDIS=0" 2>/dev/null || true; }
        [[ -n "$SERVICE_POSTGRES" ]] && { log "INFO" "Stoppe $SERVICE_POSTGRES..."; docker service scale "$SERVICE_POSTGRES=0" 2>/dev/null || true; }
        sleep 3
    else
        # Regulärer Docker: docker stop
        [[ -n "$SERVICE_TRAEFIK" ]] && docker stop "$SERVICE_TRAEFIK" 2>/dev/null || true
        sleep 2
        [[ -n "$SERVICE_MAIN" ]] && docker stop "$SERVICE_MAIN" 2>/dev/null || true
        sleep 2
        [[ -n "$SERVICE_REDIS" ]] && docker stop "$SERVICE_REDIS" 2>/dev/null || true
        [[ -n "$SERVICE_POSTGRES" ]] && docker stop "$SERVICE_POSTGRES" 2>/dev/null || true
        sleep 2
    fi
    
    # Stoppe alle übrigen Container
    local containers
    containers=$(docker ps -q 2>/dev/null || true)
    if [[ -n "$containers" ]]; then
        log "INFO" "Stoppe verbleibende Container..."
        docker stop $containers 2>/dev/null || true
    fi
    
    log "SUCCESS" "Alle Services gestoppt"
}

update_system() {
    log "INFO" "Starte System-Updates..."
    
    apt-get update || {
        log "ERROR" "apt-get update fehlgeschlagen"
        return 1
    }
    
    log "INFO" "Halte problematische Pakete zurück..."
    apt-mark hold snapd ubuntu-advantage-tools 2>/dev/null || true
    
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y || {
        log "ERROR" "apt-get upgrade fehlgeschlagen"
        return 1
    }
    
    DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y || {
        log "ERROR" "apt-get dist-upgrade fehlgeschlagen"
        return 1
    }
    
    apt-get autoremove -y
    apt-get autoclean
    
    log "SUCCESS" "System-Updates abgeschlossen"
}

start_dokploy_stack() {
    local has_dokploy=false
    if [[ "$IS_SWARM" == "true" ]]; then
        docker service ls --format '{{.Name}}' 2>/dev/null | grep -qi "dokploy" && has_dokploy=true
    else
        docker ps -a --format '{{.Names}}' | grep -qi "dokploy" && has_dokploy=true
    fi
    
    if [[ "$has_dokploy" == "false" ]]; then
        log "INFO" "Dokploy nicht installiert"
        return 0
    fi
    
    log "INFO" "Starte Dokploy-Stack in korrekter Reihenfolge..."
    
    if [[ "$IS_SWARM" == "true" ]]; then
        start_swarm_services
    else
        start_regular_services
    fi
    
    # Warte und verifiziere
    sleep 5
    verify_dokploy_services
    
    log "SUCCESS" "Dokploy-Stack gestartet"
}

# Starte Swarm-Services in korrekter Reihenfolge
start_swarm_services() {
    # Reihenfolge: PostgreSQL → Redis → Hauptservice → Traefik
    
    # 1. PostgreSQL
    if [[ -n "$SERVICE_POSTGRES" ]]; then
        local replicas="${SERVICE_REPLICAS[$SERVICE_POSTGRES]:-1}"
        log "INFO" "Starte PostgreSQL ($SERVICE_POSTGRES, $replicas Replika(s))..."
        docker service scale "$SERVICE_POSTGRES=$replicas" 2>/dev/null || true
        sleep 10
    fi
    
    # 2. Redis
    if [[ -n "$SERVICE_REDIS" ]]; then
        local replicas="${SERVICE_REPLICAS[$SERVICE_REDIS]:-1}"
        log "INFO" "Starte Redis ($SERVICE_REDIS, $replicas Replika(s))..."
        docker service scale "$SERVICE_REDIS=$replicas" 2>/dev/null || true
        sleep 5
    fi
    
    # 3. Hauptservice
    if [[ -n "$SERVICE_MAIN" ]]; then
        local replicas="${SERVICE_REPLICAS[$SERVICE_MAIN]:-1}"
        log "INFO" "Starte Dokploy Hauptservice ($SERVICE_MAIN, $replicas Replika(s))..."
        docker service scale "$SERVICE_MAIN=$replicas" 2>/dev/null || true
        sleep 10
    fi
    
    # 4. Traefik
    if [[ -n "$SERVICE_TRAEFIK" ]]; then
        local replicas="${SERVICE_REPLICAS[$SERVICE_TRAEFIK]:-1}"
        log "INFO" "Starte Traefik ($SERVICE_TRAEFIK, $replicas Replika(s))..."
        docker service scale "$SERVICE_TRAEFIK=$replicas" 2>/dev/null || true
        sleep 5
    fi
}

# Starte reguläre Docker-Container
start_regular_services() {
    if [[ -n "$DOKPLOY_PATH" ]] && [[ -f "$DOKPLOY_PATH/docker-compose.yml" ]]; then
        cd "$DOKPLOY_PATH"
        log "INFO" "Starte via docker-compose..."
        docker compose up -d 2>/dev/null || docker-compose up -d || true
    else
        log "INFO" "Starte Container direkt..."
        [[ -n "$SERVICE_POSTGRES" ]] && docker start "$SERVICE_POSTGRES" 2>/dev/null || true
        [[ -n "$SERVICE_REDIS" ]] && docker start "$SERVICE_REDIS" 2>/dev/null || true
        sleep 10
        [[ -n "$SERVICE_MAIN" ]] && docker start "$SERVICE_MAIN" 2>/dev/null || true
        sleep 10
        [[ -n "$SERVICE_TRAEFIK" ]] && docker start "$SERVICE_TRAEFIK" 2>/dev/null || true
        sleep 5
    fi
}

# Verifiziere Services
verify_dokploy_services() {
    log "INFO" "Verifiziere Dokploy-Services..."
    
    if [[ "$IS_SWARM" == "true" ]]; then
        # Swarm: Prüfe docker service ls Replicas-Spalte
        verify_swarm_service "$SERVICE_POSTGRES" "PostgreSQL"
        verify_swarm_service "$SERVICE_REDIS" "Redis"
        verify_swarm_service "$SERVICE_MAIN" "Dokploy Hauptservice"
        verify_swarm_service "$SERVICE_TRAEFIK" "Traefik Proxy"
    else
        # Regulär: Prüfe docker ps mit Pattern-Matching
        verify_container "$SERVICE_POSTGRES" "PostgreSQL"
        verify_container "$SERVICE_REDIS" "Redis"
        verify_container "$SERVICE_MAIN" "Dokploy Hauptservice"
        verify_container "$SERVICE_TRAEFIK" "Traefik Proxy"
    fi
}

# Verifiziere einen Swarm-Service
verify_swarm_service() {
    local service="$1"
    local label="$2"
    
    [[ -z "$service" ]] && return 0
    
    local replicas_info
    replicas_info=$(docker service ls --format '{{.Name}} {{.Replicas}}' 2>/dev/null | grep "^${service} " || true)
    
    if [[ -n "$replicas_info" ]]; then
        local current desired
        current=$(echo "$replicas_info" | awk '{print $2}' | cut -d'/' -f1)
        desired=$(echo "$replicas_info" | awk '{print $2}' | cut -d'/' -f2)
        
        if [[ "$current" == "$desired" ]] && [[ "$current" -gt 0 ]]; then
            log "SUCCESS" "✓ $label ($service) läuft ($current/$desired)"
        else
            log "WARNING" "✗ $label ($service) nicht vollständig ($current/$desired)"
            # Diagnose
            log "INFO" "Service-Details:"
            docker service ps "$service" --format "table {{.Name}}\t{{.CurrentState}}\t{{.Error}}" 2>/dev/null | head -5 | tee -a "$LOGFILE" || true
        fi
    else
        log "WARNING" "✗ $label ($service) nicht gefunden"
    fi
}

# Verifiziere einen regulären Container
verify_container() {
    local container="$1"
    local label="$2"
    
    [[ -z "$container" ]] && return 0
    
    if docker ps --format '{{.Names}}' | grep -q "$container"; then
        log "SUCCESS" "✓ $label ($container) läuft"
    else
        log "WARNING" "✗ $label ($container) läuft nicht!"
    fi
}

start_other_containers() {
    log "INFO" "Starte andere Container..."
    
    if [[ "$IS_SWARM" == "true" ]]; then
        # Im Swarm-Modus: Starte Nicht-Dokploy-Services die auf 0 skaliert wurden
        local all_services
        all_services=$(docker service ls --format '{{.Name}} {{.Replicas}}' 2>/dev/null | grep -vi "dokploy" || true)
        
        while IFS=' ' read -r name replicas; do
            [[ -z "$name" ]] && continue
            local current desired
            current=$(echo "$replicas" | cut -d'/' -f1)
            desired=$(echo "$replicas" | cut -d'/' -f2)
            
            if [[ "$current" == "0" ]] && [[ "$desired" -gt 0 ]]; then
                log "INFO" "Starte Service: $name"
                docker service scale "$name=$desired" 2>/dev/null || log "WARNING" "Konnte $name nicht starten"
            fi
        done <<< "$all_services"
    else
        # Regulär: Starte gestoppte Container mit Restart-Policy
        docker ps -a --format '{{.Names}}\t{{.State}}' | grep -vi "dokploy" | while IFS=$'\t' read -r name state; do
            if [[ "$state" != "running" ]] && [[ -n "$name" ]]; then
                local restart_policy
                restart_policy=$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$name" 2>/dev/null || echo "")
                
                if [[ "$restart_policy" == "always" ]] || [[ "$restart_policy" == "unless-stopped" ]]; then
                    log "INFO" "Starte Container: $name"
                    docker start "$name" 2>/dev/null || log "WARNING" "Konnte $name nicht starten"
                fi
            fi
        done
    fi
    
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
    log "INFO" "=== Finale Status ==="
    
    if [[ "$IS_SWARM" == "true" ]]; then
        docker service ls --format "table {{.Name}}\t{{.Replicas}}\t{{.Image}}" 2>/dev/null | grep -E "(dokploy|NAME)" | tee -a "$LOGFILE" || true
    else
        docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep -E "(dokploy|NAMES)" | tee -a "$LOGFILE" || true
    fi
}

# =====================================
# Hauptprogramm
# =====================================
main() {
    log "INFO" "=== VPS Update für Dokploy gestartet ==="
    log "INFO" "Datum: $(date)"
    log "INFO" "Server: $(hostname)"
    log "INFO" "Swarm-Modus: $IS_SWARM"
    
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
