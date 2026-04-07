<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-04-07 | Updated: 2026-04-07 -->

# dokploy

## Purpose
Dokploy-specific VPS update and autostart scripts, adapted from the Coolify variants. Dokploy uses a simpler startup sequence (no Soketi) and Traefik as its reverse proxy instead of a custom proxy container.

## Key Files

| File | Description |
|------|-------------|
| `vps-update-dokploy.sh` | Dokploy-specific update script with simplified start/stop sequence |
| `ensure-docker-autostart-dokploy.sh` | Post-reboot autostart for Dokploy stack |
| `docker-autostart-dokploy.service` | Systemd unit file for the autostart script |
| `README-DOKPLOY.md` | Dokploy usage guide with Coolify comparison and troubleshooting |

## For AI Agents

### Working In This Directory

- Container start order: `dokploy-postgres` → `dokploy-redis` → `dokploy` → `dokploy-traefik`
- **No Soketi** — Dokploy does not use a separate realtime service (key difference from Coolify)
- Dokploy path is auto-detected from: `/etc/dokploy`, `/opt/dokploy`, `/var/lib/dokploy`, `/root/dokploy`
- Uses Traefik as reverse proxy instead of a custom proxy container

### Testing Requirements

- After modifying start order, test with `systemctl restart docker-autostart-dokploy.service`
- Verify Dokploy: `curl -I http://localhost:3000`
- Check logs: `docker logs dokploy`

### Common Patterns

- Same logging and lock-file patterns as Coolify scripts
- Same `wait_for_docker()` polling pattern
- Simpler than Coolify variant — fewer containers, no Soketi verification step

## Dependencies

### Internal

- Adapted from `coolify/` scripts — shared structure and conventions

### External

- `docker` / `docker compose` — Dokploy runs as a Docker Compose stack
- `systemd` — the `.service` file registers the autostart script
- Traefik — reverse proxy (runs as `dokploy-traefik` container)

<!-- MANUAL: Any manually added notes below this line are preserved on regeneration -->
