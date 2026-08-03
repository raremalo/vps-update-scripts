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
# Exit 1  = neue Findings oder Syntaxfehler
# Exit 2  = Werkzeug fehlt oder Baseline nicht lesbar
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
normalize() {
    sed -E 's/^([^:]+):[0-9]+:[0-9]+: [a-z]+: .*\[(SC[0-9]+)\]$/\1:\2/' \
        | grep -E '^[^ ]+:SC[0-9]+$' \
        | sort | uniq -c \
        | awk '{printf "%s %s\n", $2, $1}' \
        | sort
}

# ---------------------------------------------------------------------------

FILES=$(collect_files)
[[ -n "$FILES" ]] || die "keine Shell-Skripte gefunden"
FILE_COUNT=$(printf '%s\n' "$FILES" | wc -l | tr -d ' ')

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

CURRENT=$(printf '%s\n' "$FILES" | xargs shellcheck -f gcc 2>/dev/null | normalize)
CURRENT_SUM=$(printf '%s\n' "$CURRENT" | awk 'NF{s+=$2} END {print s+0}')

if [[ "${1:-}" == "--update" ]]; then
    printf '%s\n' "$CURRENT" > "$BASELINE"
    printf '  Baseline neu geschrieben: %s Findings in %s Paaren\n' \
        "$CURRENT_SUM" "$(printf '%s\n' "$CURRENT" | grep -c . )"
    printf '  ACHTUNG: Das akzeptiert den Ist-Zustand als Soll. Nur bewusst tun.\n'
    exit 0
fi

[[ -r "$BASELINE" ]] || die "Baseline fehlt: $BASELINE (einmalig mit --update anlegen)"

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
readonly MUTATING='docker[[:space:]]+(start|stop|rm|kill|update|prune|create|run|exec|load|import|volume[[:space:]]+(rm|prune|create))|docker[[:space:]]+(service|stack|network|image|system|builder)[[:space:]]+(rm|prune|scale|update|create|deploy)|systemctl[[:space:]]+(start|stop|enable|disable|mask|unmask|restart|reload|kill|set-|reset-failed|daemon-reload)|apt-get|apt-mark[[:space:]]+(hold|unhold|auto|manual)|(^|[[:space:]])(rm|mkdir|rmdir|touch|chmod|chown|ln|mv|cp|dd|truncate|install)[[:space:]]|(^|[[:space:]])(reboot|shutdown|halt|poweroff)([[:space:]]|$)|>[[:space:]]*[^&[:space:]]'

# Reduziert eine Datei auf das, was tatsächlich ausgeführt wird:
#   1. Heredoc-Rümpfe entfernen — sie sind Daten, kein Code. Der Installer
#      erzeugt damit systemd-Units, der Selbsttest seinen Hilfetext.
#   2. einfache und doppelte Anführungszeichen samt Inhalt entfernen
#      (Prosa in Log- und Hilfetexten soll nicht mitzählen)
#   3. Kommentare entfernen
#   4. harmlose Umleitungen entfernen, BEVOR auf ">" geprüft wird —
#      `2>/dev/null`, `>/dev/null`, `2>&1` sind keine Schreibzugriffe und
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
    | sed -e "s/'[^']*'//g" \
          -e 's/"[^"]*"//g' \
          -e 's/#.*$//' \
          -e 's/[0-9]*>[[:space:]]*\/dev\/null//g' \
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
