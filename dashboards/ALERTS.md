# Jinbocho — Grafana alert rules (ADR-012 baseline)

Grafana Cloud is SaaS: there is no filesystem to mount a `provisioning/alerting/*.yaml`
into (that mechanism only exists for self-hosted Grafana), and pushing rules via the
Terraform/HTTP Alerting API requires a Cloud Service Account token this environment
doesn't have. So these rules are **not applied automatically** — create each one by hand
under **Alerting → Alert rules → New alert rule**, pasting the query/threshold below. This
mirrors how `jinbocho-overview.json` / `jinbocho-logs-errors.json` / `jinbocho-infra.json`
are already handled: manual import, not provisioned.

For each rule: set **Folder** = `Jinbocho`, **Evaluation group** = `jinbocho-adr-012`
(shared 1m evaluation interval), then the `for` duration and labels below.

## Application (Prometheus — `grafanacloud-prom`)

| Rule | Query | Condition | For | Labels |
|---|---|---|---|---|
| 5xx error rate sustained | `100 * sum(rate(http_requests_total{status="5xx"}[5m])) by (service_name) / sum(rate(http_requests_total[5m])) by (service_name))` | `> 5` | 5m | `severity=critical` |
| p95 latency over threshold | `histogram_quantile(0.95, sum(rate(http_request_duration_highr_seconds_bucket[5m])) by (service_name, le))` | `> 2` (seconds — tune per traffic profile) | 5m | `severity=warning` |
| Service down | `up{service_name=~"auth-service\|catalog-service\|api-gateway\|ai-service"}` | `== 0` | 2m | `severity=critical` |

## Host / container / Postgres (Prometheus — requires the `infra_metrics` scrape job, see `config.alloy`)

| Rule | Query | Condition | For | Labels |
|---|---|---|---|---|
| Disk > 85% | `100 * (1 - node_filesystem_avail_bytes{mountpoint="/"} / node_filesystem_size_bytes{mountpoint="/"})` | `> 85` | 5m | `severity=critical` |
| RAM > 90% | `100 * (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)` | `> 90` | 5m | `severity=critical` |
| Container restart loop | `resets(container_start_time_seconds{name=~"jinbocho-.+"}[15m])` | `> 2` | 0m (fires immediately once true) | `severity=warning` |
| Postgres connections near saturation | `max(pg_stat_database_numbackends{datname=~"auth_db\|catalog_db"}) by (datname) / on() group_left() max(pg_settings_max_connections)` | `> 0.8` | 5m | `severity=warning` |

## Logs (Loki — `grafanacloud-logs`)

| Rule | Query | Condition | For | Labels |
|---|---|---|---|---|
| ERROR log spike | `sum(count_over_time({service_name=~".+"} \|~ " ERROR " [5m])) by (service_name)` | `> 20` (tune to baseline noise) | 5m | `severity=warning` |

## Explicitly NOT Grafana rules (per ADR-012 — configure at the source instead)

- **"New exception type"** — this is a Sentry/GlitchTip issue alert, configured in that
  product's own Alerts settings (Sentry Cloud EU or self-hosted GlitchTip UI), not
  Grafana. Grafana never sees individual exceptions, only the 5xx rate they cause.
- **Uptime down** — external monitor (UptimeRobot/Better Stack/Uptime Kuma on a
  *different* host, per ADR-012's watcher/watched separation). Configure its alerting in
  that product, not Grafana — a Grafana alert co-located on the monitored VPS can't
  detect the VPS itself being down.

## Contact point (routes alerts to something you actually read)

ADR-012 recommends Telegram or email over a channel that gets ignored. Grafana Cloud has
a built-in Telegram integration under **Alerting → Contact points → New contact point**;
you supply your own bot token (`@BotFather`) and chat ID — neither can be generated for
you. Route all `severity=critical` labels here via a **Notification policy**; route
`severity=warning` to a lower-urgency channel (e.g. email) if you want to avoid alert
fatigue on day one.
