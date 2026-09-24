#!/usr/bin/env bash
#
# test-logic.sh — Ebene 2b: stub-getriebene Funktionsprüfung (A0c)
#
# Extrahiert Funktionen aus vps-update-auto.sh und fährt sie gegen die
# gemessenen Flotten-Tupel (Inventur §2) plus Kontrollfälle — lauffähig auf
# macOS wie Linux, ohne Docker, ohne systemd, ohne root.
#
# Verwendung:
#     bash tools/test-logic.sh                   # alle Fallgruppen
#     bash tools/test-logic.sh --case ssh-guard  # eine Fallgruppe
#
# TEST_LOGIC_TARGET=<datei> prüft einen anderen Stand (z. B. eine per
# `git show <ref>:vps-update-auto.sh` ausgeleitete Kopie) — so lässt sich
# belegen, dass die Fälle auf dem ungepatchten Code rot sind.
#
# Exit 0 = alle Fälle grün · 1 = mindestens ein Fall rot · 2 = Werkzeugfehler
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
TARGET="${TEST_LOGIC_TARGET:-$REPO_ROOT/vps-update-auto.sh}"
readonly TARGET

die() { printf 'FEHLER: %s\n' "$1" >&2; exit 2; }

[[ -r "$TARGET" ]] || die "Zieldatei nicht lesbar: $TARGET"

CASE_FILTER=""
case "${1:-}" in
    --case)
        CASE_FILTER="${2:-}"
        [[ -n "$CASE_FILTER" ]] || die "--case braucht ein Argument"
        ;;
    "") ;;
    *) die "unbekannte Option: $1 (erlaubt: --case <fallgruppe>)" ;;
esac

WORKDIR=$(mktemp -d) || die "mktemp fehlgeschlagen"
trap 'rm -rf "$WORKDIR"' EXIT

PASS=0
FAIL=0

ok()   { printf '  gruen  %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  ROT    %s — %s\n' "$1" "$2"; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
# Fallgruppe ssh-guard: verify_ssh_before_reboot (A5)
#
# Stubs lesen ihre Daten aus T_*-Umgebungsvariablen; die echte Funktion wird
# unverändert aus der Zieldatei extrahiert. Die Tupel (sshd -T, ss -tlnp,
# ssh.socket, ssh.service) stammen aus der Inventur; K-1…K-4 sind die
# Kontrollfälle aus Plan-Abschnitt A5, P-1…P-3 die Rohzeilen-Parse-Fälle.
# ---------------------------------------------------------------------------

build_ssh_guard_runner() {
    local guard_src
    guard_src=$(awk '/^verify_ssh_before_reboot\(\)/,/^}/' "$TARGET")
    [[ -n "$guard_src" ]] || die "verify_ssh_before_reboot() nicht extrahierbar aus $TARGET"
    {
        cat <<'HEAD'
set -uo pipefail
log() {
    local level="$1"
    shift
    printf 'LOG %s %s\n' "$level" "$*"
}
sshd() {
    case "${1:-}" in
        -t) return 0 ;;
        -T) printf '%s\n' "$T_SSHD_T"; return 0 ;;
    esac
    return 0
}
ss() {
    [[ -n "$T_SS" ]] && printf '%s\n' "$T_SS"
    return 0
}
systemctl() {
    local unit="${2:-}" state=""
    case "$unit" in
        ssh.socket)  state="$T_SOCKET" ;;
        ssh.service) state="$T_SERVICE" ;;
    esac
    printf '%s\n' "$state"
    case "$state" in
        enabled|static) return 0 ;;
    esac
    return 1
}
HEAD
        printf '%s\n' "$guard_src"
        cat <<'FOOT'
verify_ssh_before_reboot
printf 'RC %s\n' "$?"
exit 0
FOOT
    } > "$WORKDIR/ssh-guard-runner.sh"
}

# Zeilenbauer im Original-Format von ss -tlnp (drei Adress-Schreibweisen)
sshd_line()    { printf 'LISTEN 0 128 0.0.0.0:%s 0.0.0.0:* users:(("sshd",pid=812,fd=3))' "$1"; }
systemd_line() { printf 'LISTEN 0 4096 *:%s *:* users:(("systemd",pid=1,fd=137))' "$1"; }
nginx_line()   { printf 'LISTEN 0 511 0.0.0.0:%s 0.0.0.0:* users:(("nginx",pid=990,fd=6))' "$1"; }

# Argumente: name, sshd-T-Ausgabe, ss-Ausgabe, socket-Zustand, service-Zustand,
#            Soll-rc, Soll-WARNING-Anzahl ('-' = nicht prüfen),
#            Pflichtmuster ('' = keins), verbotenes Muster ('' = keins)
run_ssh_guard() {
    local name="$1" conf="$2" ssout="$3" sock="$4" svc="$5"
    local exp_rc="$6" exp_warns="$7" req="$8" forb="$9"
    local out rc warns bad=""
    out=$(T_SSHD_T="$conf" T_SS="$ssout" T_SOCKET="$sock" T_SERVICE="$svc" \
        bash "$WORKDIR/ssh-guard-runner.sh" 2>&1)
    rc=$(printf '%s\n' "$out" | awk '$1 == "RC" {print $2; exit}')
    warns=$(printf '%s\n' "$out" | grep -c '^LOG WARNING' || true)
    if [[ "$rc" != "$exp_rc" ]]; then
        bad="rc=$rc (soll $exp_rc)"
    elif [[ "$exp_warns" != "-" && "$warns" != "$exp_warns" ]]; then
        bad="warnings=$warns (soll $exp_warns)"
    elif [[ -n "$req" ]] && ! printf '%s\n' "$out" | grep -qF "$req"; then
        bad="Pflichtmuster fehlt: $req"
    elif [[ -n "$forb" ]] && printf '%s\n' "$out" | grep -qF "$forb"; then
        bad="verbotenes Muster gefunden: $forb"
    fi
    if [[ -n "$bad" ]]; then
        fail "$name" "$bad"
        printf '%s\n' "$out" | sed 's/^/         | /'
    else
        ok "$name"
    fi
}

case_ssh_guard() {
    printf '=== Fallgruppe ssh-guard gegen: %s ===\n' "$TARGET"
    build_ssh_guard_runner
    local NL
    NL=$'\n'

    # Die sechs gemessenen Flotten-Tupel (Inventur §2)
    run_ssh_guard "lorini" \
        "port 2222" "$(sshd_line 2222)" disabled enabled 0 0 "" ""
    run_ssh_guard "vmd185359" \
        "port 2222" "$(sshd_line 2222)" enabled enabled 0 0 "" ""
    run_ssh_guard "vmd168409" \
        "port 2222" "$(sshd_line 2222)" disabled enabled 0 0 "" ""
    run_ssh_guard "vmd168223" \
        "port 22" "$(systemd_line 22)${NL}$(sshd_line 2222)" enabled enabled \
        0 1 "Port 2222 lauscht (sshd)" ""
    run_ssh_guard "vmd183199" \
        "port 22" "$(systemd_line 22)" enabled disabled 0 0 "" ""
    run_ssh_guard "vmd202656" \
        "port 22${NL}port 2223" "$(systemd_line 2223)" enabled disabled \
        0 1 "SSH-Port 22 aus sshd -T lauscht nicht" ""

    # Kontrollfälle
    run_ssh_guard "K-1-ausfall" \
        "port 22" "$(nginx_line 80)" enabled enabled 1 - "Kein SSH-Port lauscht" ""
    run_ssh_guard "K-2-masked" \
        "port 2222" "$(sshd_line 2222)" masked masked 1 - "" ""
    run_ssh_guard "K-3-sock-abweichend" \
        "port 22" "$(systemd_line 2224)" enabled disabled 0 - "Portzuordnung abweichend" ""
    run_ssh_guard "K-4-fremder-socket" \
        "port 22" "$(systemd_line 22)${NL}$(systemd_line 9090)" enabled disabled \
        0 0 "" "9090"

    # Rohzeilen-Parse (M-1 Punkt 4): [::]:PORT, *:PORT, fehlende users:-Spalte
    local raw1 raw2 raw3
    raw1="$(sshd_line 22)${NL}LISTEN 0 128 [::]:22 [::]:* users:((\"sshd\",pid=812,fd=4))${NL}$(systemd_line 2222)${NL}$(nginx_line 80)"
    run_ssh_guard "P-1-rohzeilen" \
        "port 2222" "$raw1" enabled disabled 0 1 "Port 22 lauscht (sshd)" ""
    raw2="LISTEN 0 128 0.0.0.0:22 0.0.0.0:*"
    run_ssh_guard "P-2-kein-root" \
        "port 22" "$raw2" enabled disabled 0 1 "Portzuordnung unvollst" ""
    raw3="LISTEN 0 128 [::]:2222 [::]:* users:((\"sshd\",pid=812,fd=3))"
    run_ssh_guard "P-3-nur-ipv6" \
        "port 2222" "$raw3" disabled enabled 0 0 "" ""
}

# ---------------------------------------------------------------------------
# Fallgruppe stack-verify: verify_coolify_services / verify_dokploy_services (N15)
#
# Beide Funktionen enden mit `[[ "$all_ok" == true ]] && log ...`. Ist all_ok
# false, wird der Status des gescheiterten Tests zum Rueckgabewert der Funktion
# — und weil sie jeweils die letzte Anweisung ihrer start_*_stack-Funktion ist,
# beendet der nackte Aufruf im case-Zweig unter `set -e` den GESAMTEN Lauf.
#
# Der Runner bildet das woertlich ab: `set -euo pipefail`, nackter Aufruf, und
# erst danach die Marke REACHED. Bricht die Funktion ab, fehlt die Marke — das
# ist derselbe Mechanismus, der am 04.08. auf vmd185359 status=1 erzeugte.
# ---------------------------------------------------------------------------

extract_fn() {
    local fn="$1" src
    src=$(awk "/^${fn}\\(\\)/,/^}/" "$TARGET")
    [[ -n "$src" ]] || die "${fn}() nicht extrahierbar aus $TARGET"
    printf '%s\n' "$src"
}

build_coolify_verify_runner() {
    {
        cat <<'HEAD'
set -euo pipefail
log() { local l="$1"; shift; printf 'LOG %s %s\n' "$l" "$*"; }
docker() {
    if [[ "$1 ${2:-}" == "ps --format" && -n "$T_PS" ]]; then
        printf '%s\n' "$T_PS"
    fi
    return 0
}
HEAD
        extract_fn verify_coolify_services
        cat <<'FOOT'
verify_coolify_services
printf 'RC %s\n' "$?"
printf 'REACHED\n'
exit 0
FOOT
    } > "$WORKDIR/coolify-verify-runner.sh"
}

build_dokploy_verify_runner() {
    {
        cat <<'HEAD'
set -euo pipefail
log() { local l="$1"; shift; printf 'LOG %s %s\n' "$l" "$*"; }
LOGFILE=/dev/null
IS_SWARM=true
DOKPLOY_SVC_POSTGRES=dokploy-postgres
DOKPLOY_SVC_REDIS=dokploy-redis
DOKPLOY_SVC_MAIN=dokploy
DOKPLOY_SVC_TRAEFIK=dokploy-traefik
docker() {
    if [[ "$1 ${2:-}" == "service ls" && -n "$T_SVC" ]]; then
        printf '%s\n' "$T_SVC"
    fi
    return 0
}
HEAD
        extract_fn verify_swarm_svc
        extract_fn verify_dokploy_services
        cat <<'FOOT'
verify_dokploy_services
printf 'RC %s\n' "$?"
printf 'REACHED\n'
exit 0
FOOT
    } > "$WORKDIR/dokploy-verify-runner.sh"
}

# Argumente: name, runner, T-Variablenname, T-Wert, Soll-WARNING-Anzahl
#            ('-' = nicht pruefen), Pflichtmuster (''), verbotenes Muster ('')
run_stack_verify() {
    local name="$1" runner="$2" tvar="$3" tval="$4"
    local exp_warns="$5" req="$6" forb="$7"
    local out warns bad=""
    out=$(env "$tvar=$tval" bash "$WORKDIR/$runner" 2>&1)
    warns=$(printf '%s\n' "$out" | grep -c '^LOG WARNING' || true)
    if ! printf '%s\n' "$out" | grep -qx 'REACHED'; then
        bad="Lauf abgebrochen — Funktion lieferte Nicht-Null (N15)"
    elif [[ "$exp_warns" != "-" && "$warns" != "$exp_warns" ]]; then
        bad="warnings=$warns (soll $exp_warns)"
    elif [[ -n "$req" ]] && ! printf '%s\n' "$out" | grep -qF "$req"; then
        bad="Pflichtmuster fehlt: $req"
    elif [[ -n "$forb" ]] && printf '%s\n' "$out" | grep -qF "$forb"; then
        bad="verbotenes Muster gefunden: $forb"
    fi
    if [[ -n "$bad" ]]; then
        fail "$name" "$bad"
        printf '%s\n' "$out" | sed 's/^/         | /'
    else
        ok "$name"
    fi
}

case_stack_verify() {
    printf '=== Fallgruppe stack-verify gegen: %s ===\n' "$TARGET"
    build_coolify_verify_runner
    build_dokploy_verify_runner
    local NL
    NL=$'\n'

    local coolify_alle
    coolify_alle="coolify-db${NL}coolify-redis${NL}coolify-realtime${NL}coolify${NL}coolify-proxy"

    # Sollzustand: alle fuenf oben -> Erfolgsmeldung, keine WARNING
    run_stack_verify "coolify-alle-oben" coolify-verify-runner.sh T_PS \
        "$coolify_alle" 0 "Coolify-Stack vollständig gestartet" ""

    # Der reale Fall vom 04.08.: Proxy braucht laenger als die 5 s aus
    # start_coolify_stack (:623). Er DARF den Lauf nicht beenden.
    run_stack_verify "coolify-proxy-verspaetet" coolify-verify-runner.sh T_PS \
        "coolify-db${NL}coolify-redis${NL}coolify-realtime${NL}coolify" \
        1 "Coolify Proxy läuft nicht" "vollständig gestartet"

    # Echter Ausfall des Hauptservice: ERROR im Log, trotzdem kein Abbruch
    run_stack_verify "coolify-hauptservice-aus" coolify-verify-runner.sh T_PS \
        "coolify-db${NL}coolify-redis${NL}coolify-realtime${NL}coolify-proxy" \
        0 "Coolify Hauptservice läuft nicht" "vollständig gestartet"

    # Totalausfall — der Extremfall darf ebenfalls nur protokollieren
    run_stack_verify "coolify-nichts-oben" coolify-verify-runner.sh T_PS \
        "" - "" "vollständig gestartet"

    # Dokploy/Swarm: dieselbe Mechanik ueber verify_swarm_svc
    local dokploy_alle
    dokploy_alle="dokploy-postgres 1/1${NL}dokploy-redis 1/1${NL}dokploy 1/1${NL}dokploy-traefik 1/1"

    run_stack_verify "dokploy-alle-oben" dokploy-verify-runner.sh T_SVC \
        "$dokploy_alle" 0 "Dokploy-Stack vollständig gestartet" ""

    # Ein Service noch bei 0/1 — der haeufige Fall Sekunden nach dem Scale-up
    run_stack_verify "dokploy-main-hochfahrend" dokploy-verify-runner.sh T_SVC \
        "dokploy-postgres 1/1${NL}dokploy-redis 1/1${NL}dokploy 0/1${NL}dokploy-traefik 1/1" \
        1 "nicht vollständig (0/1)" "Dokploy-Stack vollständig gestartet"

    # Service noch gar nicht gelistet
    run_stack_verify "dokploy-svc-fehlt" dokploy-verify-runner.sh T_SVC \
        "dokploy-postgres 1/1${NL}dokploy-redis 1/1${NL}dokploy-traefik 1/1" \
        1 "nicht gefunden" "Dokploy-Stack vollständig gestartet"
}

# ---------------------------------------------------------------------------
# Fallgruppe apt-update: kompletter Update-Pfad mit simuliertem Paketbestand.
# Eine neue Kernel-Version braucht ein neues Paket. Ohne --with-new-pkgs
# bleibt sie alt; bestehende Holds bleiben auch nach Fehlern unangetastet.
# Die Ergebniszahlen werden am Log des echten update_system() geprüft.
# ---------------------------------------------------------------------------

build_apt_update_runner() {
    {
        cat <<'HEAD'
set -euo pipefail
APT_HOLDS_ADDED=""
APT_OUTPUT_FILE=""
LOCKFILE="$T_DIR/update.lock"
log() { local level="$1"; shift; printf 'LOG %s %s\n' "$level" "$*"; }
phase_start() { :; }
phase_end() { :; }
wait_for_apt_lock() { return 0; }
apt() {
    [[ "$T_CASE" != list-error ]] || return 100
    [[ "$T_CASE" != headerless ]] && printf 'Listing...\n'
    [[ "$T_CASE" != empty ]] || return 0
    printf '%s\n' \
        'linux-generic/noble-updates 2 amd64 [upgradable from: 1]' \
        'snapd/noble-updates 2 amd64 [upgradable from: 1]' \
        'held-app/noble 2 amd64 [upgradable from: 1]'
}
apt-mark() {
    local action="${1:-}" pkg
    shift
    case "$action" in
        showhold)
            [[ "$T_CASE" != hold-read-error ]] || return 100
            cat "$T_DIR/holds"
            ;;
        hold)
            for pkg in "$@"; do
                grep -qxF "$pkg" "$T_DIR/holds" || printf '%s\n' "$pkg" >> "$T_DIR/holds"
            done
            ;;
        unhold)
            for pkg in "$@"; do
                awk -v pkg="$pkg" '$0 != pkg' "$T_DIR/holds" > "$T_DIR/holds.next"
                mv "$T_DIR/holds.next" "$T_DIR/holds"
            done
            ;;
        *) return 2 ;;
    esac
}
apt-get() {
    local new_allowed=false no_remove=false assume_yes=false
    local confdef=false confold=false action="" arg
    for arg in "$@"; do
        case "$arg" in
            --with-new-pkgs) new_allowed=true ;;
            --no-remove) no_remove=true ;;
            -y|--assume-yes) assume_yes=true ;;
            Dpkg::Options::=--force-confdef) confdef=true ;;
            Dpkg::Options::=--force-confold) confold=true ;;
            update|upgrade|autoremove|autoclean) action="$arg" ;;
        esac
    done
    case "$action" in
        update) return 0 ;;
        autoremove) [[ "$T_CASE" != autoremove-error ]]; return $? ;;
        autoclean) [[ "$T_CASE" != autoclean-error ]]; return $? ;;
        upgrade)
            [[ "$new_allowed" == true && "$no_remove" == true && "$assume_yes" == true \
                && "$confdef" == true && "$confold" == true \
                && "${LC_ALL:-}" == C && "${DEBIAN_FRONTEND:-}" == noninteractive ]] || {
                printf 'E: required APT options or locale missing\n' >&2
                return 99
            }
            [[ "$T_CASE" != empty ]] || return 100
            if [[ "$T_CASE" == signal ]]; then
                kill -TERM "$$"
                return 143
            fi
            printf 'The following packages will be upgraded:\n'
            if [[ "$T_CASE" == apt-error ]]; then
                printf '1 upgraded, 1 newly installed, 0 to remove and 2 not upgraded.\n'
                printf 'E: Failed to fetch package\n' >&2
                return 100
            fi
            if [[ "$T_CASE" == removed ]]; then
                printf '1 upgraded, 1 newly installed, 1 to remove and 0 not upgraded.\n'
                return 0
            fi
            if [[ "$T_CASE" == unknown ]]; then
                printf 'Unbekanntes APT-Ausgabeformat\n'
                return 0
            fi
            if [[ "$T_CASE" == nonnumeric ]]; then
                printf 'wrong upgraded, 1 newly installed, 0 to remove and 2 not upgraded.\n'
                return 0
            fi
            if [[ "$T_CASE" != dependency-held && "$T_CASE" != held ]]; then
                printf '2\n' > "$T_DIR/kernel-version"
                printf '2\n' > "$T_DIR/new-kernel"
                printf '1 upgraded, 1 newly installed, 0 to remove and 2 not upgraded.\n'
            else
                printf '0 upgraded, 0 newly installed, 0 to remove and 3 not upgraded.\n'
            fi
            return 0
            ;;
        *) return 2 ;;
    esac
}
tee() {
    if [[ "$T_CASE" == tee-error ]]; then
        cat
        return 1
    fi
    command tee "$@"
}
HEAD
        awk '/^parse_apt_summary\(\)/,/^}/' "$TARGET"
        extract_fn release_apt_holds
        extract_fn cleanup
        extract_fn update_system
        cat <<'FOOT'
trap cleanup EXIT
if update_system; then
    exit 0
else
    exit 1
fi
FOOT
    } > "$WORKDIR/apt-update-runner.sh"
}

run_apt_update() {
    local name="$1" exp_rc="$2" exp_version="$3" exp_counts="$4" exp_candidates="${5:-}"
    local dir="$WORKDIR/apt-$name" out rc counts success_counts candidate_count bad="" holds
    mkdir "$dir" "$dir/tmp"
    printf '1\n' > "$dir/kernel-version"
    printf 'held-app\n' > "$dir/holds.before"
    case "$name" in
        held) printf 'snapd\nubuntu-advantage-tools\n' >> "$dir/holds.before" ;;
        dependency-held) printf 'linux-generic\n' >> "$dir/holds.before" ;;
    esac
    cp "$dir/holds.before" "$dir/holds"
    local tmpdir="$dir/tmp"
    [[ "$name" == mktemp-error ]] && tmpdir="$dir/missing"
    out=$(T_CASE="$name" T_DIR="$dir" TMPDIR="$tmpdir" \
        "$BASH" "$WORKDIR/apt-update-runner.sh" 2>&1)
    rc=$?
    candidate_count=$(printf '%s\n' "$out" | sed -nE \
        's/^.* ([0-9]+) installierte Pakete mit Update-Kandidat gefunden:$/\1/p')
    counts=$(printf '%s\n' "$out" | sed -nE \
        's/^.*APT-Ergebnis: ([0-9]+) aktualisiert, ([0-9]+) neu installiert, ([0-9]+) entfernt, ([0-9]+) nicht aktualisiert$/\1 \2 \3 \4/p')
    success_counts=$(printf '%s\n' "$out" | sed -nE \
        's/^.*System-Updates abgeschlossen \(([0-9]+) Pakete aktualisiert, ([0-9]+) neue Pakete installiert\)$/\1 \2/p')
    holds=$(cat "$dir/holds")
    if [[ "$rc" != "$exp_rc" ]]; then
        bad="exit=$rc (soll $exp_rc)"
    elif [[ $(cat "$dir/kernel-version") != "$exp_version" ]]; then
        bad="Kernel-Abhängigkeit nicht wie erwartet aktualisiert"
    elif [[ "$exp_version" == 2 && ! -f "$dir/new-kernel" ]]; then
        bad="Kernel-Abhängigkeit fehlt"
    elif [[ "$counts" != "$exp_counts" ]]; then
        bad="APT-Ergebniszahlen=[$counts] (soll [$exp_counts])"
    elif [[ -n "$exp_candidates" && "$candidate_count" != "$exp_candidates" ]]; then
        bad="Kandidatenzahl=$candidate_count (soll $exp_candidates)"
    elif [[ -z "$exp_counts" ]] \
        && printf '%s\n' "$out" | grep -q '^LOG SUCCESS System-Updates abgeschlossen'; then
        bad="SUCCESS meldet Abschluss trotz unbekanntem APT-Ergebnis"
    elif [[ "$exp_counts" != '' && "$success_counts" != "$(printf '%s' "$exp_counts" | awk '{print $1, $2}')" ]]; then
        bad="SUCCESS-Zahlen=[$success_counts] stimmen nicht mit APT überein"
    elif [[ "$holds" != "$(cat "$dir/holds.before")" ]]; then
        bad="Holds nach dem Lauf verändert"
    elif compgen -G "$dir/tmp/vps-update-apt.*" >/dev/null; then
        bad="Temporäre APT-Ausgabe nach dem Lauf zurückgeblieben"
    elif [[ "$name" == unknown || "$name" == nonnumeric || "$name" == tee-error \
        || "$name" == held || "$name" == dependency-held || "$name" == hold-read-error ]] \
        && ! printf '%s\n' "$out" | grep -q '^LOG WARNING '; then
        bad="Offene Updates oder unbekanntes Ergebnis ohne Warnung"
    fi
    if [[ -n "$bad" ]]; then
        fail "$name" "$bad"
        printf '%s\n' "$out" | sed 's/^/         | /'
    else
        ok "$name"
    fi
}

case_apt_update() {
    printf '=== Fallgruppe apt-update gegen: %s ===\n' "$TARGET"
    build_apt_update_runner
    run_apt_update headerless 0 2 '1 1 0 2' 3
    run_apt_update held 0 1 '0 0 0 3' 3
    run_apt_update dependency-held 0 1 '0 0 0 3' 3
    run_apt_update hold-read-error 0 2 '1 1 0 2' 3
    run_apt_update empty 0 1 ''
    run_apt_update list-error 1 1 ''
    run_apt_update apt-error 1 1 ''
    run_apt_update removed 1 1 ''
    run_apt_update unknown 0 1 ''
    run_apt_update nonnumeric 0 1 ''
    run_apt_update tee-error 0 2 ''
    run_apt_update mktemp-error 1 1 ''
    run_apt_update autoremove-error 0 2 '1 1 0 2' 3
    run_apt_update autoclean-error 0 2 '1 1 0 2' 3
    run_apt_update signal 143 1 ''
}

# ---------------------------------------------------------------------------

case "$CASE_FILTER" in
    "") case_ssh_guard; printf '\n'; case_stack_verify; printf '\n'; case_apt_update ;;
    ssh-guard) case_ssh_guard ;;
    stack-verify) case_stack_verify ;;
    apt-update) case_apt_update ;;
    *) die "unbekannte Fallgruppe: $CASE_FILTER (vorhanden: ssh-guard, stack-verify, apt-update)" ;;
esac

printf '\nErgebnis: %s gruen, %s rot\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]] || exit 1
exit 0
