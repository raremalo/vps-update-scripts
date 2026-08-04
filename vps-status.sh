#!/usr/bin/env bash
set -euo pipefail
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BLUE='\033[0;34m'; NC='\033[0m'

echo -e "${GREEN}===== VPS-Status ($(date)) =====${NC}"
echo -e "${BLUE}Host:$(hostname) | Kernel:$(uname -r) | Uptime:$(uptime -p)${NC}\n"

# Updates
UPG_TOTAL=$(apt list --upgradable 2>/dev/null | tail -n +2 | wc -l)
# grep -c liefert bei null Treffern Exit 1 — unter set -euo pipefail stürbe
# das Skript genau dann, wenn KEINE Security-Updates ausstehen
UPG_SEC=$(apt list --upgradable 2>/dev/null | grep -ci security || true)
UPG_SEC=${UPG_SEC:-0}
[[ $UPG_TOTAL -gt 0 ]] \
  && echo -e "📦 Updates: ${YELLOW}$UPG_TOTAL ($UPG_SEC Security)${NC}" \
  || echo -e "📦 Updates: ${GREEN}keine${NC}"

# Reboot — steht er länger als REBOOT_OVERDUE_DAYS aus, endet vps-status mit
# Exit 2, damit der Zustand maschinell auswertbar ist statt nur lesbar
REBOOT_OVERDUE_DAYS="${REBOOT_OVERDUE_DAYS:-7}"
if [[ ! "$REBOOT_OVERDUE_DAYS" =~ ^[1-9][0-9]*$ ]]; then
  echo -e "${YELLOW}REBOOT_OVERDUE_DAYS='${REBOOT_OVERDUE_DAYS}' ist keine positive Zahl — verwende Default 7${NC}"
  REBOOT_OVERDUE_DAYS=7
fi
RC=0
RUNNING_KERNEL=$(uname -r)
# Neuester installierter Kernel. sort -V ist Pflicht: ohne Versionssortierung
# gewinnt 6.8.0-99 gegen 6.8.0-136. Schlägt die Abfrage fehl, bleibt der Wert
# leer und wird unten als „unbekannt" gemeldet — nicht als „nicht nötig".
NEWEST_KERNEL=$(dpkg-query -W -f='${Package}\t${Status}\n' 'linux-image-[0-9]*' 2>/dev/null \
  | awk -F'\t' '$2 == "install ok installed" {print $1}' \
  | sed 's/^linux-image-//' | sort -V | tail -n 1) || NEWEST_KERNEL=""

if [[ -f /var/run/reboot-required ]]; then
  # mtime ist eine UNTERGRENZE: jedes reboot-pflichtige Paket touch-t die Datei
  # neu. Epochenvergleich statt find -mtime +N: find matcht erst ab N+1 VOLLEN
  # Tagen (Tag 7 eskalierte real erst Tag 14), und ein find-Fehler sähe wie
  # „nicht überfällig" aus. stat -c ist GNU, -f der BSD-Fallback; ein nicht
  # ermittelbares Alter eskaliert fail-closed statt still weiterzulaufen.
  MTIME=$(stat -c %Y /var/run/reboot-required 2>/dev/null) \
    || MTIME=$(stat -f %m /var/run/reboot-required 2>/dev/null) \
    || MTIME=""
  if [[ "$MTIME" =~ ^[0-9]+$ ]]; then
    AGE_SECS=$(( $(date +%s) - MTIME ))
    AGE_DAYS=$(( AGE_SECS / 86400 ))
    if (( AGE_SECS > REBOOT_OVERDUE_DAYS * 86400 )); then
      echo -e "🔄 Reboot:  ${RED}ÜBERFÄLLIG — steht seit mindestens ${AGE_DAYS} Tagen aus, bitte manuell nachholen${NC}"
      RC=2
    else
      echo -e "🔄 Reboot:  ${RED}erforderlich${NC} (seit mindestens ${AGE_DAYS} Tagen)"
    fi
  else
    echo -e "🔄 Reboot:  ${RED}erforderlich — Alter nicht ermittelbar, gilt als ÜBERFÄLLIG${NC}"
    RC=2
  fi
  if [[ -r /var/run/reboot-required.pkgs ]]; then
    echo -e "   Pakete:  $(sort -u /var/run/reboot-required.pkgs | tr '\n' ' ')"
  fi
elif [[ -n "$NEWEST_KERNEL" && "$NEWEST_KERNEL" != "$RUNNING_KERNEL" ]]; then
  echo -e "🔄 Reboot:  ${YELLOW}empfohlen${NC} — reboot-required fehlt, aber ein neuerer Kernel ist installiert"
elif [[ -z "$NEWEST_KERNEL" ]]; then
  # Messausfall (dpkg-query gescheitert oder kein Kernel-Paket gefunden):
  # unbekannt melden statt fail-open grün
  echo -e "🔄 Reboot:  ${YELLOW}unbekannt${NC} — installierte Kernel nicht ermittelbar (dpkg-query)"
else
  echo -e "🔄 Reboot:  ${GREEN}nicht nötig${NC}"
fi

# Kernel-Abgleich — das Signal, das den lorini-Fall gefunden hätte
if [[ -n "$NEWEST_KERNEL" && "$NEWEST_KERNEL" != "$RUNNING_KERNEL" ]]; then
  echo -e "   Kernel:  ${YELLOW}läuft ${RUNNING_KERNEL}, installiert ist ${NEWEST_KERNEL}${NC}"
fi

# Docker
if command -v docker &>/dev/null; then
  systemctl is-active --quiet docker \
    && echo -e "🐳 Docker:  ${GREEN}aktiv${NC} ($(docker ps -q | wc -l) running)" \
    || echo -e "🐳 Docker:  ${RED}inaktiv${NC}"
fi

# Exit ≠ 0 nur bei überfälligem Reboot (siehe oben). Achtung für Aufrufer in
# set -e-Ketten: vps-status ist damit kein garantierter Exit-0-Befehl mehr.
exit "$RC"
