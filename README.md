# LLM Router + Monitoring Stack

A self-hosted LLM routing and observability stack for home lab and small enterprise use. Routes requests between local Ollama inference and free OpenRouter cloud models, with full metrics, log aggregation, and Grafana dashboards.

---

## Architecture Overview

```
┌─────────────────────┐     ┌─────────────────────┐     ┌─────────────────────┐
│   Clients           │     │   Router VM          │     │   Monitoring VM     │
│                     │     │   (llmrouter)        │     │   (dashboard)       │
│  Hermes Agent  ─────┼────▶│  LiteLLM :4000      │     │                     │
│  Claude Code   ─────┼────▶│                      │────▶│  Prometheus :9090   │
│  Any OpenAI    ─────┼────▶│  node_exporter :9100 │────▶│  Loki :3100         │
│  compatible client  │     │  Promtail            │────▶│  Grafana :80        │
└─────────────────────┘     └──────────┬───────────┘     └─────────────────────┘
                                        │
                             ┌──────────▼───────────┐
                             │   Ollama Server       │
                             │   (separate machine)  │
                             │   OpenAI-compat /v1   │
                             └───────────────────────┘
                                        +
                             ┌──────────────────────┐
                             │   OpenRouter (cloud)  │
                             │   Free-tier models    │
                             └──────────────────────┘
```

**Router VM** acts as a unified LLM gateway. Clients send standard OpenAI-format requests to one endpoint and the router decides which backend handles each request — local Ollama for speed and cost, OpenRouter free-tier cloud models as fallback or for specific tiers.

**Monitoring VM** runs the full observability stack independently. It survives router VM restarts, providing visibility exactly when you need it most.

---

## Scripts

| Script | Purpose |
|---|---|
| `install-monitoring-vm.sh` | Installs Prometheus, Loki, Grafana, nginx, node_exporter, Promtail on the monitoring VM |
| `install-router-vm.sh` | Installs LiteLLM, node_exporter, Promtail on the router VM |
| `litellm-dashboard-fixed.json` | Grafana dashboard JSON matched to your LiteLLM version's metric names |

Both install scripts are **re-runnable**. Completed steps are tracked in a state directory and skipped on subsequent runs, so you can safely re-run after a failure or partial install.

---

## Requirements

### Both VMs
- Ubuntu 24.04 LTS (script warns but continues on other versions)
- sudo / root access
- Internet access for package downloads

### Monitoring VM
- Minimum: 2 vCPU / 4 GB RAM / 60 GB disk
- The 60 GB covers 30 days of metrics + log retention at moderate traffic

### Router VM
- Minimum: 2 vCPU / 2 GB RAM / 20 GB disk
- LiteLLM runs in a Python venv, ~300 MB RAM at idle

### Ollama Server (separate machine)
- Must expose the OpenAI-compatible endpoint at `/v1` (not just the native Ollama API)
- Must be bound to `0.0.0.0`, not just `localhost`
- The model you want to use must already be pulled before running the router install

To verify your Ollama server is reachable and correctly configured:
```bash
curl http://YOUR_OLLAMA_IP:YOUR_PORT/v1/models
```
This should return a JSON list of available models.

---

## Monitoring VM Setup

### Step 1 — Run the install script

```bash
sudo bash install-monitoring-vm.sh
```

The script will ask:
- **Router VM IP** *(optional)* — if provided, Prometheus scrape jobs for LiteLLM and node_exporter are pre-configured. You can skip this and add them manually later.

Everything else is fully automated.

### What gets installed

| Component | Version | Purpose |
|---|---|---|
| Prometheus | 2.53.4 | Metrics collection and storage |
| node_exporter | 1.8.2 | Host CPU/memory/disk/network metrics |
| Loki | 3.5.1 | Log aggregation and storage |
| Promtail | 3.5.1 | Ships this VM's own systemd logs to Loki |
| Grafana | latest stable | Dashboards and visualisation |
| nginx | system | Reverse proxy for Grafana on port 80 |

### Firewall rules configured

| Port | Protocol | Purpose |
|---|---|---|
| 22 | TCP | SSH |
| 80 | TCP | nginx → Grafana |
| 3000 | TCP | Grafana direct access |
| 9090 | TCP | Prometheus |
| 3100 | TCP | Loki push endpoint (agents push logs here) |
| 9080 | TCP | Promtail metrics |
| 9100 | TCP | node_exporter |
| 161 | UDP | SNMP (LibreNMS) |

If a router VM IP was provided, an additional targeted rule is added:
```
ALLOW from ROUTER_VM_IP to port 3100
```

### Service locations

| File | Purpose |
|---|---|
| `/etc/prometheus/prometheus.yml` | Prometheus scrape configuration |
| `/var/lib/prometheus/` | Prometheus time-series data |
| `/etc/loki/config.yml` | Loki configuration |
| `/var/lib/loki/` | Loki log storage |
| `/etc/promtail/config.yml` | Promtail scrape config |
| `/var/lib/promtail/positions.yaml` | Promtail file tracking |

### Step 2 — First login to Grafana

Browse to `http://YOUR_MONITORING_VM_IP` and log in with `admin` / `admin`. You will be prompted to change the password immediately — do this before proceeding.

### Step 3 — Add data sources

In Grafana go to **Connections → Data Sources → Add new data source**.

**Prometheus:**
- Type: `Prometheus`
- URL: `http://localhost:9090`
- Click **Save & Test** — should show "Successfully queried the Prometheus API"

**Loki:**
- Type: `Loki`
- URL: `http://localhost:3100`
- Click **Save & Test** — should show "Data source connected and labels found"

### Step 4 — Import dashboards

**Node Exporter Full** (host metrics for all VMs):

Go to **Dashboards → Import**, enter ID `1860`, select your Prometheus data source, click **Import**.

**LiteLLM Router Dashboard** (custom, matched to your metric names):

Go to **Dashboards → Import → Upload JSON file**, select `litellm-dashboard-fixed.json`, choose your Prometheus data source, click **Import**.

> The official LiteLLM Grafana dashboard uses metric names from an older version and will show "No data". The included `litellm-dashboard-fixed.json` uses the correct metric names for the current LiteLLM version.

### Step 5 — Wire in the router VM

After the router VM is installed, add its scrape jobs to Prometheus.

Edit `/etc/prometheus/prometheus.yml` on the monitoring VM and add under `scrape_configs`:

```yaml
  - job_name: 'litellm'
    scrape_interval: 15s
    metrics_path: '/metrics/'
    follow_redirects: false
    authorization:
      credentials: 'YOUR_LITELLM_MASTER_KEY'
    static_configs:
      - targets: ['ROUTER_VM_IP:4000']
        labels:
          host: 'router-vm'

  - job_name: 'node-router-vm'
    static_configs:
      - targets: ['ROUTER_VM_IP:9100']
        labels:
          host: 'router-vm'
```

> **Important:** `metrics_path` must use a trailing slash (`/metrics/`) and `follow_redirects: false` is required. LiteLLM issues a 307 redirect on `/metrics` (no slash) pointing to `http://localhost:4000/metrics/`. Prometheus follows this redirect, but `localhost` resolves to the monitoring VM — not the router VM — causing a connection timeout. The trailing slash avoids the redirect entirely.
>
> Use `authorization: credentials:` format, not `bearer_token:` — the latter caused silent auth failures in testing.

Validate and reload without restarting Prometheus:

```bash
sudo /usr/local/bin/promtool check config /etc/prometheus/prometheus.yml
curl -X POST http://localhost:9090/-/reload
```

Verify at `http://YOUR_MONITORING_VM:9090/targets` — both `litellm` and `node-router-vm` should show `health: up`.

### Adding further hosts

For any additional VM you want to monitor, install node_exporter on it (see the pattern in Runbook B below), then add a scrape job:

```yaml
  - job_name: 'node-HOSTNAME'
    static_configs:
      - targets: ['HOST_IP:9100']
        labels:
          host: 'HOSTNAME'
```

Reload Prometheus after adding:
```bash
curl -X POST http://localhost:9090/-/reload
```

---

## Router VM Setup

### Step 1 — Prepare your Ollama server

Before running the install script, confirm on the Ollama server that:

1. Ollama is bound to `0.0.0.0` (not just `localhost`):
   ```bash
   sudo ss -tlnp | grep ollama
   # Should show 0.0.0.0:PORT not 127.0.0.1:PORT
   ```
   If it shows `127.0.0.1`, add an environment override:
   ```bash
   sudo systemctl edit ollama
   # Add:
   # [Service]
   # Environment="OLLAMA_HOST=0.0.0.0"
   sudo systemctl restart ollama
   ```

2. Your model is pulled:
   ```bash
   ollama list
   ollama pull YOUR_MODEL_NAME   # if not already present
   ```

3. The OpenAI-compatible endpoint responds:
   ```bash
   curl http://OLLAMA_IP:PORT/v1/models
   ```

### Step 2 — Run the install script

```bash
sudo bash install-router-vm.sh
```

### What the script prompts for

| Prompt | Description | Example |
|---|---|---|
| OpenRouter API key | Your key from openrouter.ai/keys | `sk-or-v1-...` |
| LiteLLM master key | Key clients use to authenticate — you choose this | `sk-myrouter-abc123` |
| Monitoring VM IP | IP of your dashboard VM | `192.168.1.42` |
| Ollama host IP | IP of the machine running Ollama | `192.168.1.48` |
| Ollama port | Port Ollama is listening on | `18434` |
| Ollama model name | Model to use for local inference | `qwen3.5:35b-a3b` |

After entering the Ollama host and port, the script verifies connectivity and displays all available models on that server to help confirm the model name.

If a config file exists from a previous run, you are offered the option to reuse it and skip to unfinished steps.

### What gets installed

| Component | Purpose |
|---|---|
| LiteLLM (Python venv in `/opt/litellm/venv`) | LLM routing proxy |
| prometheus-client (Python package) | Enables the `/metrics/` endpoint |
| node_exporter | Host metrics → monitoring VM Prometheus |
| Promtail | Ships LiteLLM logs → monitoring VM Loki |

> **Note:** Ollama is not installed by this script. It is assumed to be running on a separate server. The script only configures LiteLLM to connect to it.

### Firewall rules configured

| Port | Protocol | Scope | Purpose |
|---|---|---|---|
| 22 | TCP | Any | SSH |
| 4000 | TCP | Any | LiteLLM proxy |
| 9100 | TCP | Any | node_exporter |
| 9080 | TCP | Any | Promtail metrics |
| 161 | UDP | Any | SNMP (LibreNMS) |
| 4000 | TCP | Monitoring VM IP | Targeted allow |
| 9100 | TCP | Monitoring VM IP | Targeted allow |

### Config file locations

| File | Purpose |
|---|---|
| `/etc/litellm/config.yaml` | LiteLLM model list, routing, settings |
| `/etc/litellm/.env` | API keys and secrets (chmod 600) |
| `/var/log/litellm/litellm.log` | LiteLLM structured JSON log |
| `/etc/promtail/config.yml` | Promtail log shipping config |
| `/etc/systemd/system/litellm.service` | LiteLLM systemd unit |

### Virtual model tiers

These are the model names clients use when talking to the router. Each tier routes to a specific backend with automatic fallback.

| Tier | Primary backend | Fallback chain | Best for |
|---|---|---|---|
| `fast` | Local Ollama | Llama 70B → magic router | Simple tasks, zero cost, lowest latency |
| `default` | Local Ollama | Llama 70B → magic router | General use, local-first |
| `agentic` | Llama 3.3 70B (cloud) | Nemotron 120B → Hermes 405B → magic router | Tool calls, multi-step agents |
| `coding` | Qwen3 Coder (cloud) | Nemotron 120B → Llama 70B → magic router | Code generation and reasoning |

### Named cloud backends

These can be referenced directly in requests or used in custom fallback chains:

| Name | Model | Notes |
|---|---|---|
| `cloud/free` | `openrouter/free` magic router | Auto-selects best available free model |
| `cloud/llama70b-free` | Llama 3.3 70B Instruct | Reliable, good tool call support |
| `cloud/nemotron-free` | Nvidia Nemotron 120B MoE | High capability, ~12B active params |
| `cloud/qwen-coder-free` | Qwen3 Coder | Code-optimised |
| `cloud/hermes-free` | Hermes 3 Llama 3.1 405B | Large model, complex tasks |

> **Free model availability changes.** OpenRouter adds and removes free-tier endpoints regularly. Check current availability at `https://openrouter.ai/models?q=:free`. If models stop working, update `config.yaml` and restart LiteLLM.

### Pointing Hermes at the router

Run `hermes model` and configure:

```
Provider:  openai-compatible
Base URL:  http://ROUTER_VM_IP:4000
API Key:   YOUR_LITELLM_MASTER_KEY
Model:     default
```

For agentic coding sessions with heavy tool use, set the model to `agentic` instead of `default`.

---

## Configuration Reference

### LiteLLM config (`/etc/litellm/config.yaml`)

**Adding a new Ollama model:**
```yaml
- model_name: "local/my-new-model"
  litellm_params:
    model: "openai/my-new-model"
    api_base: "http://OLLAMA_HOST:PORT/v1"
    api_key: "ollama"
    stream: true
```

**Adding a new OpenRouter model:**
```yaml
- model_name: "cloud/my-model"
  litellm_params:
    model: "openrouter/provider/model-name:free"
    api_key: "os.environ/OPENROUTER_API_KEY"
    api_base: "https://openrouter.ai/api/v1"
    stream: true
```

**Key settings explained:**

| Setting | Value | Why |
|---|---|---|
| `require_auth_for_metrics_endpoint` | `false` | Must be false without a database — when true, `/metrics/` returns an empty body (not 401), causing Prometheus to report a timeout |
| `drop_params: false` | `false` | Passes unknown parameters through to backends — required for Hermes tool calls |
| `json_logs: true` | `true` | Structured JSON output — required for Promtail to parse and Loki to index |
| `follow_redirects` (Prometheus) | `false` | Prevents Prometheus following LiteLLM's 307 redirect to localhost |

After editing `config.yaml`, restart LiteLLM:
```bash
sudo systemctl restart litellm
```

### Secrets file (`/etc/litellm/.env`)

```bash
OPENROUTER_API_KEY=sk-or-v1-...
LITELLM_MASTER_KEY=sk-yourkey
OLLAMA_API_BASE=http://OLLAMA_HOST:PORT/v1
MONITORING_VM_IP=192.168.1.42
OLLAMA_HOST=192.168.1.48
OLLAMA_PORT=18434
OLLAMA_MODEL=qwen3.5:35b-a3b
```

This file is `chmod 600` owned by the `litellm` user. To update a key:

```bash
sudo nano /etc/litellm/.env
sudo systemctl restart litellm
```

### Prometheus config (`/etc/prometheus/prometheus.yml`)

Reload without restarting Prometheus after any edit:
```bash
sudo /usr/local/bin/promtool check config /etc/prometheus/prometheus.yml
curl -X POST http://localhost:9090/-/reload
```

---

## Operations

### Monitoring VM

```bash
# Service status
sudo systemctl status prometheus loki grafana-server promtail nginx

# Live logs
sudo journalctl -u prometheus -f
sudo journalctl -u loki -f
sudo journalctl -u grafana-server -f

# Reload Prometheus config (no restart)
curl -X POST http://localhost:9090/-/reload

# Check Prometheus targets
curl -s http://localhost:9090/api/v1/targets | python3 -m json.tool | grep -E '"job"|"health"|"lastError"'

# Test Loki is receiving logs (use query_range, not instant query)
curl -s -G http://localhost:3100/loki/api/v1/query_range \
  --data-urlencode 'query={job="litellm"}' \
  --data-urlencode "start=$(date -d '1 hour ago' +%s)000000000" \
  --data-urlencode "end=$(date +%s)000000000" \
  --data-urlencode 'limit=5' | python3 -m json.tool | head -20

# Upgrade Prometheus
# Download new binary, replace /usr/local/bin/prometheus, restart service

# Upgrade Grafana
sudo apt update && sudo apt upgrade grafana
```

### Router VM

```bash
# Service status
sudo systemctl status litellm node_exporter promtail

# Live LiteLLM log
sudo tail -f /var/log/litellm/litellm.log

# Journal log (startup errors, crashes)
sudo journalctl -u litellm -f

# Health check
curl -s http://localhost:4000/health

# Test routing (fast tier → local Ollama)
curl -s http://localhost:4000/v1/chat/completions \
  -H "Authorization: Bearer YOUR_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"fast","messages":[{"role":"user","content":"Reply with one word: working"}]}' \
  | python3 -m json.tool

# Test routing (agentic tier → cloud)
curl -s http://localhost:4000/v1/chat/completions \
  -H "Authorization: Bearer YOUR_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"agentic","messages":[{"role":"user","content":"Reply with one word: working"}]}' \
  | python3 -m json.tool

# List available models
curl -s http://localhost:4000/v1/models \
  -H "Authorization: Bearer YOUR_MASTER_KEY" | python3 -m json.tool

# View current free OpenRouter models
curl -s https://openrouter.ai/api/v1/models \
  -H "Authorization: Bearer YOUR_OPENROUTER_KEY" \
  | python3 -m json.tool | grep '"id"' | grep ':free' | sort

# Upgrade LiteLLM
sudo -u litellm /opt/litellm/venv/bin/pip install --upgrade 'litellm[proxy]' prometheus-client
sudo systemctl restart litellm
```

---

## Troubleshooting

### Prometheus shows "context deadline exceeded" for litellm target

LiteLLM returns a 307 redirect on `/metrics` (no trailing slash) pointing to `http://localhost:4000/metrics/`. When Prometheus follows this, `localhost` resolves to the monitoring VM — not the router VM — causing a timeout.

**Fix:** Ensure `prometheus.yml` has `metrics_path: '/metrics/'` (trailing slash) and `follow_redirects: false`.

### Prometheus shows 401 for litellm target

The credentials in `prometheus.yml` don't match the `LITELLM_MASTER_KEY` in `/etc/litellm/.env`.

**Fix:** Copy the exact key from the `.env` file and paste it into the `credentials:` field in `prometheus.yml`. Use `authorization: credentials:` format, not `bearer_token:`.

### LiteLLM crashes on startup with `ModuleNotFoundError: No module named 'prometheus_client'`

The `prometheus-client` Python package is not installed in the venv.

**Fix:**
```bash
sudo -u litellm /opt/litellm/venv/bin/pip install prometheus-client
sudo systemctl restart litellm
```

### LiteLLM crashes with "LLM Provider NOT provided"

A virtual model tier (`default`, `fast`, `agentic`, `coding`) has a model alias reference instead of full `litellm_params`. For example:

```yaml
# WRONG — causes crash
- model_name: "default"
  litellm_params:
    model: "local/mymodel"   # this is an alias, not a provider string
```

**Fix:** Each virtual tier must have full provider details:

```yaml
# CORRECT
- model_name: "default"
  litellm_params:
    model: "openai/mymodel"
    api_base: "http://OLLAMA_HOST:PORT/v1"
    api_key: "ollama"
    stream: true
```

### Prometheus config parse error: "did not find expected key"

YAML indentation is wrong. All scrape job entries under `scrape_configs:` must use exactly 2 spaces of indentation. A single missing space causes this error.

**Fix:** Always validate before reloading:
```bash
sudo /usr/local/bin/promtool check config /etc/prometheus/prometheus.yml
```

### Loki query returns empty even though Promtail is running

The instant query endpoint (`/loki/api/v1/query`) uses a very short default time window and returns empty for recently ingested data. Use the range query instead:

```bash
curl -s -G http://localhost:3100/loki/api/v1/query_range \
  --data-urlencode 'query={job="litellm"}' \
  --data-urlencode "start=$(date -d '1 hour ago' +%s)000000000" \
  --data-urlencode "end=$(date +%s)000000000" \
  --data-urlencode 'limit=5'
```

### OpenRouter returns "User not found" 401

The OpenRouter account needs to complete a one-time verification step with credits added, even for free-tier models. Visit `https://openrouter.ai/settings` and check for any pending verification or billing setup steps.

### OpenRouter returns "No endpoints found" for a specific model

The free-tier endpoint for that model is temporarily unavailable. Free model availability fluctuates. The `cloud/free` magic router fallback handles this automatically by routing to whichever free models are currently available.

To see which free models are currently available:
```bash
curl -s https://openrouter.ai/api/v1/models \
  -H "Authorization: Bearer YOUR_OPENROUTER_KEY" \
  | python3 -m json.tool | grep '"id"' | grep ':free' | sort
```

### Routing test times out but Ollama is reachable

The model may still be loading into VRAM. Large models (30B+) can take 30-60 seconds to load on first request. Wait a minute and retry. Check Ollama's activity:
```bash
curl http://OLLAMA_HOST:PORT/api/ps
```

---

## Step Tracking and Re-runs

Both scripts track completed steps in a state directory:

- Monitoring VM: `/var/lib/monitoring-install/`
- Router VM: `/var/lib/router-install/`

Each step writes a flag file when it completes. On re-run, completed steps are skipped. This means:

- If the script fails partway through, re-run it and it resumes from where it stopped
- If you want to force a step to re-run, delete its flag file:
  ```bash
  # Example: force LiteLLM config to be rewritten
  sudo rm /var/lib/router-install/litellm_config
  sudo bash install-router-vm.sh
  ```
- To force a complete fresh install, remove the entire tracking directory:
  ```bash
  sudo rm -rf /var/lib/router-install/
  sudo bash install-router-vm.sh
  ```

---

## Adding New Hosts to Monitoring

For any new VM you want to add to the monitoring stack:

**On the new host**, install node_exporter:
```bash
NODE_VERSION="1.8.2"
cd /tmp
wget -q "https://github.com/prometheus/node_exporter/releases/download/v${NODE_VERSION}/node_exporter-${NODE_VERSION}.linux-amd64.tar.gz" \
  -O node_exporter.tar.gz
tar xf node_exporter.tar.gz
sudo cp node_exporter-${NODE_VERSION}.linux-amd64/node_exporter /usr/local/bin/
sudo useradd --system --no-create-home --shell /usr/sbin/nologin prometheus 2>/dev/null || true

sudo tee /etc/systemd/system/node_exporter.service << 'EOF'
[Unit]
Description=Prometheus Node Exporter
After=network-online.target
[Service]
User=prometheus
ExecStart=/usr/local/bin/node_exporter
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now node_exporter
sudo ufw allow from MONITORING_VM_IP to any port 9100
```

**On the monitoring VM**, add the scrape job and reload:
```bash
sudo nano /etc/prometheus/prometheus.yml
# Add under scrape_configs:
#   - job_name: 'node-NEWHOSTNAME'
#     static_configs:
#       - targets: ['NEW_HOST_IP:9100']
#         labels:
#           host: 'NEWHOSTNAME'

sudo /usr/local/bin/promtool check config /etc/prometheus/prometheus.yml
curl -X POST http://localhost:9090/-/reload
```

The new host immediately appears in Grafana's Node Exporter Full dashboard via the `host` label filter.

---

## Dashboard Panels (LiteLLM Router Dashboard)

The custom `litellm-dashboard-fixed.json` includes 14 panels:

| Panel | Metric | Description |
|---|---|---|
| Requests per Second | `litellm_proxy_total_requests_metric_total` | Request rate across all tiers |
| Failed Requests/s | `litellm_proxy_failed_requests_metric_total` | Client-facing failures |
| Average Request Latency | `litellm_request_total_latency_metric` | End-to-end latency including routing overhead |
| Token Usage Rate | `litellm_input/output/total_tokens_metric_total` | Input, output, and total tokens per minute |
| Requests by Deployment | `litellm_deployment_total_requests_total` | Per-model request breakdown |
| Success vs Failure by Deployment | `litellm_deployment_success/failure_responses_total` | Per-model success rate |
| In-Flight Requests | `litellm_in_flight_requests` | Current concurrent requests |
| Spend Rate | `litellm_spend_metric_total` | USD per hour (cloud models only) |
| Total Requests | `litellm_proxy_total_requests_metric_total` | Cumulative counter |
| Total Tokens | `litellm_total_tokens_metric_total` | Cumulative counter |
| Total Spend | `litellm_spend_metric_total` | Cumulative USD |
| Successful Fallbacks | `litellm_deployment_successful_fallbacks_total` | Fallback events |
| Deployment State | `litellm_deployment_state` | 0=healthy, 1=partial, 2=down |
| LiteLLM Overhead Latency | `litellm_overhead_latency_metric` | Router processing time in ms |

---

## Security Notes

- The `/etc/litellm/.env` file is `chmod 600` — keep it that way. It contains your OpenRouter API key and LiteLLM master key.
- The LiteLLM `/metrics/` endpoint is open without authentication (`require_auth_for_metrics_endpoint: false`). This is intentional — authentication without a database causes silent failures. If you add a Postgres database to LiteLLM in future, you can re-enable this.
- Prometheus on the monitoring VM is unauthenticated on port 9090. Consider restricting this to trusted IPs with a ufw rule if the VM is on a shared network.
- Grafana admin password should be changed immediately after first login.
- LibreNMS SNMP access (port 161/udp) is open to all by default. Restrict with a ufw rule if needed: `sudo ufw allow from LIBRENMS_IP to any port 161 proto udp`.
