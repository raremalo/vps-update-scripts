<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-04-07 | Updated: 2026-04-07 -->

# coolify

## Purpose
Coolify-specific VPS update and autostart scripts, optimized for the Coolify deployment platform with Soketi (realtime/WebSocket) support. Ensures correct container startup ordering where Soketi must launch before the Coolify main container.

## Key Files

| File | Description |
|------|-------------|
| `vps-update-coolify.sh` | Coolify-specific update script with Soketi-aware stop/start sequence |
| `ensure-docker-autostart-coolify.sh` | Post-reboot autostart ensuring correct Coolify stack ordering |
| `docker-autostart-coolify.service` | Systemd unit file for the autostart script |
| `README-COOLIFY.md` | Detailed Coolify usage guide, troubleshooting, and installation instructions |

## For AI Agents

### Working In This Directory

- Container start order is **critical**: `coolify-db` → `coolify-redis` → `coolify-realtime` (Soketi) → `coolify` → `coolify-proxy`
- Stop order is reversed: proxy → main → realtime → redis → db
- Soketi (`coolify-realtime`) is the most common failure point — always verify it starts
- Coolify source path is auto-detected from: `/data/coolify/source`, `/opt/coolify/source`, `/root/coolify/source`
- Sleep intervals between container starts are intentional — do not remove them

### Testing Requirements

- After modifying start order, test with `systemctl restart docker-autostart-coolify.service`
- Verify Soketi: `docker ps | grep coolify-realtime`
- Check logs: `docker logs coolify-realtime`

### Common Patterns

- `wait_for_docker()` polls `docker info` with timeout before starting containers
- Service verification uses `docker ps` to confirm each container is running after start
- Max wait timeouts: Docker=60s, per-service=30s

## Dependencies

### Internal

- Shares logging patterns and structure with root-level scripts

### External

- `docker` / `docker compose` — Coolify runs as a Docker Compose stack
- `systemd` — the `.service` file registers the autostart script

<!-- MANUAL: Any manually added notes below this line are preserved on regeneration -->
