# Chaos Tests

Hot reload zero-downtime validation under load.

## Prerequisites

- Docker Compose running (`make up`)
- `LUAGATE_ADMIN_TOKEN` set
- `wrk` installed
- `bc` installed

## Usage

```bash
# Run all chaos tests
make test-chaos

# Or directly
LUAGATE_ADMIN_TOKEN=<token> bash tests/chaos/test_hot_reload.sh
```

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `LUAGATE_HTTP_URL` | `http://localhost:8080` | Gateway HTTP endpoint |
| `LUAGATE_ADMIN_URL` | `http://localhost:9090` | Admin API endpoint |
| `LUAGATE_ADMIN_TOKEN` | (required) | Admin API token |
| `WRK_THREADS` | `4` | wrk thread count |
| `WRK_CONNECTIONS` | `100` | wrk connection count |
| `WRK_DURATION` | `30s` | wrk duration per phase |
| `RELOAD_INTERVAL` | `5` | Seconds between reloads |
| `RELOAD_COUNT` | `6` | Number of reloads during load |

## Scenarios

1. **Reload under load** — wrk + concurrent reloads. Error rate < 0.1%, RPS drop < 5%
2. **Reload succeeds** — Reload returns 200 and /health reports a valid source_version
3. **Invalid YAML → LKG** — PUT with invalid YAML returns 422, version unchanged, gateway healthy
4. **Concurrent rapid-fire reloads** — 10 parallel reloads, expects 200/409 only (no 5xx), gateway survives
