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

# Reboot
[[ -f /var/run/reboot-required ]] \
  && echo -e "🔄 Reboot:  ${RED}erforderlich${NC}" \
  || echo -e "🔄 Reboot:  ${GREEN}nicht nötig${NC}"

# Docker
if command -v docker &>/dev/null; then
  systemctl is-active --quiet docker \
    && echo -e "🐳 Docker:  ${GREEN}aktiv${NC} ($(docker ps -q | wc -l) running)" \
    || echo -e "🐳 Docker:  ${RED}inaktiv${NC}"
fi
