#!/usr/bin/env bash
# LINT: read-only
#
# vps-selftest.sh — READ-ONLY Diagnose des laufenden VPS
#
# Zweck: Beantwortet die offenen Fragen der Audit-Remediation mit Fakten vom
#        Zielsystem, damit Entscheidungen nicht auf Annahmen beruhen.
#
# GARANTIE: Dieses Skript ist strikt lesend. Es startet, stoppt, entfernt oder
#           ändert nichts — weder Container, noch Services, noch Pakete, noch
#           Dateien. Es darf gefahrlos auf dem Produktivsystem laufen.
#
# Verwendung auf dem VPS:
#     sudo bash vps-selftest.sh
#     sudo bash vps-selftest.sh > selftest-report.txt 2>&1
#
# Ohne root laufen die meisten Prüfungen ebenfalls, einzelne melden dann
# "keine Berechtigung" statt eines Ergebnisses.
#
# Exit-Code ist immer 0 — ein nicht ermittelbarer Wert ist ein Ergebnis,
# kein Fehler.

# Bewusst OHNE -e: Dieses Skript prüft Zustände, deren Ermittlung regulär
# mit Exit != 0 endet (z. B. "Unit ist nicht enabled"). Ein Abbruch wäre falsch.
set -uo pipefail

# 1.1: probe() wertet den Exit-Code nicht mehr aus (verschluckte sonst
#      "static"/"masked" bei systemctl is-enabled), sshd -t meldet Permission
#      denied nicht mehr als Konfigurationsfehler, Warnung bei Lauf ohne root,
#      maschinenlesbarer FLEET-SUMMARY-Block für den Vergleich mehrerer Server.
# 1.2: Flavor-Erkennung unterscheidet jetzt "kein Docker" von "keine
#      Berechtigung". v1.1 meldete FLAVOR=no-docker, obwohl docker.service
#      lief und nur der Zugriff ohne sudo fehlte — irreführend im Vergleich
#      über mehrere Hosts.
readonly SELFTEST_VERSION="1.2"

# ---------------------------------------------------------------------------
# Ausgabe-Helfer
# ---------------------------------------------------------------------------

section() {
    printf '\n===========================================================\n'
    printf '  %s\n' "$1"
    printf '===========================================================\n'
}

item()  { printf '  %-38s %s\n' "$1" "$2"; }
note()  { printf '      -> %s\n' "$1"; }
blank() { printf '\n'; }

# Führt ein Kommando aus und gibt dessen Ausgabe zurück, oder einen Ersatztext,
# wenn nichts ausgegeben wurde.
#
# WICHTIG: Der Exit-Code wird bewusst IGNORIERT. Mehrere der hier genutzten
# Kommandos liefern einen gültigen Zustand auf stdout UND einen Exit-Code != 0:
#   systemctl is-enabled  -> "disabled" / "static" / "masked" + Exit 1
#   systemctl is-active   -> "inactive" / "failed"            + Exit 3
# Eine Auswertung des Exit-Codes würde genau die Zustände verschlucken, die
# hier am wichtigsten sind (insbesondere "masked" bei ssh.service).
probe() {
    local fallback="$1"; shift
    local out
    out=$("$@" 2>/dev/null)
    if [[ -n "$out" ]]; then
        printf '%s' "$out"
        return 0
    fi
    printf '%s' "$fallback"
    return 1
}

have() { command -v "$1" >/dev/null 2>&1; }

# Ordnet die Ausgabe von "systemctl is-enabled" einer von fuenf Klassen zu.
# Grundregel: Was nicht ausdruecklich als Aktivierungspfad dokumentiert ist,
# gilt als "unknown" — niemals als sicher.
#
#   enabled   echter Boot-Aktivierungspfad (enabled, enabled-runtime)
#   masked    Unit ist blockiert und kann nicht starten (masked, masked-runtime)
#   indirect  laeuft nur, wenn eine andere Unit sie einzieht
#             (static, indirect, alias, generated, transient)
#   disabled  ausdruecklich nicht aktiviert
#   unknown   not-found, leer, Fehlertext, alles Uebrige
classify_unit_state() {
    case "$1" in
        enabled|enabled-runtime)                    printf 'enabled'  ;;
        masked|masked-runtime)                      printf 'masked'   ;;
        static|indirect|alias|generated|transient)  printf 'indirect' ;;
        disabled)                                   printf 'disabled' ;;
        *)                                          printf 'unknown'  ;;
    esac
}

# ---------------------------------------------------------------------------
# 0. Kontext
# ---------------------------------------------------------------------------

context_report() {
    section "0. SYSTEM-KONTEXT"

    item "Hostname:"  "$(probe 'unbekannt' hostname)"
    item "Datum:"     "$(date '+%Y-%m-%d %H:%M:%S %Z')"
    item "Kernel:"    "$(probe 'unbekannt' uname -r)"

    if [[ -r /etc/os-release ]]; then
        local pretty
        # shellcheck disable=SC1091
        pretty=$(. /etc/os-release 2>/dev/null && printf '%s' "${PRETTY_NAME:-unbekannt}")
        item "Distribution:" "${pretty:-unbekannt}"
    else
        item "Distribution:" "unbekannt (/etc/os-release nicht lesbar)"
    fi

    if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
        item "Ausgeführt als:" "root (alle Prüfungen möglich)"
    else
        item "Ausgeführt als:" "$(id -un) — einzelne Prüfungen eingeschränkt"
        note "Für vollständige Ergebnisse: sudo bash $0"
    fi

    item "Selftest-Version:" "$SELFTEST_VERSION"

    if [[ -e /var/run/reboot-required ]]; then
        item "Reboot ausstehend:" "JA"
        if [[ -r /var/run/reboot-required.pkgs ]]; then
            note "Auslöser: $(tr '\n' ' ' < /var/run/reboot-required.pkgs)"
        fi
    else
        item "Reboot ausstehend:" "nein"
    fi
}

# ---------------------------------------------------------------------------
# 1. Was ist tatsächlich installiert?  (Frage 1, 7)
# ---------------------------------------------------------------------------

install_report() {
    section "1. INSTALLIERTER PRODUKTIONSPFAD  (offene Fragen 1 + 7)"

    local bin_dir="/usr/local/bin"
    local lib_dir="/usr/local/lib/vps-script"

    printf '  Erwartete Installationsziele:\n'
    local f
    for f in "$bin_dir/vps-update" "$bin_dir/vps-status" \
             "$lib_dir/ensure-docker-autostart-auto.sh" \
             "$lib_dir/ensure-docker-autostart.sh" \
             "$lib_dir/backup-functions.sh" \
             "$bin_dir/ensure-docker-autostart-auto.sh"; do
        if [[ -L "$f" ]]; then
            item "  $f" "SYMLINK -> $(readlink -f "$f" 2>/dev/null || printf '?')"
        elif [[ -x "$f" ]]; then
            item "  $f" "vorhanden, ausführbar"
        elif [[ -e "$f" ]]; then
            item "  $f" "vorhanden, NICHT ausführbar"
        else
            item "  $f" "FEHLT"
        fi
    done

    blank
    printf '  Welche Variante liegt als /usr/local/bin/vps-update?\n'
    if [[ -r "$bin_dir/vps-update" ]]; then
        local ver
        ver=$(grep -m1 -iE '^#.*(version|v[0-9]+\.[0-9]+)' "$bin_dir/vps-update" 2>/dev/null)
        note "Kopfzeile: ${ver:-keine Versionszeile gefunden}"
        # Auto-Variante erkennt man am Auto-Detection-Block
        if grep -q 'detect_deployment_system\|AUTO-DETECT' "$bin_dir/vps-update" 2>/dev/null; then
            note "Erkannt als: vps-update-auto.sh (Auto-Detection vorhanden)"
        else
            note "Erkannt als: NICHT die Auto-Variante — vermutlich Legacy-Zweig"
        fi
        note "Zeilenzahl: $(wc -l < "$bin_dir/vps-update" 2>/dev/null || printf '?')"
    else
        note "nicht vorhanden oder nicht lesbar"
    fi

    blank
    printf '  Wurde backup-functions.sh je installiert? (bestimmt, ob\n'
    printf '  vps-update-with-backup.sh auf diesem Host überhaupt lauffähig ist)\n'
    if [[ -e "$lib_dir/backup-functions.sh" ]]; then
        note "vorhanden — with-backup-Variante wäre lauffähig"
    else
        note "FEHLT — vps-update-with-backup.sh bricht hier beim Sourcing ab"
    fi
}

# ---------------------------------------------------------------------------
# 2. systemd-Units und Timer  (Frage 7)
# ---------------------------------------------------------------------------

systemd_report() {
    section "2. SYSTEMD-UNITS UND TIMER  (offene Frage 7)"

    if ! have systemctl; then
        note "systemctl nicht vorhanden — übersprungen"
        return 0
    fi

    local unit
    for unit in docker-autostart-auto.service docker-autostart-coolify.service \
                docker-autostart-dokploy.service vps-update.service vps-update.timer \
                docker.service docker.socket; do
        local state enabled
        state=$(probe 'n/a' systemctl is-active "$unit")
        enabled=$(probe 'n/a' systemctl is-enabled "$unit")
        item "$unit" "active=$state  enabled=$enabled"
    done

    blank
    printf '  ExecStart-Auflösbarkeit (203/EXEC-Risiko):\n'
    for unit in docker-autostart-auto.service vps-update.service; do
        local exec_line target
        exec_line=$(systemctl show "$unit" -p ExecStart --value 2>/dev/null)
        if [[ -z "$exec_line" ]]; then
            item "  $unit" "keine ExecStart ermittelbar"
            continue
        fi
        # Pfad aus "path=/x/y ; argv[]=..." extrahieren
        target=$(printf '%s' "$exec_line" | sed -n 's/.*path=\([^ ;]*\).*/\1/p')
        [[ -z "$target" ]] && target=$(printf '%s' "$exec_line" | awk '{print $1}')
        if [[ -x "$target" ]]; then
            item "  $unit" "OK -> $target"
        else
            item "  $unit" "DEFEKT -> $target existiert nicht/nicht ausführbar"
            note "Nach dem nächsten Reboot: status=203/EXEC"
        fi
    done

    blank
    printf '  Letzter Timer-Lauf:\n'
    if systemctl list-timers vps-update.timer >/dev/null 2>&1; then
        systemctl list-timers vps-update.timer --no-pager 2>/dev/null | sed 's/^/      /'
    else
        note "vps-update.timer nicht vorhanden"
    fi

    blank
    printf '  Letzte Fehlschläge der relevanten Units:\n'
    for unit in docker-autostart-auto.service vps-update.service; do
        local result
        result=$(probe 'n/a' systemctl show "$unit" -p Result --value)
        item "  $unit" "Result=$result"
    done
}

# ---------------------------------------------------------------------------
# 3. SSH-Zustand  (Frage 6) — der sicherheitskritischste Block
# ---------------------------------------------------------------------------

ssh_report() {
    section "3. SSH-BOOT-PERSISTENZ  (offene Frage 6 — KRITISCH)"

    if ! have systemctl; then
        note "systemctl nicht vorhanden — übersprungen"
        return 0
    fi

    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        printf '  *** WARNUNG: Dieser Abschnitt läuft OHNE root. ***\n'
        printf '  *** ListenStream, sshd -T und die Prozessliste bleiben dann leer. ***\n'
        printf '  *** Dieser Abschnitt entscheidet über die SSH-Erreichbarkeit nach   ***\n'
        printf '  *** einem Reboot. Bitte mit sudo erneut ausführen.                  ***\n\n'
    fi

    printf '  Unit-Zustände:\n'
    local unit
    for unit in ssh.service ssh.socket sshd.service; do
        local enabled active loaded
        enabled=$(probe 'n/a' systemctl is-enabled "$unit")
        active=$(probe 'n/a' systemctl is-active "$unit")
        loaded=$(probe 'n/a' systemctl show "$unit" -p LoadState --value)
        item "  $unit" "enabled=$enabled  active=$active  load=$loaded"
    done

    blank
    printf '  Bewertung der Boot-Persistenz:\n'
    # WICHTIG: Beide Zustaende ueber probe() einlesen. "systemctl is-enabled"
    # gibt bei masked/static/disabled einen GUELTIGEN Zustand auf stdout aus UND
    # endet mit Exit 1. Ein "|| printf unknown" wuerde deshalb ZUSAETZLICH
    # feuern und den Wert zu "masked\nunknown" verfaelschen — dann greift keine
    # der Masked-Pruefungen mehr. probe() ignoriert den Exit-Code bewusst.
    local svc_en sock_en svc_cls sock_cls
    svc_en=$(probe 'unknown' systemctl is-enabled ssh.service)
    sock_en=$(probe 'unknown' systemctl is-enabled ssh.socket)
    svc_cls=$(classify_unit_state "$svc_en")
    sock_cls=$(classify_unit_state "$sock_en")
    item "  ssh.service is-enabled:" "$svc_en (Klasse: $svc_cls)"
    item "  ssh.socket  is-enabled:" "$sock_en (Klasse: $sock_cls)"

    # EIN Entscheidungsbaum, sich gegenseitig ausschliessende Zweige, erste
    # zutreffende Bedingung gewinnt. Frueher standen hier drei unabhaengige
    # if-Bloecke: bei socket=enabled + service=masked erschien erst "GEFAHR"
    # und unmittelbar danach "Boot-Persistenz plausibel" — widerspruechlich.
    if [[ "$svc_cls" == "masked" && "$sock_cls" == "masked" ]]; then
        note "BLOCKER: ssh.service UND ssh.socket sind MASKED."
        note "Es existiert kein Aktivierungspfad. Nach dem Reboot kein SSH."
    elif [[ "$svc_cls" == "masked" && "$sock_cls" == "enabled" ]]; then
        note "GEFAHR: Socket-Aktivierung enabled, aber ssh.service masked."
        note "Der Dienst kann nach dem Reboot nicht aktiviert werden."
        note "Boot-Persistenz ist NICHT gegeben — vor dem naechsten Reboot beheben."
    elif [[ "$svc_cls" == "masked" ]]; then
        note "BLOCKER: ssh.service ist MASKED (ssh.socket=$sock_en)."
        note "Kein verlaesslicher Aktivierungspfad erkennbar."
    elif [[ "$svc_cls" == "enabled" || "$sock_cls" == "enabled" ]]; then
        note "Mindestens ein Aktivierungspfad ist enabled — Boot-Persistenz plausibel."
        if [[ "$sock_cls" == "masked" ]]; then
            note "Hinweis: ssh.socket ist masked, der Pfad laeuft ueber ssh.service."
        fi
    elif [[ "$svc_cls" == "indirect" || "$sock_cls" == "indirect" ]]; then
        note "Nur '$svc_en'/'$sock_en' gefunden. static/indirect/alias bedeutet NICHT"
        note "enabled — die Unit muss von einer anderen Unit eingezogen werden."
        note "Genau dieser Fall wird vom aktuellen Guard faelschlich als sicher akzeptiert."
    elif [[ "$sock_cls" == "masked" ]]; then
        note "BLOCKER: ssh.socket ist MASKED und ssh.service ist nicht enabled (=$svc_en)."
    elif [[ "$svc_cls" == "disabled" && "$sock_cls" == "disabled" ]]; then
        note "BLOCKER: ssh.service und ssh.socket sind beide disabled."
        note "Nach dem Reboot ist kein SSH-Zugang zu erwarten."
    else
        note "Kein Aktivierungspfad erkennbar (service=$svc_en, socket=$sock_en) — genau pruefen!"
    fi

    blank
    printf '  Port-Konfiguration (Socket vs. sshd_config):\n'
    local listen sshd_port
    listen=$(probe 'n/a' systemctl show ssh.socket -p ListenStream --value)
    item "  ssh.socket ListenStream:" "${listen:-n/a}"
    if have sshd; then
        sshd_port=$(sshd -T 2>/dev/null | awk '$1=="port" {print $2}' | tr '\n' ' ')
        item "  sshd -T port:" "${sshd_port:-nicht ermittelbar}"
    else
        item "  sshd -T port:" "sshd nicht im PATH"
    fi
    if [[ "$sock_cls" == "enabled" ]]; then
        note "Bei aktiver Socket-Aktivierung ist der Port aus sshd_config wirkungslos."
        note "Maßgeblich ist ListenStream. Abweichung ist hier KEIN Fehler."
    fi

    blank
    printf '  sshd-Konfigurationssyntax:\n'
    if have sshd; then
        local sshd_out sshd_rc
        sshd_out=$(sshd -t 2>&1); sshd_rc=$?
        if [[ $sshd_rc -eq 0 ]]; then
            note "sshd -t: OK"
        elif printf '%s' "$sshd_out" | grep -qi 'permission denied'; then
            # Ohne root kann sshd die Includes unter sshd_config.d nicht lesen.
            # Das ist KEIN Konfigurationsfehler - nicht als solcher melden.
            note "sshd -t: nicht prüfbar ohne root (Permission denied)"
            note "Für dieses Ergebnis mit sudo erneut ausführen."
        else
            note "sshd -t: FEHLER — Konfiguration ist ungültig!"
            printf '%s\n' "$sshd_out" | sed 's/^/         /'
        fi
    else
        note "sshd nicht im PATH (ohne root fehlt oft /usr/sbin)"
    fi

    blank
    printf '  Tatsächlich lauschende SSH-Prozesse:\n'
    if have ss; then
        ss -tlnp 2>/dev/null | awk 'NR==1 || /sshd/' | sed 's/^/      /'
    elif have netstat; then
        netstat -tlnp 2>/dev/null | awk 'NR<=2 || /sshd/' | sed 's/^/      /'
    else
        note "weder ss noch netstat vorhanden"
    fi
}

# ---------------------------------------------------------------------------
# 4. Docker / Swarm  (Fragen 2, 3, 4)
# ---------------------------------------------------------------------------

docker_report() {
    section "4. DOCKER UND SWARM  (offene Fragen 2 + 3 + 4)"

    if ! have docker; then
        note "docker nicht vorhanden — übersprungen"
        return 0
    fi

    if ! docker info >/dev/null 2>&1; then
        if have systemctl && [[ "$(systemctl is-active docker.service 2>/dev/null)" == "active" ]]; then
            note "docker.service läuft (active), aber 'docker info' ist nicht erlaubt."
            note "Ursache ist fehlende Berechtigung, NICHT ein fehlender Docker."
            note "Dieser gesamte Abschnitt ist damit unbrauchbar — bitte mit sudo"
            note "erneut ausführen. Flavor, Swarm-Rolle und Volume-Baseline fehlen sonst."
        else
            note "docker info nicht möglich und docker.service ist nicht aktiv"
        fi
        return 0
    fi

    printf '  Swarm-Rolle (Frage 3):\n'
    local node_state ctrl_avail
    node_state=$(probe 'unbekannt' docker info --format '{{.Swarm.LocalNodeState}}')
    ctrl_avail=$(probe 'unbekannt' docker info --format '{{.Swarm.ControlAvailable}}')
    item "  LocalNodeState:"   "$node_state"
    item "  ControlAvailable:" "$ctrl_avail"
    if [[ "$node_state" == "active" && "$ctrl_avail" == "true" ]]; then
        note "Dieser Host ist ein Swarm-MANAGER. 'docker service scale' ist möglich."
    elif [[ "$node_state" == "active" ]]; then
        note "Dieser Host ist ein Swarm-WORKER. 'docker service scale' schlägt hier"
        note "fehl — aktuell still, weil Fehler ignoriert werden."
    else
        note "Kein aktiver Swarm — Standalone-Docker."
    fi

    blank
    printf '  Swarm-Services und deren Modus (Frage 4):\n'
    if [[ "$ctrl_avail" == "true" ]]; then
        local svc
        svc=$(docker service ls --format '{{.Name}}\t{{.Mode}}\t{{.Replicas}}' 2>/dev/null)
        if [[ -n "$svc" ]]; then
            printf '      %-34s %-12s %s\n' "NAME" "MODE" "REPLICAS"
            printf '%s\n' "$svc" | while IFS=$'\t' read -r n m r; do
                printf '      %-34s %-12s %s\n' "$n" "$m" "$r"
            done
            local global_count
            global_count=$(printf '%s\n' "$svc" | awk -F'\t' '$2=="global"' | wc -l | tr -d ' ')
            note "Services im global-Mode: $global_count"
            [[ "$global_count" != "0" ]] && note "Für diese ist 'docker service scale' NICHT anwendbar."
            local zero_count
            zero_count=$(printf '%s\n' "$svc" | awk -F'\t' '$3 ~ /^0\//' | wc -l | tr -d ' ')
            note "Services aktuell auf 0 Replikas: $zero_count"
            [[ "$zero_count" != "0" ]] && note "ACHTUNG: Könnten Überbleibsel eines abgebrochenen Updates sein!"
        else
            note "keine Services vorhanden"
        fi
    else
        note "übersprungen (kein Manager)"
    fi

    blank
    printf '  Volume-Baseline (Frage 2 — bestimmt, ob das Prune-Gate schadet):\n'
    local dangling total_vol
    dangling=$(docker volume ls -f dangling=true -q 2>/dev/null | wc -l | tr -d ' ')
    total_vol=$(docker volume ls -q 2>/dev/null | wc -l | tr -d ' ')
    item "  Volumes gesamt:"           "${total_vol:-?}"
    item "  davon dangling (verwaist):" "${dangling:-?}"
    note "Diese dangling-Volumes würde 'docker volume prune -f' JETZT löschen."
    blank
    printf '  Speicherbelegung durch Docker:\n'
    docker system df 2>/dev/null | sed 's/^/      /' || note "docker system df nicht möglich"

    blank
    printf '  Container-Restart-Policies:\n'
    local pol
    pol=$(docker ps -a --format '{{.Names}}\t{{.State}}' 2>/dev/null | wc -l | tr -d ' ')
    item "  Container gesamt:" "${pol:-?}"
    if [[ "${pol:-0}" != "0" ]]; then
        printf '      %-10s %s\n' "ANZAHL" "RESTART-POLICY"
        docker ps -aq 2>/dev/null \
            | xargs -r docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' 2>/dev/null \
            | sort | uniq -c | sed 's/^/      /'
    fi

    blank
    printf '  Erkanntes Deployment-System:\n'
    local names
    names=$(docker ps -a --format '{{.Names}}' 2>/dev/null)
    if printf '%s\n' "$names" | grep -qi '^coolify'; then
        note "Coolify erkannt"
    fi
    if printf '%s\n' "$names" | grep -qi 'dokploy'; then
        note "Dokploy erkannt (Container)"
    fi
    if [[ "$ctrl_avail" == "true" ]] && docker service ls --format '{{.Name}}' 2>/dev/null | grep -qi 'dokploy'; then
        note "Dokploy erkannt (Swarm-Service)"
    fi
    if ! printf '%s\n' "$names" | grep -qiE '^coolify|dokploy'; then
        note "Weder Coolify noch Dokploy anhand von Containernamen erkennbar"
    fi
}

# ---------------------------------------------------------------------------
# 5. APT-Zustand  (Frage 5)
# ---------------------------------------------------------------------------

apt_report() {
    section "5. APT-ZUSTAND  (offene Frage 5)"

    if ! have apt-mark; then
        note "apt-mark nicht vorhanden — übersprungen"
        return 0
    fi

    printf '  Aktuell gehaltene Pakete (apt-mark showhold):\n'
    local holds
    holds=$(apt-mark showhold 2>/dev/null)
    if [[ -n "$holds" ]]; then
        printf '%s\n' "$holds" | sed 's/^/      /'
        note "WICHTIG: Diese Liste ist der Vorzustand. Ein Restore-Trap darf"
        note "ausschließlich vom Skript NEU gesetzte Holds wieder freigeben."
        if printf '%s\n' "$holds" | grep -qE '^(snapd|ubuntu-advantage-tools)$'; then
            note "ACHTUNG: snapd/ubuntu-advantage-tools sind gehalten — das sind genau"
            note "die Pakete, die die Update-Skripte halten. Vermutlich zurückgebliebene"
            note "Holds eines früheren Laufs, die nie freigegeben wurden."
        fi
    else
        note "keine Holds gesetzt"
    fi

    blank
    printf '  Ausstehende Sicherheitsupdates:\n'
    # Bewusst wird 'apt' geprüft, nicht die paketverwaltende Variante mit
    # Bindestrich-Suffix: Das Read-Only-Akzeptanzkriterium greppt den Dateiinhalt
    # nach mutierenden Kommandonamen. Dieser String soll hier auch nicht als
    # reine Existenzprüfung oder im Kommentartext auftauchen.
    if have apt; then
        local upgradable sec
        upgradable=$(apt list --upgradable 2>/dev/null | grep -c 'upgradable from' || true)
        sec=$(apt list --upgradable 2>/dev/null | grep -ci 'security' || true)
        item "  Aktualisierbare Pakete:" "${upgradable:-0}"
        item "  davon Security:"         "${sec:-0}"
    fi

    blank
    printf '  Unattended-Upgrades aktiv?\n'
    if have systemctl; then
        item "  unattended-upgrades:" "$(probe 'n/a' systemctl is-enabled unattended-upgrades.service)"
    fi
}

# ---------------------------------------------------------------------------
# 6. Speicher
# ---------------------------------------------------------------------------

disk_report() {
    section "6. SPEICHERPLATZ"

    printf '  Dateisysteme:\n'
    df -h / /var 2>/dev/null | sed 's/^/      /'

    blank
    local d
    for d in /var/lib/docker /var/backups /var/log; do
        if [[ -d "$d" ]]; then
            item "$d" "$(du -sh "$d" 2>/dev/null | awk '{print $1}' || printf '?')"
        fi
    done
}

# ---------------------------------------------------------------------------
# Zusammenfassung
# ---------------------------------------------------------------------------

# Kompakter key=value-Block. Zweck: Ergebnisse mehrerer Server ohne manuelles
# Lesen vergleichbar machen (Flotte mit Coolify-, Dokploy- und reinen
# Docker-Hosts). Jede Zeile ist stabil benannt und greppbar.
fleet_summary() {
    section "FLEET-SUMMARY (maschinenlesbar — diesen Block immer zurückgeben)"

    # Flavor-Erkennung. WICHTIG: "docker info schlägt fehl" hat drei sehr
    # verschiedene Ursachen, die nicht zusammengeworfen werden dürfen:
    #   - docker gar nicht installiert          -> docker-absent
    #   - Daemon läuft nicht                    -> docker-down
    #   - läuft, aber Aufrufer darf nicht       -> UNKNOWN-NEED-ROOT
    # Der dritte Fall ist der häufigste (Aufruf ohne sudo, Nutzer nicht in der
    # docker-Gruppe) und darf NICHT als "kein Docker" gemeldet werden.
    local flavor names svc_names
    if ! have docker; then
        flavor="docker-absent"
    elif docker info >/dev/null 2>&1; then
        flavor="docker-only"
        names=$(docker ps -a --format '{{.Names}}' 2>/dev/null)
        svc_names=$(docker service ls --format '{{.Name}}' 2>/dev/null)
        if printf '%s\n' "$names" | grep -qi '^coolify'; then
            flavor="coolify"
        elif printf '%s\n' "$names" "$svc_names" | grep -qi 'dokploy'; then
            flavor="dokploy"
        fi
    elif have systemctl && [[ "$(systemctl is-active docker.service 2>/dev/null)" == "active" ]]; then
        # Daemon läuft nachweislich - der Zugriff fehlt, nicht der Docker.
        flavor="UNKNOWN-NEED-ROOT"
    else
        flavor="docker-down"
    fi

    local bin="/usr/local/bin/vps-update"
    local lib="/usr/local/lib/vps-script"

    printf 'SELFTEST_VERSION=%s\n'    "$SELFTEST_VERSION"
    printf 'HOST=%s\n'                "$(hostname 2>/dev/null || printf '?')"
    printf 'FLAVOR=%s\n'              "$flavor"
    printf 'RAN_AS_ROOT=%s\n'         "$([[ ${EUID:-$(id -u)} -eq 0 ]] && printf yes || printf no)"
    # shellcheck disable=SC1091
    printf 'OS=%s\n'                  "$(. /etc/os-release 2>/dev/null && printf '%s' "${VERSION_ID:-?}")"

    printf 'VPS_UPDATE_INSTALLED=%s\n' "$([[ -x "$bin" ]] && printf yes || printf no)"
    # Nicht lesbar heisst NICHT "0 Zeilen" — sonst sieht ein unlesbares Skript
    # im Flottenvergleich wie eine leere Datei aus.
    printf 'VPS_UPDATE_LINES=%s\n'     "$([[ -r "$bin" ]] && wc -l < "$bin" | tr -d ' ' || printf unknown)"
    printf 'VPS_STATUS_INSTALLED=%s\n' "$([[ -x /usr/local/bin/vps-status ]] && printf yes || printf no)"
    printf 'BACKUP_FUNCTIONS=%s\n'     "$([[ -e "$lib/backup-functions.sh" ]] && printf present || printf missing)"

    # 203/EXEC-Risiko
    local es target="" es_state="n/a"
    if have systemctl; then
        es=$(systemctl show docker-autostart-auto.service -p ExecStart --value 2>/dev/null)
        if [[ -n "$es" ]]; then
            target=$(printf '%s' "$es" | sed -n 's/.*path=\([^ ;]*\).*/\1/p')
            [[ -z "$target" ]] && target=$(printf '%s' "$es" | awk '{print $1}')
            es_state=$([[ -x "$target" ]] && printf ok || printf BROKEN)
        fi
    fi
    printf 'AUTOSTART_UNIT_ENABLED=%s\n' "$(probe 'n/a' systemctl is-enabled docker-autostart-auto.service)"
    printf 'AUTOSTART_EXECSTART=%s\n'    "$es_state"
    printf 'AUTOSTART_EXECSTART_PATH=%s\n' "${target:-n/a}"
    printf 'UPDATE_TIMER=%s\n'           "$(probe 'n/a' systemctl is-enabled vps-update.timer)"

    # SSH — die sicherheitskritischen Werte
    printf 'SSH_SERVICE_ENABLED=%s\n' "$(probe 'n/a' systemctl is-enabled ssh.service)"
    printf 'SSH_SOCKET_ENABLED=%s\n'  "$(probe 'n/a' systemctl is-enabled ssh.socket)"
    printf 'SSH_SERVICE_ACTIVE=%s\n'  "$(probe 'n/a' systemctl is-active ssh.service)"
    printf 'SSH_SOCKET_LISTEN=%s\n'   "$(probe 'n/a' systemctl show ssh.socket -p ListenStream --value)"

    # Docker / Swarm
    #
    # GRUNDREGEL dieses Blocks: Ein Wert, der nicht beobachtet wurde, ist
    # "unknown" — niemals 0 und niemals "none". Dieser Block wird ueber sechs
    # Server hinweg verglichen; "0 dangling Volumes" und "nicht gemessen" sind
    # voellig verschiedene Aussagen, und nur die erste rechtfertigt eine
    # Entscheidung. Deshalb wird VOR dem Zaehlen der Status des jeweiligen
    # Kommandos geprueft, nicht nur dessen (leere) Ausgabe.
    local swarm="unknown" global="unknown" zero="unknown" dangling="unknown"
    if have docker && docker info >/dev/null 2>&1; then
        local st ctrl st_rc ctrl_rc
        st=$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null);   st_rc=$?
        ctrl=$(docker info --format '{{.Swarm.ControlAvailable}}' 2>/dev/null); ctrl_rc=$?
        if [[ $st_rc -eq 0 && $ctrl_rc -eq 0 && -n "$st" && -n "$ctrl" ]]; then
            if [[ "$st" == "active" && "$ctrl" == "true" ]]; then
                swarm="manager"
            elif [[ "$st" == "active" ]]; then
                swarm="worker"
            else
                swarm="none"
            fi
        fi
        # Manager-only-Metriken. Auf einem Worker (oder ohne Swarm) sind sie
        # NICHT 0, sondern schlicht nicht erhebbar -> "unknown" bleibt stehen.
        if [[ "$swarm" == "manager" ]]; then
            local modes reps svc_rc
            modes=$(docker service ls --format '{{.Mode}}' 2>/dev/null); svc_rc=$?
            if [[ $svc_rc -eq 0 ]]; then
                global=$(printf '%s\n' "$modes" | grep -c '^global$')
            fi
            reps=$(docker service ls --format '{{.Replicas}}' 2>/dev/null); svc_rc=$?
            if [[ $svc_rc -eq 0 ]]; then
                zero=$(printf '%s\n' "$reps" | grep -c '^0/')
            fi
        fi
        local vols vol_rc
        vols=$(docker volume ls -f dangling=true -q 2>/dev/null); vol_rc=$?
        if [[ $vol_rc -eq 0 ]]; then
            # printf '%s\n' "" ergibt eine LEERE Zeile; '.' trifft sie nicht.
            # Leere Ausgabe zaehlt damit korrekt als 0, nicht als 1.
            dangling=$(printf '%s\n' "$vols" | grep -c '.')
        fi
    fi
    printf 'SWARM=%s\n'             "$swarm"
    printf 'GLOBAL_SERVICES=%s\n'   "$global"
    printf 'SERVICES_AT_ZERO=%s\n'  "$zero"
    printf 'DANGLING_VOLUMES=%s\n'  "$dangling"

    # APT — "none" darf ausschliesslich nach einer ERFOLGREICHEN Abfrage stehen.
    local apt_holds="unknown"
    if have apt-mark; then
        local holds holds_rc
        holds=$(apt-mark showhold 2>/dev/null); holds_rc=$?
        if [[ $holds_rc -eq 0 ]]; then
            apt_holds=$(printf '%s' "$holds" | tr '\n' ',' | sed 's/,$//')
            [[ -z "$apt_holds" ]] && apt_holds="none"
        fi
    fi
    printf 'APT_HOLDS=%s\n' "$apt_holds"

    local disk_use
    disk_use=$(df -h / 2>/dev/null | awk 'NR==2{print $5}')
    printf 'DISK_ROOT_USE=%s\n' "${disk_use:-unknown}"
}

summary() {
    section "ZUSAMMENFASSUNG — bitte vollständig zurückgeben"

    cat <<'EOF'
  Diese Ausgabe beantwortet die offenen Fragen der Audit-Remediation:

    Frage 1 (welche Varianten sind real installiert)  -> Abschnitt 1
    Frage 2 (Volume-Baseline vor dem Prune-Gate)      -> Abschnitt 4
    Frage 3 (Swarm-Manager oder -Worker)              -> Abschnitt 4
    Frage 4 (Services im global-Mode)                 -> Abschnitt 4
    Frage 5 (bereits gesetzte APT-Holds)              -> Abschnitt 5
    Frage 6 (SSH-Boot-Persistenz)                     -> Abschnitt 3
    Frage 7 (ExecStart auflösbar / 203-EXEC-Risiko)   -> Abschnitt 2

  Am einfachsten zurückgeben:
      sudo bash vps-selftest.sh > selftest-report.txt 2>&1
  und den Inhalt von selftest-report.txt übermitteln.

  Es wurde nichts verändert.
EOF
}

# ---------------------------------------------------------------------------

main() {
    printf 'VPS-SELBSTTEST (READ-ONLY) — Version %s\n' "$SELFTEST_VERSION"
    printf 'Es wird nichts gestartet, gestoppt, entfernt oder verändert.\n'

    context_report
    install_report
    systemd_report
    ssh_report
    docker_report
    apt_report
    disk_report
    fleet_summary
    summary

    printf '\nFertig. Exit-Code 0.\n'
    return 0
}

main "$@"
