#!/usr/bin/env bash
#
# lint.sh — Statische Prüfung aller Shell-Skripte des Repos (Ebene 1)
#
# Prüft zwei Dinge:
#   1. Syntax:    bash -n über jedes Skript
#   2. Regression: shellcheck-Findings gegen eine gepinnte Baseline
#
# Die Baseline ist auf "datei:regelcode" normalisiert, NICHT auf Zeilennummern.
# Dadurch erzeugt eine eingefügte Zeile keinen Fehlalarm, während ein neues
# Finding in einer Datei sofort auffällt.
#
# Exit 0  = keine neuen Findings, Syntax überall in Ordnung
# Exit 1  = neue Findings, Syntaxfehler oder Read-only-Verletzung
# Exit 2  = Werkzeugfehler: shellcheck fehlt, bricht ab oder liefert eine
#           Ausgabe, die sich nicht normalisieren lässt; Baseline nicht lesbar.
#           Ein unvollständiger Analyselauf gilt NIE als bestanden.
#
# Verwendung:
#     bash tools/lint.sh              # prüfen
#     bash tools/lint.sh --update     # Baseline neu schreiben (bewusst!)

set -uo pipefail

# Getrennt deklariert und zugewiesen: `readonly X=$(...)` würde den Exit-Code
# der Substitution maskieren (SC2155) — genau das Muster, das dieses Repo an
# 50 Stellen beseitigen soll. Das Werkzeug hält sich an seinen eigenen Maßstab.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly BASELINE="$REPO_ROOT/tools/shellcheck-baseline.txt"

cd "$REPO_ROOT" || { printf 'FEHLER: Repo-Wurzel nicht erreichbar\n' >&2; exit 2; }

# ---------------------------------------------------------------------------

die() { printf 'FEHLER: %s\n' "$1" >&2; exit 2; }

command -v shellcheck >/dev/null 2>&1 || die "shellcheck nicht installiert (brew install shellcheck)"

# Zu prüfende Dateien: alle getrackten .sh plus noch nicht getrackte unter tools/.
# Letzteres, damit neu angelegte Werkzeuge nicht erst nach dem Commit geprüft werden.
collect_files() {
    {
        git ls-files '*.sh' 2>/dev/null
        [[ -d tools ]] && find tools -maxdepth 1 -name '*.sh' -type f 2>/dev/null
    } | sort -u
}

# Normalisiert die shellcheck-Ausgabe auf "datei:SCxxxx anzahl".
# Zeilen- und Spaltennummern fallen bewusst weg.
#
# Bewusst OHNE `grep` als Filter: grep endet mit 1, wenn nichts passt. Unter
# `pipefail` waere der Status der Pipeline dann 1 — ununterscheidbar von einem
# echten Werkzeugfehler. Genau diese Unterscheidung braucht der Aufrufer, um
# fail-closed reagieren zu koennen. awk filtert und zaehlt in einem Schritt und
# endet auch bei null Treffern mit 0.
normalize() {
    sed -E 's/^([^:]+):[0-9]+:[0-9]+: [a-z]+: .*\[(SC[0-9]+)\]$/\1:\2/' \
        | awk '/^[^ ]+:SC[0-9]+$/ { c[$0]++ } END { for (k in c) printf "%s %s\n", k, c[k] }' \
        | sort
}

# ---------------------------------------------------------------------------

FILES=$(collect_files)
[[ -n "$FILES" ]] || die "keine Shell-Skripte gefunden"
FILE_COUNT=$(printf '%s\n' "$FILES" | wc -l | tr -d ' ')

# Argumente strikt prüfen: Ein Tippfehler wie "--updat" würde sonst still den
# Normalmodus fahren und mit 0 enden — dieselbe fail-open-Klasse, die dieses
# Skript gerade beseitigen soll.
UPDATE_MODE=0
case "${1:-}" in
    --update) UPDATE_MODE=1 ;;
    "")       ;;
    *)        die "unbekannte Option: $1 (erlaubt: --update)" ;;
esac

# Dateiliste als Array: shellcheck wird DIREKT aufgerufen, nicht über xargs.
# Grund: xargs bildet jeden Kindstatus zwischen 1 und 125 auf 123 ab. Damit
# wäre "Findings gefunden" (1) nicht mehr von "Werkzeugfehler" (2, 3, 4) zu
# unterscheiden — genau die Unterscheidung, auf der die Fehlerbehandlung beruht.
SC_FILES=()
while IFS= read -r f; do
    [[ -n "$f" ]] && SC_FILES+=("$f")
done <<< "$FILES"
[[ ${#SC_FILES[@]} -gt 0 ]] || die "keine Shell-Skripte gefunden"

# --- 1. Syntaxprüfung ------------------------------------------------------

printf '=== Syntaxprüfung (bash -n) ===\n'
syntax_errors=0
while IFS= read -r f; do
    [[ -f "$f" ]] || continue
    if ! bash -n "$f" 2>/tmp/lint-syntax-err.$$; then
        printf '  FEHLER  %s\n' "$f"
        sed 's/^/          /' /tmp/lint-syntax-err.$$
        syntax_errors=$((syntax_errors + 1))
    fi
done <<< "$FILES"
rm -f /tmp/lint-syntax-err.$$
if [[ $syntax_errors -eq 0 ]]; then
    printf '  OK — %s Dateien fehlerfrei\n' "$FILE_COUNT"
fi

# --- 2. shellcheck gegen Baseline -----------------------------------------

printf '\n=== shellcheck gegen Baseline ===\n'

# Rohausgabe, stderr und Exit-Status GETRENNT erfassen.
#
# Früher stand hier eine Pipeline mit "2>/dev/null", deren Status nie geprüft
# wurde. Bricht shellcheck ab, ist CURRENT leer — und leer bedeutet für den
# Vergleich unten "alle Baseline-Findings behoben". Der Lauf endete dann mit
# EXIT 0 und meldete den Werkzeugausfall als Fortschritt.
#
# Dokumentierte Exit-Codes von shellcheck: 0 = keine Findings, 1 = Findings.
# Alles andere (2 = Datei nicht verarbeitbar, 3 = Shell-Typ, 4 = Optionsfehler)
# ist ein Werkzeugfehler und muss fail-closed enden.
#
# KANARIENVOGEL: ein Schnipsel, der garantiert genau ein SC2086 auslöst, läuft
# im SELBEN shellcheck-Aufruf mit. Grund: Exit 0 mit leerer Ausgabe ist sonst
# nicht von "es gibt wirklich keine Findings" zu unterscheiden — ein Analyzer,
# der still nichts liefert, hätte alle Baseline-Einträge als "behoben" gemeldet.
# Fehlt das Kanarienvogel-Finding, hat dieser Lauf nachweislich nicht analysiert.
SC_TMP=$(mktemp -d "${TMPDIR:-/tmp}/lint-canary.XXXXXX") || die "mktemp -d fehlgeschlagen"
readonly CANARY="$SC_TMP/canary.sh"
cat > "$CANARY" <<'CANARY_EOF'
#!/usr/bin/env bash
canary_value=$1
echo $canary_value
CANARY_EOF

SC_ERR="$SC_TMP/stderr.txt"
SC_RAW=$(shellcheck -f gcc "${SC_FILES[@]}" "$CANARY" 2>"$SC_ERR")
SC_RC=$?

sc_die() { printf 'FEHLER: %s\n' "$1" >&2; rm -rf "$SC_TMP"; exit 2; }

if [[ $SC_RC -ne 0 && $SC_RC -ne 1 ]]; then
    printf '  FEHLER: shellcheck endete mit Status %s (dokumentiert sind nur 0 und 1)\n' "$SC_RC" >&2
    [[ -s "$SC_ERR" ]] && sed 's/^/    /' "$SC_ERR" >&2
    printf '  Abbruch — ein unvollständiger Analyselauf darf nicht als Ergebnis gelten.\n' >&2
    sc_die "shellcheck-Lauf abgebrochen"
fi
if [[ -s "$SC_ERR" ]]; then
    printf '  FEHLER: shellcheck hat auf stderr geschrieben — Analyse unvollständig\n' >&2
    sed 's/^/    /' "$SC_ERR" >&2
    sc_die "shellcheck-Lauf nicht sauber"
fi

CURRENT_ALL=$(printf '%s\n' "$SC_RAW" | normalize)
NORM_RC=$?
[[ $NORM_RC -eq 0 ]] || sc_die "Normalisierung der shellcheck-Ausgabe fehlgeschlagen (Status $NORM_RC)"

# Liveness: Ohne das erwartete Kanarienvogel-Finding hat der Lauf nichts
# analysiert. Fail-closed, egal welchen Status shellcheck gemeldet hat.
if ! printf '%s\n' "$CURRENT_ALL" | grep -qxF "$CANARY:SC2086 1"; then
    printf '  FEHLER: Der Kanarienvogel-Schnipsel liefert kein SC2086.\n' >&2
    printf '  shellcheck hat diesen Lauf nicht ausgewertet — Ergebnis unbrauchbar.\n' >&2
    printf '  (Status war %s, Rohausgabe %s Zeilen)\n' \
        "$SC_RC" "$(printf '%s' "$SC_RAW" | grep -c '.')" >&2
    sc_die "Analysator liefert kein Ergebnis"
fi

# Kanarienvogel aus dem Ergebnis entfernen — er gehört nicht in die Baseline.
CURRENT=$(printf '%s\n' "$CURRENT_ALL" | awk -v c="$CANARY:" 'NF && index($0, c) != 1')
rm -rf "$SC_TMP"

CURRENT_SUM=$(printf '%s\n' "$CURRENT" | awk 'NF{s+=$2} END {print s+0}')

# Baseline einlesen. Sie darf nur im --update-Modus fehlen (Erstanlage).
BASE_SUM=0
regressions=""
improvements=""
if [[ -r "$BASELINE" ]]; then
    BASE_SUM=$(awk 'NF{s+=$2} END {print s+0}' "$BASELINE")

    # Vergleich der Paare. Neue oder gewachsene Einträge sind Regressionen,
    # verschwundene oder geschrumpfte sind Verbesserungen.
    regressions=$(
        join -a1 -e 0 -o 0,1.2,2.2 \
            <(printf '%s\n' "$CURRENT" | awk 'NF') \
            <(awk 'NF' "$BASELINE") 2>/dev/null \
        | awk '$2 > $3 { printf "  + %-52s %s -> %s\n", $1, $3, $2 }'
    )
    improvements=$(
        join -a1 -e 0 -o 0,1.2,2.2 \
            <(awk 'NF' "$BASELINE") \
            <(printf '%s\n' "$CURRENT" | awk 'NF') 2>/dev/null \
        | awk '$2 > $3 { printf "  - %-52s %s -> %s\n", $1, $2, $3 }'
    )

    printf '  Baseline: %s Findings\n' "$BASE_SUM"
    printf '  Aktuell:  %s Findings\n' "$CURRENT_SUM"
    printf '  Delta:    %+d\n' "$((CURRENT_SUM - BASE_SUM))"

    if [[ -n "$improvements" ]]; then
        printf '\n  Behoben:\n%s\n' "$improvements"
    fi

    if [[ -n "$regressions" ]]; then
        printf '\n  NEUE FINDINGS (Regression):\n%s\n' "$regressions"
    fi
elif [[ $UPDATE_MODE -eq 1 ]]; then
    printf '  (keine Baseline vorhanden — wird durch --update angelegt)\n'
    printf '  Aktuell:  %s Findings\n' "$CURRENT_SUM"
else
    die "Baseline fehlt: $BASELINE (einmalig mit --update anlegen)"
fi

# --- 3. Read-only-Zusicherung ---------------------------------------------
#
# Skripte, die im Kopf "# LINT: read-only" tragen, dürfen keine mutierenden
# Kommandos enthalten. Geprüft werden AUSFÜHRBARE ZEILEN, nicht der Volltext:
# Kommentare und String-Literale werden vorher entfernt.
#
# Grund: Eine Volltext-Suche zählt Prosa mit ("... würde 'docker volume prune'
# löschen") und ist durch Umformulieren umgehbar — sie prüft die Wortwahl,
# nicht das Verhalten.

# Nur echte Zustandsänderungen. Bewusst NICHT enthalten: lesende Unterkommandos
# wie `docker ps/info/inspect`, `systemctl show/is-*/list-*`, `apt-mark showhold`.
#
# In Teile zerlegt, damit jede Gruppe für sich lesbar und begründbar bleibt.
readonly MUT_DOCKER='docker[[:space:]]+(start|stop|restart|rm|kill|pause|unpause|update|prune|create|run|exec|load|import|cp|commit|tag|push|login|logout|compose|volume[[:space:]]+(rm|prune|create))'
readonly MUT_DOCKER_SUB='docker[[:space:]]+(service|stack|network|image|system|builder|container|node|secret|config|swarm|volume)[[:space:]]+(rm|prune|scale|update|create|deploy|remove|leave|join|init|load|import|restart)'
readonly MUT_SYSTEMD='systemctl[[:space:]]+(start|stop|enable|disable|mask|unmask|restart|reload|kill|edit|link|revert|preset|isolate|set-|reset-failed|daemon-reload)'
readonly MUT_PKG='apt-get|apt-mark[[:space:]]+(hold|unhold|auto|manual)|dpkg[[:space:]]+(-i|-r|-P|--install|--remove|--purge)|snap[[:space:]]+(install|remove|refresh|revert)'
readonly MUT_FS='(^|[[:space:]])(rm|mkdir|rmdir|touch|chmod|chown|chgrp|ln|mv|cp|dd|truncate|install|tee|mkfs|mount|umount|swapon|swapoff)[[:space:]]'
readonly MUT_INPLACE='(^|[[:space:]])(sed|perl)[[:space:]]+(-[a-zA-Z]*i|--in-place)'
readonly MUT_GIT='git[[:space:]]+(add|commit|push|checkout|switch|reset|clean|rm|mv|merge|rebase|pull|fetch|clone|init|tag|stash|apply|am|cherry-pick|revert|gc|prune|config|remote|branch|worktree)'
readonly MUT_USER='(^|[[:space:]])(useradd|usermod|userdel|groupadd|groupdel|passwd|chpasswd|crontab|visudo)[[:space:]]'
readonly MUT_PROC='(^|[[:space:]])(kill|pkill|killall|reboot|shutdown|halt|poweroff)([[:space:]]|$)'
readonly MUT_NET='(^|[[:space:]])(ufw|iptables|ip6tables|nft)[[:space:]]|sysctl[[:space:]]+-w|journalctl[[:space:]]+[^|;&]*--vacuum'
readonly MUT_FETCH='(^|[[:space:]])wget([[:space:]]|$)|curl[[:space:]]+[^|;&]*[[:space:]](-o|-O|--output)([[:space:]]|$)'
# Jede Umleitung, deren Ziel nicht /dev/null oder ein Deskriptor ist. Deckt
# auch ">>" ab: nach dem ersten ">" steht dann ">", also ein Nicht-Space.
readonly MUT_REDIR='>[[:space:]]*[^&[:space:]]'

readonly MUTATING="$MUT_DOCKER|$MUT_DOCKER_SUB|$MUT_SYSTEMD|$MUT_PKG|$MUT_FS|$MUT_INPLACE|$MUT_GIT|$MUT_USER|$MUT_PROC|$MUT_NET|$MUT_FETCH|$MUT_REDIR"

# Reduziert eine Datei auf das, was tatsächlich ausgeführt wird:
#   1. Heredoc-Rümpfe entfernen — sie sind Daten, kein Code. Der Installer
#      erzeugt damit systemd-Units, der Selbsttest seinen Hilfetext.
#   2. Zeichenketten durch den PLATZHALTER "QSTR" ersetzen, nicht löschen.
#      Löschen erzeugte einen direkten Bypass: `printf x > "$ziel"` wurde zu
#      `printf x > `, und das Umleitungsmuster verlangt ein Zeichen nach dem
#      ">" — der Schreibzugriff rutschte durch. Der Platzhalter erhält die
#      Struktur der Zeile, hält aber Prosa aus Log- und Hilfetexten heraus.
#   3. Kommentare entfernen
#   4. harmlose Umleitungen entfernen, BEVOR auf ">" geprüft wird —
#      `2>/dev/null`, `&>/dev/null`, `2>&1` sind keine Schreibzugriffe und
#      stehen in nahezu jeder Zeile
strip_to_executable() {
    awk '
        # Heredoc-Zeilen werden durch Leerzeilen ERSETZT, nicht entfernt —
        # sonst verschieben sich alle folgenden Zeilennummern und die
        # Fundstellenmeldung zeigt auf die falsche Stelle.
        inhd {
            if ($0 ~ "^[ \t]*" term "[ \t]*$") inhd = 0
            print ""
            next
        }
        {
            line = $0
            if (match(line, /<<-?[ \t]*[\047\042]?[A-Za-z_][A-Za-z0-9_]*[\047\042]?/)) {
                t = substr(line, RSTART, RLENGTH)
                sub(/^<<-?[ \t]*/, "", t)
                gsub(/[\047\042]/, "", t)
                term = t
                inhd = 1
                sub(/<<.*$/, "", line)
            }
            print line
        }
    ' "$1" \
    | sed -e "s/'[^']*'/QSTR/g" \
          -e 's/"[^"]*"/QSTR/g' \
          -e 's/#.*$//' \
          -e 's/[&0-9]*>>\{0,1\}[[:space:]]*\/dev\/null//g' \
          -e 's/[0-9]*>&[0-9-]//g'
}

printf '\n=== Read-only-Zusicherung ===\n'
readonly_violations=0
readonly_checked=0
while IFS= read -r f; do
    [[ -f "$f" ]] || continue
    grep -q '^# LINT: read-only' "$f" 2>/dev/null || continue
    readonly_checked=$((readonly_checked + 1))
    hits=$(strip_to_executable "$f" | grep -nE "$MUTATING" || true)
    if [[ -n "$hits" ]]; then
        printf '  VERLETZUNG  %s\n' "$f"
        printf '%s\n' "$hits" | sed 's/^/              /'
        readonly_violations=$((readonly_violations + 1))
    else
        printf '  OK  %s — keine mutierenden Kommandos in ausführbaren Zeilen\n' "$f"
    fi
done <<< "$FILES"
[[ $readonly_checked -eq 0 ]] && printf '  (kein Skript mit "# LINT: read-only" markiert)\n'

# --- 4. Baseline fortschreiben (--update) ----------------------------------
#
# BEWUSST HIER, nicht direkt nach dem shellcheck-Lauf: --update darf erst
# laufen, wenn Syntax- UND Read-only-Prüfung sauber sind. Früher schrieb
# --update die Baseline und beendete sich mit 0, BEVOR diese Prüfungen
# ausgewertet wurden — ein Syntaxfehler oder eine Read-only-Verletzung wurde
# damit stillschweigend in die Baseline übernommen.

if [[ $UPDATE_MODE -eq 1 ]]; then
    printf '\n=== Baseline fortschreiben (--update) ===\n'
    if [[ $syntax_errors -gt 0 || $readonly_violations -gt 0 ]]; then
        printf '  ABGEBROCHEN: %s Syntaxfehler, %s Read-only-Verletzung(en).\n' \
            "$syntax_errors" "$readonly_violations" >&2
        printf '  Die Baseline bleibt unverändert. Erst beheben, dann fortschreiben.\n' >&2
        exit 1
    fi
    # Atomar ersetzen: Temp-Datei im Zielverzeichnis + mv. Ein Abbruch beim
    # Schreiben darf keine halbe Baseline hinterlassen.
    BASE_TMP=$(mktemp "$BASELINE.tmp.XXXXXX") || die "mktemp neben der Baseline fehlgeschlagen"
    if ! printf '%s\n' "$CURRENT" > "$BASE_TMP"; then
        rm -f "$BASE_TMP"
        die "Baseline konnte nicht geschrieben werden"
    fi
    if ! mv "$BASE_TMP" "$BASELINE"; then
        rm -f "$BASE_TMP"
        die "Baseline konnte nicht ersetzt werden"
    fi
    printf '  Baseline neu geschrieben: %s Findings in %s Paaren\n' \
        "$CURRENT_SUM" "$(printf '%s\n' "$CURRENT" | awk 'NF' | wc -l | tr -d ' ')"
    printf '  ACHTUNG: Das akzeptiert den Ist-Zustand als Soll. Nur bewusst tun.\n'
    exit 0
fi

# --- Ergebnis --------------------------------------------------------------

printf '\n=== Ergebnis ===\n'
rc=0
if [[ $readonly_violations -gt 0 ]]; then
    printf '  FEHLGESCHLAGEN: %s Skript(e) verletzen ihre Read-only-Zusicherung\n' \
        "$readonly_violations"
    rc=1
fi
if [[ $syntax_errors -gt 0 ]]; then
    printf '  FEHLGESCHLAGEN: %s Datei(en) mit Syntaxfehler\n' "$syntax_errors"
    rc=1
fi
if [[ -n "$regressions" ]]; then
    printf '  FEHLGESCHLAGEN: neue shellcheck-Findings gegenüber der Baseline\n'
    printf '  Entweder beheben, oder — falls bewusst akzeptiert — Baseline mit\n'
    printf '  "bash tools/lint.sh --update" fortschreiben und im Commit begründen.\n'
    rc=1
fi
if [[ $rc -eq 0 ]]; then
    if [[ -n "$improvements" ]]; then
        printf '  OK — keine Regression, %s Finding(s) behoben\n' \
            "$((BASE_SUM - CURRENT_SUM))"
        printf '  Baseline mit "--update" fortschreiben, damit der Fortschritt festgehalten wird.\n'
    else
        printf '  OK — keine Regression\n'
    fi
fi

exit $rc
