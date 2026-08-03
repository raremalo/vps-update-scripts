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
RC=0
RUNNING_KERNEL=$(uname -r)
# Neuester installierter Kernel. sort -V ist Pflicht: ohne Versionssortierung
# gewinnt 6.8.0-99 gegen 6.8.0-136.
NEWEST_KERNEL=$({ dpkg-query -W -f='${Package}\t${Status}\n' 'linux-image-[0-9]*' 2>/dev/null \
  | awk -F'\t' '$2 == "install ok installed" {print $1}' \
  | sed 's/^linux-image-//' | sort -V | tail -n 1; } || true)

if [[ -f /var/run/reboot-required ]]; then
  # mtime ist eine UNTERGRENZE: jedes reboot-pflichtige Paket touch-t die Datei
  # neu. Die Tageszahl (GNU stat) ist Kosmetik — die Eskalationsentscheidung
  # hängt am portablen find.
  AGE_DAYS=""
  if MTIME=$(stat -c %Y /var/run/reboot-required 2>/dev/null); then
    AGE_DAYS=$(( ($(date +%s) - MTIME) / 86400 ))
  fi
  if [[ -n "$(find /var/run/reboot-required -maxdepth 0 -mtime +"$REBOOT_OVERDUE_DAYS" -print 2>/dev/null)" ]]; then
    echo -e "🔄 Reboot:  ${RED}ÜBERFÄLLIG — steht seit mindestens ${AGE_DAYS:-$REBOOT_OVERDUE_DAYS} Tagen aus, bitte manuell nachholen${NC}"
    RC=2
  else
    echo -e "🔄 Reboot:  ${RED}erforderlich${NC} (seit mindestens ${AGE_DAYS:-0} Tagen)"
  fi
  if [[ -r /var/run/reboot-required.pkgs ]]; then
    echo -e "   Pakete:  $(sort -u /var/run/reboot-required.pkgs | tr '\n' ' ')"
  fi
elif [[ -n "$NEWEST_KERNEL" && "$NEWEST_KERNEL" != "$RUNNING_KERNEL" ]]; then
  echo -e "🔄 Reboot:  ${YELLOW}empfohlen${NC} — reboot-required fehlt, aber ein neuerer Kernel ist installiert"
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
