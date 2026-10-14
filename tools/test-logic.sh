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

# Wie extract_fn, aber ohne die(): Für Funktionen, die erst in einem neueren
# Stand existieren. Fehlt die Funktion im Ziel (z. B. TEST_LOGIC_TARGET auf
# einen Stand vor v2.2), liefert der Aufruf nichts zurück und der Aufrufer
# legt einen No-Op-Stub nach — sonst stürbe der historische Lauf in extract_fn
# ab, BEVOR irgendeine Assertion die Fälle rot machen könnte
# (Codex-Review 13.10.2026, B2).
extract_fn_optional() {
    local fn="$1" src
    src=$(awk "/^${fn}\\(\\)/,/^}/" "$TARGET")
    [[ -n "$src" ]] || return 1
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
# Fallgruppe apt-lock: wait_for_apt_lock + Pre-Flight-Reihenfolge in main()
#
# Vorfall 04.10.2026 (vmd168409, Mailcow): main() stoppte ALLE Container,
# bevor update_system() auf den apt-Lock wartete. Ein anderer Prozess
# (unattended-upgrades) hielt den Lock länger als 300s — Ergebnis:
# 5:40 min Mail-Downtime, Abbruch ohne Update, Notfall-Restart.
#
# Seit v2.2 wartet main() VOR dem Container-Stopp. Geprüft wird beides
# getrennt:
#   - wait_for_apt_lock selbst: free / busy / busy-dann-frei, inkl.
#     Lock-Inhaber-Diagnose (fuser + ps sind gestubbt)
#   - main()-Reihenfolge: Lock-busy beendet den Lauf, OHNE dass
#     stop_docker_containers je markiert wird
# ---------------------------------------------------------------------------

build_apt_lock_runner() {
    {
        cat <<'HEAD'
set -euo pipefail
APT_LOCK_WAIT=3
APT_LOCK_INTERVAL=1
log() { local level="$1"; shift; printf 'LOG %s %s\n' "$level" "$*"; }
FUSER_CALLS=0
fuser() {
    case "${T_FUSER:-free}" in
        free) return 1 ;;
        busy) printf '4242\n'; return 0 ;;
        # Regelfall Vorfall 04.10.2026: EIN Prozess hält mehrere Lock-Dateien,
        # fuser meldet ihn mehrfach (Codex-Review 13.10.2026, B1)
        dupe) printf '4242 4242\n'; return 0 ;;
        multi) printf '1111 2222 1111\n'; return 0 ;;
        busy2free)
            FUSER_CALLS=$((FUSER_CALLS + 1))
            if [[ $FUSER_CALLS -le 2 ]]; then printf '4242\n'; return 0; fi
            return 1
            ;;
        *) return 1 ;;
    esac
}
# Argumentvertrag des Produzenten: procps-ps akzeptiert nur EINE
# kommagetrennte -p-Liste ohne Duplikate. Der Stub erzwingt exakt das —
# leere, gedoppelte oder falsch geformte Aufrufe werden rot, statt wie
# bisher bedingungslos grün durchzuwinken (Codex-Review 13.10.2026, B1/B8).
ps() {
    [[ "${1:-}" == "-p" ]] || { printf 'ps-stub: Vertrag verletzt (erwartet: -p CSV -o fmt): %s\n' "$*" >&2; return 2; }
    [[ "${2:-}" =~ ^[0-9]+(,[0-9]+)*$ ]] || { printf 'ps-stub: keine CSV-PID-Liste: %s\n' "${2:-}" >&2; return 2; }
    [[ "$#" -eq 4 && "${3:-}" == "-o" && "${4:-}" == "pid=,user=,etime=,comm=" ]] || { printf 'ps-stub: Argumente nach -p CSV falsch: %s\n' "$*" >&2; return 2; }
    local p seen=""
    local IFS=','
    for p in $2; do
        [[ ",$seen," == *",$p,"* ]] && { printf 'ps-stub: doppelte PID im CSV: %s\n' "$2" >&2; return 2; }
        seen="${seen:+$seen,}$p"
        printf '  %s root     05:30 %s\n' "$p" "${T_COMM:-unattended-upgr}"
    done
}
sleep() { printf 'x' >> "$T_DIR/ticks"; }
HEAD
        extract_fn_optional apt_lock_holders || printf 'apt_lock_holders() { return 1; }\n'
        extract_fn_optional log_lock_holders || printf 'log_lock_holders() { return 0; }\n'
        extract_fn wait_for_apt_lock
        cat <<'FOOT'
wait_for_apt_lock
FOOT
    } > "$WORKDIR/apt-lock-runner.sh"
}

build_main_order_runner() {
    {
        cat <<'HEAD'
set -euo pipefail
DEPLOYMENT_SYSTEM="none"
DEPLOYMENT_PATH=""
SECONDS=0
log() { local level="$1"; shift; printf 'LOG %s %s\n' "$level" "$*"; }
mark() { printf '%s\n' "$1" >> "$T_DIR/order"; }
format_duration() { printf '%ss' "$1"; }
check_prerequisites() { mark prereq; }
check_disk_space() { mark disk; }
wait_for_apt_lock() {
    mark lock
    if [[ "${T_LOCK:-}" == busy ]]; then return 1; fi
    return 0
}
stop_docker_containers() { mark stop; }
update_system() {
    mark update
    if [[ "${T_UPDATE:-}" == fail ]]; then return 1; fi
    return 0
}
emergency_restart() { mark emergency; }
show_final_status() { mark final; }
docker_cleanup() { mark cleanup; return 0; }
start_deployment_stack() { mark stack; }
start_other_containers() { mark other; }
check_container_health() { mark health; }
security_check() { mark security; }
check_reboot_required() { mark reboot; return 0; }
show_summary() { mark summary; }
HEAD
        extract_fn main
        cat <<'FOOT'
main
FOOT
    } > "$WORKDIR/main-order-runner.sh"
}

# Gemeinsame Assertions: Soll-Exit-Code, Muss-Muster (';'-getrennt, ALLE
# gefordert), Verbot-Muster (';'-getrennt, KEINES erlaubt), Soll-Tick-Anzahl
# der sleep-Aufrufe ('' = nicht prüfen).
check_run_output() {
    # Argumente: name, ausgabe, soll-rc, ist-rc, must, forbid, ticks-file, exp-ticks
    local name="$1" out="$2" exp_rc="$3" rc="$4" must="$5" forbid="$6"
    local ticks_file="$7" exp_ticks="$8" bad="" m
    if [[ "$rc" != "$exp_rc" ]]; then
        bad="exit=$rc (soll $exp_rc)"
    fi
    if [[ -z "$bad" ]]; then
        local IFS=';'
        for m in $must; do
            [[ -n "$m" ]] || continue
            printf '%s\n' "$out" | grep -Eq "$m" || { bad="fehlt Muster: $m"; break; }
        done
    fi
    if [[ -z "$bad" ]]; then
        local IFS=';'
        for m in $forbid; do
            [[ -n "$m" ]] || continue
            printf '%s\n' "$out" | grep -Eq "$m" && { bad="enthält verbotenes Muster: $m"; break; }
        done
    fi
    if [[ -z "$bad" && -n "$exp_ticks" ]]; then
        local ticks
        # Fehlende Datei = nie geschlafen = 0 Ticks; sonst Bytes zählen
        # (sleep-Stub hängt pro Aufruf ein 'x' an)
        ticks=0
        [[ -f "$ticks_file" ]] && ticks=$(wc -c < "$ticks_file" | tr -d '[:space:]')
        [[ "$ticks" == "$exp_ticks" ]] || bad="sleep-Ticks=[$ticks] (soll [$exp_ticks])"
    fi
    if [[ -n "$bad" ]]; then
        fail "$name" "$bad"
        printf '%s\n' "$out" | sed 's/^/         | /'
    else
        ok "$name"
    fi
}

run_apt_lock() {
    # Argumente: name, Soll-rc, Muss-Muster, Verbot-Muster, Soll-Ticks
    local name="$1" exp_rc="$2" must="$3" forbid="$4" exp_ticks="${5:-}"
    local dir="$WORKDIR/lock-$name" out rc
    mkdir "$dir"
    out=$(T_FUSER="$name" T_DIR="$dir" "$BASH" "$WORKDIR/apt-lock-runner.sh" 2>&1)
    rc=$?
    check_run_output "$name" "$out" "$exp_rc" "$rc" "$must" "$forbid" "$dir/ticks" "$exp_ticks"
}

run_main_order() {
    # Argumente: name, T_LOCK-Wert, Soll-rc, Soll-Reihenfolge (';'), Muss, Verbot
    local name="$1" lock="$2" exp_rc="$3" expected="$4" must="${5:-}" forbid="${6:-}"
    local dir="$WORKDIR/order-$name" out rc order want bad
    mkdir "$dir"
    out=$(T_LOCK="$lock" T_DIR="$dir" "$BASH" "$WORKDIR/main-order-runner.sh" 2>&1)
    rc=$?
    order=$(cat "$dir/order" 2>/dev/null || true)
    want=$(printf '%s\n' "$expected" | tr ';' '\n')
    if [[ "$order" != "$want" ]]; then
        fail "$name" "Reihenfolge=[$(printf '%s' "$order" | tr '\n' ';')] (soll [$expected])"
        printf '%s\n' "$out" | sed 's/^/         | /'
        return
    fi
    check_run_output "$name" "$out" "$exp_rc" "$rc" "$must" "$forbid" "" ""
}

case_apt_lock() {
    printf '=== Fallgruppe apt-lock gegen: %s ===\n' "$TARGET"
    build_apt_lock_runner
    build_main_order_runner
    run_apt_lock free 0 \
        'Apt-Lock verfügbar' \
        'belegt durch;Lock-Inhaber;Warte auf' \
        0
    run_apt_lock busy2free 0 \
        'Apt-Lock belegt durch.*unattended-upgr;Warte auf apt-Lock\.\.\. \(1/3s\);Apt-Lock verfügbar' \
        'Lock-Inhaber' \
        2
    run_apt_lock busy 1 \
        'konnte nach 3s nicht erhalten;Lock-Inhaber.*unattended-upgr;Warte auf apt-Lock\.\.\. \(2/3s\)' \
        'Apt-Lock verfügbar' \
        3
    run_apt_lock dupe 1 \
        'belegt durch.*4242.*unattended-upgr;Lock-Inhaber.*4242.*unattended-upgr;konnte nach 3s nicht erhalten' \
        'Apt-Lock verfügbar;Vertrag verletzt;doppelte PID' \
        3
    run_apt_lock multi 1 \
        'belegt durch.*1111.*unattended-upgr;Lock-Inhaber.*2222.*unattended-upgr;konnte nach 3s nicht erhalten' \
        'Apt-Lock verfügbar;Vertrag verletzt;doppelte PID' \
        3
    run_main_order ok free 0 \
        'prereq;disk;lock;stop;update;cleanup;stack;other;health;final;security;reboot;summary' \
        '' \
        'mit Fehlern abgebrochen'
    run_main_order lock-busy busy 1 \
        'prereq;disk;lock' \
        'Abbruch vor dem Container-Stopp' \
        'Notfall'
}

build_security_check_runner() {
    {
        cat <<'HEAD'
set -euo pipefail
SECONDS=0
LOGFILE=/dev/null
BLUE=""; GREEN=""; YELLOW=""; RED=""; CYAN=""; NC=""
# Stubs mit Argument-Vertrag (Codex B9): Verstöße gegen den Produzenten-
# Vertrag (falsche/fehlende Argumente) werden rot, statt still grün.
journalctl() {
    local have_since=0 have_comm=0 a
    for a in "$@"; do
        [[ "$a" == "--since" ]] && have_since=1
        [[ "$a" == "_COMM=sshd" ]] && have_comm=1
    done
    if [[ $have_since -eq 0 || $have_comm -eq 0 ]]; then
        printf 'journalctl-stub: Vertrag verletzt (erwartet --since + _COMM=sshd): %s\n' "$*" >&2
        return 22
    fi
    case "${T_JOURNAL:-ok}" in
        ok)
            local i
            for ((i = 0; i < ${T_JOURNAL_N:-0}; i++)); do
                printf 'Okt 14 10:00:00 host sshd[1]: Invalid user admin from 10.0.0.9\n'
            done
            ;;
        broken) printf 'Verbindung zum Journal fehlgeschlagen\n' >&2; return 1 ;;
    esac
    return 0
}
ss() {
    case "$*" in
        -tln)
            if [[ "${T_SS_BROKEN:-0}" == "1" ]]; then return 1; fi
            printf '%s\n' "${T_SS_LISTEN}"
            ;;
        -tlnp)
            printf '%s\n' "${T_SS_PROC}"
            ;;
        *)
            printf 'ss-stub: Vertrag verletzt (erwartet genau -tln oder -tlnp): %s\n' "$*" >&2
            return 22
            ;;
    esac
}
who() { printf 'shogun pts/0\nroot pts/1\n'; }
ufw() { printf 'Status: %s\n' "${T_UFW:-active}"; }
last() { printf 'root pts/0 1.2.3.4 Wed Okt 14 10:00 - 10:30 (00:30)\n'; }
sshd() {
    # Argumentvertrag: -T [-f <config>]; Werte pro Config-Basename
    local mode="${T_SSHD_T:-ok}" cfg=""
    if [[ "${1:-}" != "-T" ]]; then
        printf 'sshd-stub: Vertrag verletzt (erwartet -T ...): %s\n' "$*" >&2
        return 22
    fi
    cfg=$(printf '%s\n' "$*" | awk '{for (i=1; i<=NF; i++) if ($i=="-f") print $(i+1)}')
    [[ -z "$cfg" ]] && cfg="sshd_config"
    if [[ "${cfg##*/}" != "sshd_config" && -n "${T_SSHD_ALT:-}" ]]; then
        mode="$T_SSHD_ALT"
    fi
    case "$mode" in
        ok)     printf 'port 22\npasswordauthentication no\npermitrootlogin without-password\n' ;;
        open)   printf 'port 22\npasswordauthentication yes\npermitrootlogin yes\n' ;;
        broken) printf 'kann Konfiguration nicht lesen\n' >&2; return 1 ;;
    esac
}
systemctl() {
    # Realistische Exit-Codes: active/reloading/waiting/enabled→0,
    # inactive/failed/disabled→3, Unit fehlt→4 (Codex B9)
    local unit="$2" verb="$1" state
    case "$verb $unit" in
        "is-active fail2ban")                  state="${T_F2B:-active}" ;;
        "is-active apt-daily-upgrade.timer")   state="${T_UU_TIMER_ACT:-waiting}" ;;
        "is-enabled apt-daily-upgrade.timer")  state="${T_UU_TIMER_EN:-enabled}" ;;
        "is-active apt-daily-upgrade.service") state="${T_UU_EXEC:-active}" ;;
        *) printf 'systemctl-stub: unerwarteter Aufruf: %s\n' "$*" >&2; return 22 ;;
    esac
    case "$state" in
        active|reloading|waiting|enabled) printf '%s\n' "$state"; return 0 ;;
        missing) return 4 ;;
        *) printf '%s\n' "$state"; return 3 ;;
    esac
}
HEAD
        extract_fn log
        extract_fn phase_start
        extract_fn phase_end
        extract_fn security_check
        cat <<'FOOT'
security_check
FOOT
    } > "$WORKDIR/sec-check-runner.sh"
}

run_sec() {
    # Argumente: name, Muss-Muster, Verbot-Muster; T_*-Variablen vom Aufrufer
    local name="$1" must="$2" forbid="${3:-}" out rc
    local dir="$WORKDIR/sec-$name"
    mkdir "$dir"
    out=$(T_JOURNAL="${T_JOURNAL:-ok}" T_JOURNAL_N="${T_JOURNAL_N:-0}" \
        T_SS_LISTEN="${T_SS_LISTEN}" T_SS_PROC="${T_SS_PROC}" \
        T_SS_BROKEN="${T_SS_BROKEN:-0}" T_SSHD_T="${T_SSHD_T:-ok}" \
        T_SSHD_ALT="${T_SSHD_ALT:-}" T_F2B="${T_F2B:-active}" \
        T_UU_TIMER_ACT="${T_UU_TIMER_ACT:-waiting}" \
        T_UU_TIMER_EN="${T_UU_TIMER_EN:-enabled}" \
        T_UU_EXEC="${T_UU_EXEC:-active}" \
        VPS_SSHD_CONFIGS="$VPS_SSHD_CONFIGS" \
        "$BASH" "$WORKDIR/sec-check-runner.sh" 2>&1)
    rc=$?
    check_run_output "$name" "$out" 0 "$rc" "$must" "$forbid" "" ""
}

SEC_LISTEN_MIXED='State Recv-Q Send-Q Local Address:Port Peer Address:Port
LISTEN 0 128 0.0.0.0:22 0.0.0.0:*
LISTEN 0 128 127.0.0.1:8123 0.0.0.0:*
LISTEN 0 128 [::]:443 [::]:*
LISTEN 0 128 [::1]:6379 [::]:*
LISTEN 0 4096 *:2223 *:*'
SEC_LISTEN_LOOPBACK='State Recv-Q Send-Q Local Address:Port Peer Address:Port
LISTEN 0 128 127.0.0.1:8123 0.0.0.0:*
LISTEN 0 128 [::1]:6379 [::]:*'
SEC_LISTEN_DUP='State Recv-Q Send-Q Local Address:Port Peer Address:Port
LISTEN 0 128 127.0.0.1:8080 0.0.0.0:*
LISTEN 0 128 203.0.113.5:8080 0.0.0.0:*'
SEC_PROC_MIXED='LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=900,fd=3))
LISTEN 0 128 127.0.0.1:8123 0.0.0.0:* users:(("localadmin",pid=901,fd=4))
LISTEN 0 128 [::]:443 [::]:* users:(("traefik",pid=902,fd=9))
LISTEN 0 128 [::1]:6379 [::]:* users:(("redis",pid=903,fd=6))
LISTEN 0 4096 *:2223 *:* users:(("sshd",pid=904,fd=3))'
SEC_PROC_DUP='LISTEN 0 128 127.0.0.1:8080 0.0.0.0:* users:(("localadmin",pid=901,fd=4))
LISTEN 0 128 203.0.113.5:8080 0.0.0.0:* users:(("app",pid=905,fd=4))'

case_security_check() {
    printf '=== Fallgruppe security-check gegen: %s ===\n' "$TARGET"
    build_security_check_runner
    # Fake-Config-Baum für die SSH-Instanz-Schleife (VPS_SSHD_CONFIGS-Hook)
    local cfgdir="$WORKDIR/sshd-cfg"
    mkdir -p "$cfgdir"
    : > "$cfgdir/sshd_config"
    VPS_SSHD_CONFIGS="$cfgdir/sshd_config"

    # Flotten-Frühling: alles grün, Wildcard-Listener erscheint,
    # Loopback-Ports und ihre Services dürfen nicht erscheinen
    T_SS_LISTEN="$SEC_LISTEN_MIXED" T_SS_PROC="$SEC_PROC_MIXED" T_JOURNAL_N=50 \
        run_sec fleet-green \
        '50 fehlgeschlagene SSH-Versuche \(normal\);0\.0\.0\.0:22 \(sshd\);\*:2223 \(sshd\);3 öffentliche Listener;SSH sshd_config: PasswordAuth=no PermitRootLogin=without-password;fail2ban: aktiv;unattended-upgrades: Timer aktiv' \
        'WARNING;8123;6379;Vertrag verletzt'
    T_SS_LISTEN="$SEC_LISTEN_MIXED" T_SS_PROC="$SEC_PROC_MIXED" T_JOURNAL_N=0 \
        run_sec zero-attacks \
        'Keine fehlgeschlagenen SSH-Versuche' \
        'WARNING'
    T_SS_LISTEN="$SEC_LISTEN_MIXED" T_SS_PROC="$SEC_PROC_MIXED" T_JOURNAL_N=1500 \
        run_sec high-attacks \
        'Hohe Angriffslast: 1500' \
        'nicht ermittelbar'
    T_SS_LISTEN="$SEC_LISTEN_MIXED" T_SS_PROC="$SEC_PROC_MIXED" T_JOURNAL=broken \
        run_sec journal-broken \
        'SSH-Angriffe nicht ermittelbar' \
        'Keine fehlgeschlagenen'
    T_SS_LISTEN="$SEC_LISTEN_LOOPBACK" T_SS_PROC="$SEC_PROC_MIXED" T_JOURNAL_N=0 \
        run_sec all-loopback \
        'Keine öffentlich gebundenen Ports' \
        '8123;6379'
    # Codex B4: ss-Ausfall darf nicht als „keine Ports" grün werden
    T_SS_LISTEN="$SEC_LISTEN_MIXED" T_SS_PROC="$SEC_PROC_MIXED" T_JOURNAL_N=0 T_SS_BROKEN=1 \
        run_sec ss-broken \
        'Portliste nicht ermittelbar' \
        'Keine öffentlich gebundenen'
    # Codex B7: gleicher Port, unterschiedliche Bindung — Service muss zur
    # öffentlichen Bindung (app) gehören, nicht zur Loopback-Zeile (localadmin)
    T_SS_LISTEN="$SEC_LISTEN_DUP" T_SS_PROC="$SEC_PROC_DUP" T_JOURNAL_N=0 \
        run_sec dup-binding \
        '203\.0\.113\.5:8080 \(app\)' \
        'localadmin'
    # Codex B2: zweite SSH-Config mit PA=yes muss namentlich auffallen
    : > "$cfgdir/sshd_config_2222"
    VPS_SSHD_CONFIGS="$cfgdir/sshd_config $cfgdir/sshd_config_2222"
    T_SS_LISTEN="$SEC_LISTEN_MIXED" T_SS_PROC="$SEC_PROC_MIXED" T_JOURNAL_N=0 T_SSHD_ALT=open \
        run_sec sshd-alt-open \
        'SSH sshd_config_2222: PasswordAuth=yes.*Flottenregel' \
        'SSH sshd_config_2222: PasswordAuth=no'
    T_SS_LISTEN="$SEC_LISTEN_MIXED" T_SS_PROC="$SEC_PROC_MIXED" T_JOURNAL_N=0 T_SSHD_ALT=broken \
        run_sec sshd-alt-broken \
        'SSH-Config sshd_config_2222 nicht prüfbar' \
        'Flottenregel'
    rm -f "$cfgdir/sshd_config_2222"
    VPS_SSHD_CONFIGS="$cfgdir/sshd_config"
    # Codex B8: reloading gilt systemd als aktiv
    T_SS_LISTEN="$SEC_LISTEN_MIXED" T_SS_PROC="$SEC_PROC_MIXED" T_JOURNAL_N=0 T_F2B=reloading \
        run_sec f2b-reloading \
        'fail2ban: aktiv' \
        'Bruteforce-Schutz fehlt'
    T_SS_LISTEN="$SEC_LISTEN_MIXED" T_SS_PROC="$SEC_PROC_MIXED" T_JOURNAL_N=0 T_F2B=inactive \
        run_sec f2b-inactive \
        'fail2ban: inactive.*Bruteforce-Schutz fehlt' \
        'fail2ban: aktiv'
    # Codex B3: Ausführungs-Dienst failed / Timer disabled / Messausfall
    T_SS_LISTEN="$SEC_LISTEN_MIXED" T_SS_PROC="$SEC_PROC_MIXED" T_JOURNAL_N=0 T_UU_EXEC=failed \
        run_sec uu-exec-failed \
        'Ausführungs-Dienst=failed' \
        'Timer aktiv'
    T_SS_LISTEN="$SEC_LISTEN_MIXED" T_SS_PROC="$SEC_PROC_MIXED" T_JOURNAL_N=0 T_UU_TIMER_EN=disabled T_UU_TIMER_ACT=inactive \
        run_sec uu-disabled \
        'Timer=disabled' \
        'Timer aktiv'
    T_SS_LISTEN="$SEC_LISTEN_MIXED" T_SS_PROC="$SEC_PROC_MIXED" T_JOURNAL_N=0 T_UU_EXEC=missing \
        run_sec uu-measfail \
        'Ausführungs-Dienst=fehlt' \
        'Timer aktiv'
}


case "$CASE_FILTER" in
    "") case_ssh_guard; printf '\n'; case_stack_verify; printf '\n'; case_apt_update; printf '\n'; case_apt_lock; printf '\n'; case_security_check ;;
    ssh-guard) case_ssh_guard ;;
    stack-verify) case_stack_verify ;;
    apt-update) case_apt_update ;;
    apt-lock) case_apt_lock ;;
    security-check) case_security_check ;;
    *) die "unbekannte Fallgruppe: $CASE_FILTER (vorhanden: ssh-guard, stack-verify, apt-update, apt-lock, security-check)" ;;
esac

printf '\nErgebnis: %s gruen, %s rot\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]] || exit 1
exit 0
