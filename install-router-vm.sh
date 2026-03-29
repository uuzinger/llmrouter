#!/usr/bin/env bash
# ==============================================================================
# install-router-vm.sh  v2
# LLM Router VM — LiteLLM + Monitoring Agents (node_exporter + Promtail)
#
# Usage:
#   sudo bash install-router-vm.sh
#
# Prompts for:
#   - OpenRouter API key
#   - LiteLLM master key (clients use this to authenticate)
#   - Monitoring VM IP  (Prometheus + Loki destination)
#   - Ollama host IP    (remote inference server)
#   - Ollama port       (confirm with: ss -tlnp | grep ollama)
#   - Ollama model name (must already be pulled on the Ollama server)
#
# Re-runnable: completed steps tracked in /var/lib/router-install/
#
# Changes from v1 (all from production troubleshooting):
#   - SNMP (161/udp) added to firewall for LibreNMS
#   - Monitoring VM targeted firewall rules (4000 + 9100) added on install —
#     these were missing in v1 and had to be added manually
#   - Ollama port prompted instead of hardcoded (was 11834, actual was 18434)
#   - Ollama URL format: openai/ prefix + /v1 api_base path, not ollama_chat/
#     (required for OpenAI-compatible Ollama endpoint)
#   - api_key: "ollama" added to Ollama entries (openai/ provider requires it)
#   - Virtual model tiers (default/fast/agentic/coding) now have full
#     litellm_params — using alias references caused "LLM Provider NOT
#     provided" crash on startup
#   - require_auth_for_metrics_endpoint: false — when true without a DB,
#     /metrics returns empty body causing Prometheus "context deadline
#     exceeded" rather than a visible auth error
#   - prometheus-client pip package installed alongside litellm — without
#     it LiteLLM crashes with ModuleNotFoundError on startup
#   - Free OpenRouter models updated to currently-available ones
#   - Monitoring instructions corrected: metrics_path '/metrics/' (trailing
#     slash), follow_redirects: false, authorization: credentials: format
#   - Ollama reachability check during preflight with model list display
#   - Log directory world-readable so Promtail can read log files
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Version pins
# ------------------------------------------------------------------------------
NODE_EXPORTER_VERSION="1.8.2"
LOKI_VERSION="3.5.1"
LITELLM_PACKAGE="litellm[proxy]"

# Step tracking
STEP_DIR="/var/lib/router-install"

# Config paths
LITELLM_DIR="/etc/litellm"
LITELLM_CONFIG="${LITELLM_DIR}/config.yaml"
LITELLM_ENV="${LITELLM_DIR}/.env"
LITELLM_HOME="/opt/litellm"
LITELLM_LOG_DIR="/var/log/litellm"

PROMTAIL_DIR="/etc/promtail"
PROMTAIL_LIB="/var/lib/promtail"

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------
PHASE=0

phase() {
  PHASE=$((PHASE + 1))
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  Phase ${PHASE}: $*"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

log()  { echo "  [$(date '+%H:%M:%S')] $*"; }
ok()   { echo "  ✓  $*"; }
skip() { echo "  ↷  Already done — skipping: $*"; }
warn() { echo "  ⚠  $*"; }
err()  { echo ""; echo "  ✗  ERROR: $*" >&2; echo ""; exit 1; }

step_done()     { touch "${STEP_DIR}/$1"; }
step_complete() { [[ -f "${STEP_DIR}/$1" ]]; }

require_root() {
  [[ $EUID -eq 0 ]] || err "Run this script with sudo: sudo bash $0"
}

get_local_ip() {
  hostname -I | awk '{print $1}'
}

valid_ip() {
  [[ "$1" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]
}

valid_key() {
  [[ "$1" =~ ^sk-.{8,} ]]
}

valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && [[ "$1" -ge 1 ]] && [[ "$1" -le 65535 ]]
}

# ------------------------------------------------------------------------------
# Config — populated during preflight
# ------------------------------------------------------------------------------
OPENROUTER_API_KEY=""
LITELLM_MASTER_KEY=""
MONITORING_VM_IP=""
OLLAMA_HOST=""
OLLAMA_PORT=""
OLLAMA_MODEL=""

# ------------------------------------------------------------------------------
# Preflight — gather config interactively
# ------------------------------------------------------------------------------
preflight() {
  phase "Preflight — configuration"

  require_root
  mkdir -p "$STEP_DIR"

  LOCAL_IP=$(get_local_ip)
  echo ""
  echo "  LLM Router VM Installation  v2"
  echo "  Local IP detected: ${LOCAL_IP}"
  echo ""

  # Offer to reuse existing config from a previous run
  if [[ -f "${LITELLM_ENV}" ]]; then
    echo "  ┌──────────────────────────────────────────────────────┐"
    echo "  │  Existing config found at ${LITELLM_ENV}            │"
    echo "  └──────────────────────────────────────────────────────┘"
    read -rp "  Reuse existing config and resume unfinished steps? [Y/n]: " reuse
    if [[ "${reuse,,}" != "n" ]]; then
      # shellcheck source=/dev/null
      source "${LITELLM_ENV}"
      OPENROUTER_API_KEY="${OPENROUTER_API_KEY:-}"
      LITELLM_MASTER_KEY="${LITELLM_MASTER_KEY:-}"
      MONITORING_VM_IP="${MONITORING_VM_IP:-}"
      OLLAMA_HOST="${OLLAMA_HOST:-}"
      OLLAMA_PORT="${OLLAMA_PORT:-11434}"
      OLLAMA_MODEL="${OLLAMA_MODEL:-}"
      ok "Reusing existing config"
      echo ""
      echo "  Ollama       : ${OLLAMA_HOST}:${OLLAMA_PORT}"
      echo "  Model        : ${OLLAMA_MODEL}"
      echo "  Monitoring VM: ${MONITORING_VM_IP}"
      echo ""
      return
    fi
  fi

  # ── OpenRouter ──────────────────────────────────────────────────────────────
  echo ""
  echo "  ── OpenRouter ────────────────────────────────────────"
  echo "  Get your key at: https://openrouter.ai/keys"
  echo "  Note: free-tier models require a verified account with"
  echo "  credits added — check openrouter.ai/settings after signup."
  while true; do
    read -rsp "  OpenRouter API key (sk-or-...): " OPENROUTER_API_KEY
    echo ""
    [[ -n "$OPENROUTER_API_KEY" ]] && break
    warn "API key cannot be empty"
  done

  # ── LiteLLM master key ──────────────────────────────────────────────────────
  echo ""
  echo "  ── LiteLLM Master Key ────────────────────────────────"
  echo "  Clients (Hermes etc.) use this to authenticate."
  echo "  Must start with sk- and be at least 10 characters."
  while true; do
    read -rsp "  LiteLLM master key (sk-...): " LITELLM_MASTER_KEY
    echo ""
    if valid_key "$LITELLM_MASTER_KEY"; then
      break
    else
      warn "Key must start with 'sk-' and be at least 10 characters"
    fi
  done

  # ── Monitoring VM ───────────────────────────────────────────────────────────
  echo ""
  echo "  ── Monitoring VM ─────────────────────────────────────"
  echo "  IP of the dashboard VM running Prometheus + Loki."
  while true; do
    read -rp "  Monitoring VM IP: " MONITORING_VM_IP
    if valid_ip "$MONITORING_VM_IP"; then
      break
    else
      warn "Please enter a valid IP address (e.g. 192.168.1.42)"
    fi
  done

  # ── Ollama host ─────────────────────────────────────────────────────────────
  echo ""
  echo "  ── Ollama Inference Server ───────────────────────────"
  echo "  IP of the machine running Ollama."
  while true; do
    read -rp "  Ollama host IP: " OLLAMA_HOST
    if valid_ip "$OLLAMA_HOST"; then
      break
    else
      warn "Please enter a valid IP address"
    fi
  done

  echo ""
  echo "  Port Ollama is listening on."
  echo "  Verify on the Ollama server with: ss -tlnp | grep ollama"
  echo "  Common values: 11434 (default Ollama), 18434, 11834"
  while true; do
    read -rp "  Ollama port [11434]: " OLLAMA_PORT
    OLLAMA_PORT="${OLLAMA_PORT:-11434}"
    if valid_port "$OLLAMA_PORT"; then
      break
    else
      warn "Please enter a valid port number (1-65535)"
    fi
  done

  # Verify Ollama reachability and show available models
  echo ""
  log "Verifying Ollama at http://${OLLAMA_HOST}:${OLLAMA_PORT}/v1/models ..."
  if curl -sf --max-time 5 "http://${OLLAMA_HOST}:${OLLAMA_PORT}/v1/models" > /dev/null 2>&1; then
    ok "Ollama reachable"
    echo ""
    echo "  Models available on ${OLLAMA_HOST}:${OLLAMA_PORT}:"
    curl -sf --max-time 5 "http://${OLLAMA_HOST}:${OLLAMA_PORT}/v1/models" \
      | python3 -c "
import json,sys
data=json.load(sys.stdin)
for m in data.get('data',[]):
    print('    -', m['id'])
" 2>/dev/null || echo "    (could not parse model list)"
    echo ""
  else
    warn "Cannot reach Ollama at http://${OLLAMA_HOST}:${OLLAMA_PORT}/v1/models"
    warn "Ensure Ollama is running and bound to 0.0.0.0 not just localhost:"
    warn "  OLLAMA_HOST=0.0.0.0 in /etc/systemd/system/ollama.service.d/override.conf"
    warn "Continuing — fix connection after install if needed."
    echo ""
  fi

  # ── Ollama model ────────────────────────────────────────────────────────────
  echo "  Model to use for local inference (must be pulled on Ollama server)."
  while true; do
    read -rp "  Ollama model name: " OLLAMA_MODEL
    [[ -n "$OLLAMA_MODEL" ]] && break
    warn "Model name cannot be empty"
  done

  # ── Summary ─────────────────────────────────────────────────────────────────
  echo ""
  echo "  ── Configuration Summary ─────────────────────────────"
  echo "  OpenRouter key : ${OPENROUTER_API_KEY:0:16}..."
  echo "  LiteLLM key    : ${LITELLM_MASTER_KEY:0:16}..."
  echo "  Monitoring VM  : ${MONITORING_VM_IP}"
  echo "  Ollama server  : ${OLLAMA_HOST}:${OLLAMA_PORT}"
  echo "  Ollama model   : ${OLLAMA_MODEL}"
  echo ""
  read -rp "  Proceed with installation? [Y/n]: " confirm
  [[ "${confirm,,}" != "n" ]] || { echo "Aborted."; exit 0; }

  ok "Configuration confirmed"
}

# ------------------------------------------------------------------------------
# Phase 1 — System baseline
# ------------------------------------------------------------------------------
install_baseline() {
  phase "System baseline"

  if step_complete "baseline"; then
    skip "baseline packages"
    return
  fi

  log "Updating package lists..."
  apt-get update -qq

  log "Upgrading installed packages..."
  DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y -qq

  log "Installing dependencies..."
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    python3 \
    python3-pip \
    python3-venv \
    curl \
    wget \
    unzip \
    ufw

  step_done "baseline"
  ok "Baseline complete"
}

# ------------------------------------------------------------------------------
# Phase 2 — Firewall
# ------------------------------------------------------------------------------
configure_firewall() {
  phase "Firewall (ufw)"

  if step_complete "firewall"; then
    skip "firewall rules"
    return
  fi

  log "Configuring ufw rules..."
  ufw --force reset > /dev/null 2>&1

  ufw default deny incoming  > /dev/null
  ufw default allow outgoing > /dev/null

  ufw allow OpenSSH          > /dev/null   # SSH — always first
  ufw allow 4000/tcp         > /dev/null   # LiteLLM proxy (all clients)
  ufw allow 9100/tcp         > /dev/null   # node_exporter scrape
  ufw allow 9080/tcp         > /dev/null   # Promtail metrics
  ufw allow 161/udp          > /dev/null   # SNMP (LibreNMS)

  # Targeted rules for the monitoring VM — ensures scraping works even
  # if the broad rules above are later tightened
  ufw allow from "${MONITORING_VM_IP}" to any port 4000 > /dev/null
  ufw allow from "${MONITORING_VM_IP}" to any port 9100 > /dev/null
  ok "Added monitoring VM rules for: ${MONITORING_VM_IP}"

  ufw --force enable > /dev/null

  ok "Firewall configured:"
  echo ""
  ufw status | sed 's/^/     /'
  echo ""

  step_done "firewall"
}

# ------------------------------------------------------------------------------
# Phase 3 — LiteLLM directories and user
# ------------------------------------------------------------------------------
setup_litellm_dirs() {
  phase "LiteLLM directories and user"

  if step_complete "litellm_dirs"; then
    skip "LiteLLM directories"
    return
  fi

  if id litellm &>/dev/null; then
    log "User 'litellm' already exists"
  else
    useradd --system --shell /usr/sbin/nologin \
      --create-home --home-dir "${LITELLM_HOME}" litellm
    ok "Created user: litellm"
  fi

  mkdir -p "${LITELLM_DIR}" "${LITELLM_LOG_DIR}" "${LITELLM_HOME}"
  chown litellm:litellm "${LITELLM_DIR}" "${LITELLM_LOG_DIR}" "${LITELLM_HOME}"
  chmod 750 "${LITELLM_DIR}"
  # World-readable so Promtail can read log files regardless of group
  # membership timing during install
  chmod 755 "${LITELLM_LOG_DIR}"

  step_done "litellm_dirs"
  ok "Directories created"
}

# ------------------------------------------------------------------------------
# Phase 4 — LiteLLM Python install
# ------------------------------------------------------------------------------
install_litellm() {
  phase "LiteLLM (Python venv)"

  if ! step_complete "litellm_venv"; then
    log "Creating Python venv at ${LITELLM_HOME}/venv..."
    sudo -u litellm python3 -m venv "${LITELLM_HOME}/venv"
    step_done "litellm_venv"
    ok "venv created"
  else
    skip "litellm venv"
  fi

  if ! step_complete "litellm_pip"; then
    log "Installing ${LITELLM_PACKAGE} (this takes a few minutes)..."
    sudo -u litellm "${LITELLM_HOME}/venv/bin/pip" install --upgrade pip -q
    sudo -u litellm "${LITELLM_HOME}/venv/bin/pip" install "${LITELLM_PACKAGE}" -q

    # prometheus-client is a separate package required for the /metrics endpoint.
    # Without it, LiteLLM crashes on startup with:
    #   ModuleNotFoundError: No module named 'prometheus_client'
    # when callbacks: ["prometheus"] is set in config.
    log "Installing prometheus-client (required for /metrics endpoint)..."
    sudo -u litellm "${LITELLM_HOME}/venv/bin/pip" install prometheus-client -q

    step_done "litellm_pip"
    ok "LiteLLM installed"
  else
    skip "litellm pip install"
    # Ensure prometheus-client is present even on re-runs
    if ! sudo -u litellm "${LITELLM_HOME}/venv/bin/pip" show prometheus-client &>/dev/null; then
      log "Installing missing prometheus-client..."
      sudo -u litellm "${LITELLM_HOME}/venv/bin/pip" install prometheus-client -q
      ok "prometheus-client installed"
    fi
  fi

  LITELLM_VERSION=$("${LITELLM_HOME}/venv/bin/litellm" --version 2>/dev/null || echo "unknown")
  log "LiteLLM version: ${LITELLM_VERSION}"
}

# ------------------------------------------------------------------------------
# Phase 5 — Write config files
# ------------------------------------------------------------------------------
write_litellm_config() {
  phase "LiteLLM configuration"

  if ! step_complete "litellm_env"; then
    log "Writing secrets file: ${LITELLM_ENV}"
    cat > "${LITELLM_ENV}" << EOF
OPENROUTER_API_KEY=${OPENROUTER_API_KEY}
LITELLM_MASTER_KEY=${LITELLM_MASTER_KEY}
OLLAMA_API_BASE=http://${OLLAMA_HOST}:${OLLAMA_PORT}/v1
MONITORING_VM_IP=${MONITORING_VM_IP}
OLLAMA_HOST=${OLLAMA_HOST}
OLLAMA_PORT=${OLLAMA_PORT}
OLLAMA_MODEL=${OLLAMA_MODEL}
EOF
    chmod 600 "${LITELLM_ENV}"
    chown litellm:litellm "${LITELLM_ENV}"
    step_done "litellm_env"
    ok "Secrets file written (chmod 600)"
  else
    skip "litellm env file"
  fi

  if ! step_complete "litellm_config"; then
    log "Writing LiteLLM config: ${LITELLM_CONFIG}"
    cat > "${LITELLM_CONFIG}" << EOF
# ==============================================================================
# LiteLLM Router Config  v2
# Generated by install-router-vm.sh
#
# To change models: edit model_list, then:
#   sudo systemctl restart litellm
#
# Free model list changes frequently — check:
#   https://openrouter.ai/models?q=:free
#
# To wire Prometheus on the monitoring VM, see the output of
# print_monitoring_instructions at the end of this install script.
# ==============================================================================

model_list:

  # ── Local Ollama (OpenAI-compatible /v1 endpoint) ─────────────────────────
  #
  # Uses openai/ prefix because this Ollama instance exposes an
  # OpenAI-compatible API at /v1 (not the native Ollama API).
  #
  # api_base MUST include /v1 — e.g. http://HOST:PORT/v1
  # api_key  MUST be set (openai/ provider requires it; Ollama ignores the value)

  - model_name: "local/${OLLAMA_MODEL}"
    litellm_params:
      model: "openai/${OLLAMA_MODEL}"
      api_base: "http://${OLLAMA_HOST}:${OLLAMA_PORT}/v1"
      api_key: "ollama"
      stream: true

  # ── OpenRouter free models ────────────────────────────────────────────────
  # Free tier requires a verified OpenRouter account with credits added.
  # Rate limits: ~10-20 req/min per model. The magic router spreads load.

  # Magic router — OpenRouter picks best available free model automatically
  - model_name: "cloud/free"
    litellm_params:
      model: "openrouter/openrouter/free"
      api_key: "os.environ/OPENROUTER_API_KEY"
      api_base: "https://openrouter.ai/api/v1"
      stream: true

  # Llama 3.3 70B — reliable, strong tool call support
  - model_name: "cloud/llama70b-free"
    litellm_params:
      model: "openrouter/meta-llama/llama-3.3-70b-instruct:free"
      api_key: "os.environ/OPENROUTER_API_KEY"
      api_base: "https://openrouter.ai/api/v1"
      stream: true

  # Nemotron 120B MoE — high capability, activates ~12B params per token
  - model_name: "cloud/nemotron-free"
    litellm_params:
      model: "openrouter/nvidia/nemotron-3-super-120b-a12b:free"
      api_key: "os.environ/OPENROUTER_API_KEY"
      api_base: "https://openrouter.ai/api/v1"
      stream: true

  # Qwen3 Coder — optimised for coding tasks
  - model_name: "cloud/qwen-coder-free"
    litellm_params:
      model: "openrouter/qwen/qwen3-coder:free"
      api_key: "os.environ/OPENROUTER_API_KEY"
      api_base: "https://openrouter.ai/api/v1"
      stream: true

  # Hermes 3 405B — large model, good for complex agentic work
  - model_name: "cloud/hermes-free"
    litellm_params:
      model: "openrouter/nousresearch/hermes-3-llama-3.1-405b:free"
      api_key: "os.environ/OPENROUTER_API_KEY"
      api_base: "https://openrouter.ai/api/v1"
      stream: true

  # ── Virtual model tiers ───────────────────────────────────────────────────
  #
  # IMPORTANT: Each tier must have FULL litellm_params with real provider
  # details. Do NOT use model alias references here (e.g. model: "local/X")
  # as LiteLLM cannot resolve those at the virtual tier level and will crash
  # on startup with: "LLM Provider NOT provided. You passed model=local/X"
  #
  # Fallback chains below handle automatic failover between backends.

  # fast: local Ollama only — zero cost, lowest latency
  - model_name: "fast"
    litellm_params:
      model: "openai/${OLLAMA_MODEL}"
      api_base: "http://${OLLAMA_HOST}:${OLLAMA_PORT}/v1"
      api_key: "ollama"
      stream: true

  # default: local-first, cloud fallback on failure
  - model_name: "default"
    litellm_params:
      model: "openai/${OLLAMA_MODEL}"
      api_base: "http://${OLLAMA_HOST}:${OLLAMA_PORT}/v1"
      api_key: "ollama"
      stream: true

  # agentic: cloud-first for reliable tool calls and complex reasoning
  - model_name: "agentic"
    litellm_params:
      model: "openrouter/meta-llama/llama-3.3-70b-instruct:free"
      api_key: "os.environ/OPENROUTER_API_KEY"
      api_base: "https://openrouter.ai/api/v1"
      stream: true

  # coding: reasoning-optimised cloud model
  - model_name: "coding"
    litellm_params:
      model: "openrouter/qwen/qwen3-coder:free"
      api_key: "os.environ/OPENROUTER_API_KEY"
      api_base: "https://openrouter.ai/api/v1"
      stream: true


# ── Router settings ──────────────────────────────────────────────────────────
router_settings:
  routing_strategy: "latency-based-routing"
  num_retries: 2
  timeout: 120
  allowed_fails: 3


# ── LiteLLM settings ─────────────────────────────────────────────────────────
litellm_settings:

  # Fallback chains — tried in order when primary backend fails
  fallbacks:
    - "default":  ["cloud/llama70b-free", "cloud/free"]
    - "agentic":  ["cloud/nemotron-free", "cloud/hermes-free", "cloud/free"]
    - "fast":     ["cloud/llama70b-free", "cloud/free"]
    - "coding":   ["cloud/nemotron-free", "cloud/llama70b-free", "cloud/free"]

  context_window_fallbacks:
    - "local/${OLLAMA_MODEL}": ["cloud/llama70b-free", "cloud/free"]

  # Prometheus metrics — monitoring VM scrapes /metrics/ (trailing slash)
  callbacks: ["prometheus"]
  failure_callback: ["prometheus"]
  service_callback: ["prometheus_system"]

  # Structured JSON logs — Promtail ships these to Loki
  json_logs: true

  # MUST be false when no database is configured.
  # When true without a DB, /metrics returns an empty body instead of 401,
  # causing Prometheus to report "context deadline exceeded" rather than
  # surfacing a useful auth error.
  require_auth_for_metrics_endpoint: false

  # Pass unknown params through — important for Hermes/agentic tool calls
  drop_params: false

  # Temporarily set to true to debug routing decisions
  set_verbose: false


# ── General settings ─────────────────────────────────────────────────────────
general_settings:
  master_key: "os.environ/LITELLM_MASTER_KEY"
  port: 4000
EOF
    chown litellm:litellm "${LITELLM_CONFIG}"
    step_done "litellm_config"
    ok "LiteLLM config written"
  else
    skip "litellm config"
  fi
}

# ------------------------------------------------------------------------------
# Phase 6 — LiteLLM systemd service
# ------------------------------------------------------------------------------
install_litellm_service() {
  phase "LiteLLM systemd service"

  if ! step_complete "litellm_service"; then
    log "Writing systemd unit..."
    cat > /etc/systemd/system/litellm.service << EOF
[Unit]
Description=LiteLLM LLM Router Proxy
Documentation=https://docs.litellm.ai
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=litellm
Group=litellm
WorkingDirectory=${LITELLM_HOME}

EnvironmentFile=${LITELLM_ENV}

ExecStart=${LITELLM_HOME}/venv/bin/litellm \\
    --config ${LITELLM_CONFIG} \\
    --port 4000 \\
    --host 0.0.0.0

# Append to log file so Promtail can ship logs to Loki
StandardOutput=append:${LITELLM_LOG_DIR}/litellm.log
StandardError=append:${LITELLM_LOG_DIR}/litellm.log

Restart=on-failure
RestartSec=10
StartLimitIntervalSec=60
StartLimitBurst=3

# Hardening
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=${LITELLM_HOME} ${LITELLM_LOG_DIR}

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable litellm > /dev/null
    systemctl start litellm

    step_done "litellm_service"
    ok "LiteLLM service started"
  else
    skip "litellm service"
    systemctl is-active litellm > /dev/null || systemctl start litellm
  fi
}

# ------------------------------------------------------------------------------
# Phase 7 — node_exporter
# ------------------------------------------------------------------------------
install_node_exporter() {
  phase "node_exporter ${NODE_EXPORTER_VERSION}"

  if ! step_complete "node_exporter_user"; then
    if id prometheus &>/dev/null; then
      log "User 'prometheus' already exists"
    else
      useradd --system --no-create-home --shell /usr/sbin/nologin prometheus
      ok "Created user: prometheus"
    fi
    step_done "node_exporter_user"
  fi

  if ! step_complete "node_exporter_binary"; then
    log "Downloading node_exporter ${NODE_EXPORTER_VERSION}..."
    cd /tmp
    wget -q "https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz" \
      -O "node_exporter-${NODE_EXPORTER_VERSION}.tar.gz"
    tar xf "node_exporter-${NODE_EXPORTER_VERSION}.tar.gz"
    cp "node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64/node_exporter" /usr/local/bin/
    chmod 755 /usr/local/bin/node_exporter
    chown prometheus:prometheus /usr/local/bin/node_exporter
    rm -rf "node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64" \
           "node_exporter-${NODE_EXPORTER_VERSION}.tar.gz"
    step_done "node_exporter_binary"
    ok "node_exporter binary installed"
  else
    skip "node_exporter binary"
  fi

  if ! step_complete "node_exporter_service"; then
    log "Installing node_exporter systemd service..."
    cat > /etc/systemd/system/node_exporter.service << 'EOF'
[Unit]
Description=Prometheus Node Exporter
Documentation=https://github.com/prometheus/node_exporter
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=prometheus
Group=prometheus
ExecStart=/usr/local/bin/node_exporter
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable node_exporter > /dev/null
    systemctl start node_exporter
    step_done "node_exporter_service"
    ok "node_exporter service started"
  else
    skip "node_exporter service"
    systemctl is-active node_exporter > /dev/null || systemctl start node_exporter
  fi
}

# ------------------------------------------------------------------------------
# Phase 8 — Promtail
# ------------------------------------------------------------------------------
install_promtail() {
  phase "Promtail ${LOKI_VERSION}"

  if ! step_complete "promtail_user"; then
    if id promtail &>/dev/null; then
      log "User 'promtail' already exists"
    else
      useradd --system --no-create-home --shell /usr/sbin/nologin promtail
      ok "Created user: promtail"
    fi
    usermod -aG litellm promtail 2>/dev/null || true
    step_done "promtail_user"
  fi

  if ! step_complete "promtail_binary"; then
    log "Downloading Promtail ${LOKI_VERSION}..."
    cd /tmp
    wget -q "https://github.com/grafana/loki/releases/download/v${LOKI_VERSION}/promtail-linux-amd64.zip" \
      -O promtail-linux-amd64.zip
    unzip -q -o promtail-linux-amd64.zip
    cp promtail-linux-amd64 /usr/local/bin/promtail
    chmod 755 /usr/local/bin/promtail
    rm -f promtail-linux-amd64.zip promtail-linux-amd64
    step_done "promtail_binary"
    ok "Promtail binary installed"
  else
    skip "promtail binary"
  fi

  if ! step_complete "promtail_dirs"; then
    mkdir -p "${PROMTAIL_LIB}" "${PROMTAIL_DIR}"
    chown promtail:promtail "${PROMTAIL_LIB}" "${PROMTAIL_DIR}"
    step_done "promtail_dirs"
    ok "Promtail directories created"
  else
    skip "promtail directories"
  fi

  if ! step_complete "promtail_config"; then
    log "Writing Promtail config..."
    cat > "${PROMTAIL_DIR}/config.yml" << EOF
server:
  http_listen_port: 9080
  grpc_listen_port: 0

positions:
  filename: ${PROMTAIL_LIB}/positions.yaml

clients:
  - url: http://${MONITORING_VM_IP}:3100/loki/api/v1/push

scrape_configs:

  # LiteLLM structured JSON logs
  - job_name: litellm-app
    static_configs:
      - targets:
          - localhost
        labels:
          job: litellm
          host: router-vm
          __path__: ${LITELLM_LOG_DIR}/*.log

  # LiteLLM systemd journal — startup, crashes, restarts
  - job_name: litellm-journal
    journal:
      labels:
        job: litellm-journal
        host: router-vm
      matches: _SYSTEMD_UNIT=litellm.service
    relabel_configs:
      - source_labels: ['__journal__systemd_unit']
        target_label: unit
      - source_labels: ['__journal_priority_keyword']
        target_label: level

  # node_exporter journal
  - job_name: node-exporter-journal
    journal:
      labels:
        job: node-exporter-journal
        host: router-vm
      matches: _SYSTEMD_UNIT=node_exporter.service
    relabel_configs:
      - source_labels: ['__journal__systemd_unit']
        target_label: unit
EOF
    chown promtail:promtail "${PROMTAIL_DIR}/config.yml"
    step_done "promtail_config"
    ok "Promtail config written"
  else
    skip "promtail config"
  fi

  if ! step_complete "promtail_service"; then
    log "Installing Promtail systemd service..."
    cat > /etc/systemd/system/promtail.service << EOF
[Unit]
Description=Promtail Log Shipping Agent
Documentation=https://grafana.com/docs/loki/latest/clients/promtail/
After=network-online.target litellm.service
Wants=network-online.target

[Service]
Type=simple
User=promtail
Group=promtail
ExecStart=/usr/local/bin/promtail --config.file=${PROMTAIL_DIR}/config.yml
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable promtail > /dev/null
    systemctl start promtail
    step_done "promtail_service"
    ok "Promtail service started"
  else
    skip "promtail service"
    systemctl is-active promtail > /dev/null || systemctl start promtail
  fi
}

# ------------------------------------------------------------------------------
# Phase 9 — Health checks
# ------------------------------------------------------------------------------
run_health_checks() {
  phase "Health checks"

  log "Waiting for services to settle (15s)..."
  sleep 15

  local all_ok=true

  check_service() {
    local name="$1"
    if systemctl is-active "$name" > /dev/null 2>&1; then
      ok "Service running: $name"
    else
      warn "Service NOT running: $name"
      journalctl -u "$name" -n 5 --no-pager 2>/dev/null | sed 's/^/     /'
      all_ok=false
    fi
  }

  check_http() {
    local name="$1"
    local url="$2"
    if curl -sf --max-time 8 "$url" > /dev/null 2>&1; then
      ok "HTTP OK: $name"
    else
      warn "HTTP FAIL: $name ($url)"
      all_ok=false
    fi
  }

  echo ""
  log "Checking services..."
  check_service litellm
  check_service node_exporter
  check_service promtail

  echo ""
  log "Checking HTTP endpoints..."
  check_http "LiteLLM health"  "http://localhost:4000/health"
  check_http "LiteLLM metrics" "http://localhost:4000/metrics/"
  check_http "node_exporter"   "http://localhost:9100/metrics"
  check_http "Ollama"          "http://${OLLAMA_HOST}:${OLLAMA_PORT}/v1/models"

  echo ""
  log "Routing test — 'fast' tier (local Ollama)..."
  log "(May take 30-60s if model is still loading)"
  TEST_RESPONSE=$(curl -sf --max-time 60 \
    -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
    -H "Content-Type: application/json" \
    -d '{"model":"fast","messages":[{"role":"user","content":"Reply with one word: working"}]}' \
    "http://localhost:4000/v1/chat/completions" 2>/dev/null || echo "FAIL")

  if echo "$TEST_RESPONSE" | grep -q "choices"; then
    ok "Routing test passed — local model responded"
  else
    warn "Routing test failed or timed out"
    warn "Check logs: sudo tail -50 ${LITELLM_LOG_DIR}/litellm.log"
  fi

  echo ""
  if $all_ok; then
    ok "All health checks passed"
  else
    warn "Some checks failed — see above"
    warn "Full log: sudo journalctl -u litellm -n 50 --no-pager"
  fi
}

# ------------------------------------------------------------------------------
# Phase 10 — Monitoring VM wiring instructions
# ------------------------------------------------------------------------------
print_monitoring_instructions() {
  phase "Monitoring VM — wiring instructions"

  local local_ip
  local_ip=$(get_local_ip)

  echo ""
  echo "  ┌─────────────────────────────────────────────────────────┐"
  echo "  │  Steps to complete on monitoring VM (${MONITORING_VM_IP}):│"
  echo "  └─────────────────────────────────────────────────────────┘"
  echo ""
  echo "  If you used install-monitoring-vm.sh v2 with this VM's IP,"
  echo "  scrape job templates are already in prometheus.yml — update"
  echo "  YOUR_LITELLM_MASTER_KEY and reload."
  echo ""
  echo "  Otherwise paste the following into prometheus.yml:"
  echo ""
  echo "  ── Why metrics_path needs a trailing slash ───────────────"
  echo "  LiteLLM issues a 307 redirect on /metrics (no slash) to"
  echo "  http://localhost:4000/metrics/ — Prometheus follows this"
  echo "  but 'localhost' is the monitoring VM, causing a timeout."
  echo "  Trailing slash + follow_redirects: false prevents this."
  echo ""
  echo "  Use 'authorization: credentials:' NOT 'bearer_token:' —"
  echo "  bearer_token caused silent auth failures in testing."
  echo ""

  cat << EOF
  ── Add to /etc/prometheus/prometheus.yml ─────────────────

  - job_name: 'litellm'
    scrape_interval: 15s
    metrics_path: '/metrics/'
    follow_redirects: false
    authorization:
      credentials: '${LITELLM_MASTER_KEY}'
    static_configs:
      - targets: ['${local_ip}:4000']
        labels:
          host: 'router-vm'

  - job_name: 'node-router-vm'
    static_configs:
      - targets: ['${local_ip}:9100']
        labels:
          host: 'router-vm'

  ── Validate and reload (no restart needed) ────────────────

  sudo /usr/local/bin/promtool check config /etc/prometheus/prometheus.yml
  curl -X POST http://localhost:9090/-/reload

  ── Verify ────────────────────────────────────────────────

  http://${MONITORING_VM_IP}:9090/targets
  (both litellm and node-router-vm should show health: up)

EOF
}

# ------------------------------------------------------------------------------
# Phase 11 — Summary
# ------------------------------------------------------------------------------
print_summary() {
  local local_ip
  local_ip=$(get_local_ip)

  phase "Installation complete"

  cat << EOF

  ┌─────────────────────────────────────────────────────────┐
  │          LLM Router VM — Service Summary  v2            │
  ├─────────────────────────────────────────────────────────┤
  │                                                         │
  │  LiteLLM proxy   http://${local_ip}:4000               │
  │  Master key:     ${LITELLM_MASTER_KEY:0:20}...          │
  │                                                         │
  │  Ollama server   http://${OLLAMA_HOST}:${OLLAMA_PORT}   │
  │  Model:          ${OLLAMA_MODEL}                        │
  │                                                         │
  ├─────────────────────────────────────────────────────────┤
  │  Virtual model tiers (use these in Hermes/clients):     │
  │                                                         │
  │    fast      local Ollama — zero cost, lowest latency   │
  │    default   local Ollama — cloud fallback on failure   │
  │    agentic   cloud-first — best tool call support       │
  │    coding    cloud — reasoning/code optimised           │
  │                                                         │
  ├─────────────────────────────────────────────────────────┤
  │  Point Hermes at the router:                            │
  │                                                         │
  │    hermes model                                         │
  │    > Provider: openai-compatible                        │
  │    > Base URL: http://${local_ip}:4000                  │
  │    > API Key:  ${LITELLM_MASTER_KEY:0:20}...            │
  │    > Model:    default                                  │
  │                                                         │
  ├─────────────────────────────────────────────────────────┤
  │  Useful commands:                                       │
  │                                                         │
  │  Live log:    sudo tail -f ${LITELLM_LOG_DIR}/litellm.log
  │  Journal:     sudo journalctl -u litellm -f             │
  │  Restart:     sudo systemctl restart litellm            │
  │  Edit config: sudo nano ${LITELLM_CONFIG}               │
  │                                                         │
  │  Update free models (check availability first):         │
  │    https://openrouter.ai/models?q=:free                 │
  │    Edit config.yaml then: systemctl restart litellm     │
  │                                                         │
  │  Step tracking: ${STEP_DIR}/                            │
  │  Re-run anytime — completed steps are skipped.          │
  └─────────────────────────────────────────────────────────┘

EOF
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------
main() {
  echo ""
  echo "  ╔══════════════════════════════════════════════════════╗"
  echo "  ║      LLM Router VM Installation Script  v2          ║"
  echo "  ║      LiteLLM + node_exporter + Promtail             ║"
  echo "  ╚══════════════════════════════════════════════════════╝"
  echo ""

  preflight
  install_baseline
  configure_firewall
  setup_litellm_dirs
  install_litellm
  write_litellm_config
  install_litellm_service
  install_node_exporter
  install_promtail
  run_health_checks
  print_monitoring_instructions
  print_summary
}

main "$@"
