#!/usr/bin/env bash
# ==============================================================================
# install-router-vm.sh
# LLM Router VM — LiteLLM + Ollama + Monitoring Agents
#
# Installs:
#   - Ollama          local inference server
#   - qwen2.5:14b     local model (tool-call capable, good general use)
#   - LiteLLM proxy   unified routing layer (OpenRouter + Ollama backends)
#   - node_exporter   host metrics → Prometheus on monitoring VM
#   - Promtail        log shipping → Loki on monitoring VM
#
# Usage:
#   sudo bash install-router-vm.sh
#
# The script will prompt for:
#   - OpenRouter API key
#   - LiteLLM master key (you choose this — clients use it to authenticate)
#   - Monitoring VM IP (for node_exporter + Promtail)
#   - Ollama host (defaults to localhost if Ollama is on this VM)
#
# Re-runnable: completed steps tracked in /var/lib/router-install/
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Version pins
# ------------------------------------------------------------------------------
NODE_EXPORTER_VERSION="1.8.2"
LOKI_VERSION="3.5.1"           # Promtail version tracks Loki releases
LITELLM_PACKAGE="litellm[proxy]"

# Default Ollama model — change here if you want a different size
OLLAMA_MODEL="qwen3.5:35b-a3b"

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

# Validate an IP address format
valid_ip() {
  [[ "$1" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]
}

# Validate a LiteLLM master key (must start with sk-)
valid_key() {
  [[ "$1" =~ ^sk-.{8,} ]]
}

# ------------------------------------------------------------------------------
# Preflight — gather config interactively
# ------------------------------------------------------------------------------

# These will be populated during preflight
OPENROUTER_API_KEY=""
LITELLM_MASTER_KEY=""
MONITORING_VM_IP=""
OLLAMA_HOST=""

preflight() {
  phase "Preflight — configuration"

  require_root

  mkdir -p "$STEP_DIR"

  LOCAL_IP=$(get_local_ip)
  echo ""
  echo "  This script will configure the LLM Router VM."
  echo "  Local IP detected: ${LOCAL_IP}"
  echo ""

  # If a saved config exists from a previous run, offer to reuse it
  if [[ -f "${LITELLM_ENV}" ]]; then
    echo "  ┌─────────────────────────────────────────────────────┐"
    echo "  │  Existing config found at ${LITELLM_ENV}  │"
    echo "  └─────────────────────────────────────────────────────┘"
    read -rp "  Reuse existing config and skip to unfinished steps? [Y/n]: " reuse
    if [[ "${reuse,,}" != "n" ]]; then
      # shellcheck source=/dev/null
      source "${LITELLM_ENV}"
      OPENROUTER_API_KEY="${OPENROUTER_API_KEY:-}"
      LITELLM_MASTER_KEY="${LITELLM_MASTER_KEY:-}"
      MONITORING_VM_IP="${MONITORING_VM_IP:-}"
      OLLAMA_HOST="${OLLAMA_HOST:-localhost}"
      ok "Reusing existing config"
      return
    fi
  fi

  echo ""
  echo "  ── OpenRouter ────────────────────────────────────────"
  echo "  Get your key at: https://openrouter.ai/keys"
  while true; do
    read -rsp "  OpenRouter API key (sk-or-...): " OPENROUTER_API_KEY
    echo ""
    [[ -n "$OPENROUTER_API_KEY" ]] && break
    warn "API key cannot be empty"
  done

  echo ""
  echo "  ── LiteLLM Master Key ────────────────────────────────"
  echo "  This is the key your clients (Hermes etc.) use to"
  echo "  authenticate with the router. Must start with sk-"
  while true; do
    read -rsp "  LiteLLM master key (sk-...): " LITELLM_MASTER_KEY
    echo ""
    if valid_key "$LITELLM_MASTER_KEY"; then
      break
    else
      warn "Key must start with 'sk-' and be at least 10 characters"
    fi
  done

  echo ""
  echo "  ── Monitoring VM ─────────────────────────────────────"
  echo "  IP address of your monitoring VM (for node_exporter"
  echo "  and Promtail to send data to)."
  while true; do
    read -rp "  Monitoring VM IP: " MONITORING_VM_IP
    if valid_ip "$MONITORING_VM_IP"; then
      break
    else
      warn "Please enter a valid IP address (e.g. 192.168.1.50)"
    fi
  done

  echo ""
  echo "  ── Ollama Host ───────────────────────────────────────"
  echo "  Where is Ollama running?"
  echo "  Press Enter for localhost (Ollama on this VM),"
  echo "  or enter an IP if Ollama is on a separate machine."
  read -rp "  Ollama host [localhost]: " OLLAMA_HOST
  OLLAMA_HOST="${OLLAMA_HOST:-localhost}"

  echo ""
  echo "  ── Summary ───────────────────────────────────────────"
  echo "  OpenRouter key : ${OPENROUTER_API_KEY:0:12}..."
  echo "  LiteLLM key    : ${LITELLM_MASTER_KEY:0:12}..."
  echo "  Monitoring VM  : ${MONITORING_VM_IP}"
  echo "  Ollama host    : ${OLLAMA_HOST}"
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
    ufw \
    git

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
  ufw allow 4000/tcp         > /dev/null   # LiteLLM proxy
  ufw allow 11834/tcp        > /dev/null   # Ollama API
  ufw allow 9100/tcp         > /dev/null   # node_exporter (monitoring VM scrapes)
  ufw allow 9080/tcp         > /dev/null   # Promtail

  ufw --force enable         > /dev/null

  ok "Firewall configured:"
  echo ""
  ufw status | sed 's/^/     /'
  echo ""

  step_done "firewall"
}

# ------------------------------------------------------------------------------
# Phase 3 — Ollama
# ------------------------------------------------------------------------------
install_ollama() {
  phase "Ollama"

  if ! step_complete "ollama_install"; then
    # Only install if Ollama is running locally
    if [[ "$OLLAMA_HOST" != "localhost" && "$OLLAMA_HOST" != "127.0.0.1" ]]; then
      log "Ollama is on a remote host (${OLLAMA_HOST}) — skipping local install"
      step_done "ollama_install"
      return
    fi

    if command -v ollama &>/dev/null; then
      log "Ollama already installed — skipping download"
    else
      log "Downloading and installing Ollama..."
      curl -fsSL https://ollama.com/install.sh | sh
    fi

    log "Enabling Ollama service..."
    systemctl enable ollama > /dev/null
    systemctl start ollama
    sleep 3   # give it a moment to initialise

    step_done "ollama_install"
    ok "Ollama installed and started"
  else
    skip "ollama install"
    if [[ "$OLLAMA_HOST" == "localhost" || "$OLLAMA_HOST" == "127.0.0.1" ]]; then
      systemctl is-active ollama > /dev/null || systemctl start ollama
    fi
  fi

  if ! step_complete "ollama_model"; then
    if [[ "$OLLAMA_HOST" != "localhost" && "$OLLAMA_HOST" != "127.0.0.1" ]]; then
      log "Remote Ollama — skipping model pull (pull ${OLLAMA_MODEL} on the remote host)"
      step_done "ollama_model"
      return
    fi

    log "Pulling model: ${OLLAMA_MODEL}"
    log "(This may take a while depending on your connection — ~9GB for 14b)"
    ollama pull "${OLLAMA_MODEL}"

    step_done "ollama_model"
    ok "Model pulled: ${OLLAMA_MODEL}"
  else
    skip "ollama model pull"
  fi
}

# ------------------------------------------------------------------------------
# Phase 4 — LiteLLM service user and directories
# ------------------------------------------------------------------------------
setup_litellm_dirs() {
  phase "LiteLLM directories and user"

  if step_complete "litellm_dirs"; then
    skip "LiteLLM directories"
    return
  fi

  # Service user
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

  step_done "litellm_dirs"
  ok "Directories created"
}

# ------------------------------------------------------------------------------
# Phase 5 — LiteLLM Python install
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
    step_done "litellm_pip"
    ok "LiteLLM installed"
  else
    skip "litellm pip install"
  fi

  # Print installed version
  LITELLM_VERSION=$("${LITELLM_HOME}/venv/bin/litellm" --version 2>/dev/null || echo "unknown")
  log "LiteLLM version: ${LITELLM_VERSION}"
}

# ------------------------------------------------------------------------------
# Phase 6 — Write config files
# ------------------------------------------------------------------------------
write_litellm_config() {
  phase "LiteLLM configuration"

  if ! step_complete "litellm_env"; then
    log "Writing secrets file: ${LITELLM_ENV}"
    cat > "${LITELLM_ENV}" << EOF
OPENROUTER_API_KEY=${OPENROUTER_API_KEY}
LITELLM_MASTER_KEY=${LITELLM_MASTER_KEY}
OLLAMA_API_BASE=http://${OLLAMA_HOST}:11834
MONITORING_VM_IP=${MONITORING_VM_IP}
OLLAMA_HOST=${OLLAMA_HOST}
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
# LiteLLM Router Config
# Generated by install-router-vm.sh
#
# To add models: edit model_list, then:
#   sudo systemctl restart litellm
#
# To add a scrape target to Prometheus on the monitoring VM:
#   Edit /etc/prometheus/prometheus.yml on ${MONITORING_VM_IP}
#   Add the litellm job, then: curl -X POST http://${MONITORING_VM_IP}:9090/-/reload
# ==============================================================================

model_list:

  # ── Local Ollama models ──────────────────────────────────────────────────────
  # Using ollama_chat/ prefix for correct tool-call handling

  - model_name: "local/${OLLAMA_MODEL}"
    litellm_params:
      model: "ollama_chat/${OLLAMA_MODEL}"
      api_base: "http://${OLLAMA_HOST}:11834"
      stream: true

  # ── OpenRouter free models ───────────────────────────────────────────────────
  # All models use the :free suffix or the openrouter/free magic router.
  # Free tier has rate limits (~10-20 req/min per model) — the magic router
  # spreads load automatically. Check https://openrouter.ai/models?q=:free
  # for the current free model list.

  # Magic router — OpenRouter picks the best available free model for each
  # request, filtering for required features (tool calls, vision, etc.)
  - model_name: "cloud/free"
    litellm_params:
      model: "openrouter/openrouter/free"
      api_key: "os.environ/OPENROUTER_API_KEY"
      api_base: "https://openrouter.ai/api/v1"
      stream: true

  # DeepSeek R1 free — strong reasoning, good tool call support
  - model_name: "cloud/deepseek-r1-free"
    litellm_params:
      model: "openrouter/deepseek/deepseek-r1:free"
      api_key: "os.environ/OPENROUTER_API_KEY"
      api_base: "https://openrouter.ai/api/v1"
      stream: true

  # Gemini 2.5 Flash free — fast, large context, good general use
  - model_name: "cloud/gemini-flash-free"
    litellm_params:
      model: "openrouter/google/gemini-2.5-flash:free"
      api_key: "os.environ/OPENROUTER_API_KEY"
      api_base: "https://openrouter.ai/api/v1"
      stream: true

  # Llama 4 Maverick free — strong tool call support, good for agentic work
  - model_name: "cloud/llama4-free"
    litellm_params:
      model: "openrouter/meta-llama/llama-4-maverick:free"
      api_key: "os.environ/OPENROUTER_API_KEY"
      api_base: "https://openrouter.ai/api/v1"
      stream: true

  # ── Virtual model tiers ──────────────────────────────────────────────────────
  # These are what clients (Hermes etc.) reference by name.
  # Backends resolve via fallback chains below.

  # default: local-first, free cloud fallback
  - model_name: "default"
    litellm_params:
      model: "local/${OLLAMA_MODEL}"

  # agentic: DeepSeek R1 for reasoning + tool calls, magic router as safety net
  - model_name: "agentic"
    litellm_params:
      model: "cloud/deepseek-r1-free"

  # fast: local only for zero latency / zero cost simple tasks
  - model_name: "fast"
    litellm_params:
      model: "local/${OLLAMA_MODEL}"

  # coding: DeepSeek R1 free (strong reasoning), falls back to Llama 4
  - model_name: "coding"
    litellm_params:
      model: "cloud/deepseek-r1-free"


# ── Router settings ────────────────────────────────────────────────────────────
router_settings:
  routing_strategy: "latency-based-routing"
  num_retries: 2
  timeout: 120
  allowed_fails: 3


# ── LiteLLM settings ──────────────────────────────────────────────────────────
litellm_settings:

  # Fallback chains — what to try when primary fails
  fallbacks:
    - "default":  ["cloud/gemini-flash-free", "cloud/free"]
    - "agentic":  ["cloud/llama4-free", "cloud/free"]
    - "fast":     ["cloud/gemini-flash-free", "cloud/free"]
    - "coding":   ["cloud/llama4-free", "cloud/free"]

  context_window_fallbacks:
    - "local/${OLLAMA_MODEL}": ["cloud/gemini-flash-free", "cloud/free"]

  # Prometheus metrics (monitoring VM will scrape /metrics)
  callbacks: ["prometheus"]
  failure_callback: ["prometheus"]
  service_callback: ["prometheus_system"]

  # Structured JSON logs (Promtail ships these to Loki)
  json_logs: true

  # Secure the /metrics endpoint
  require_auth_for_metrics_endpoint: true

  # Pass unknown params through — important for Hermes tool calls
  drop_params: false

  # Set to true temporarily to debug routing decisions
  set_verbose: false


# ── General / server settings ──────────────────────────────────────────────────
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
# Phase 7 — LiteLLM systemd service
# ------------------------------------------------------------------------------
install_litellm_service() {
  phase "LiteLLM systemd service"

  if ! step_complete "litellm_service"; then
    log "Writing systemd unit..."
    cat > /etc/systemd/system/litellm.service << EOF
[Unit]
Description=LiteLLM LLM Router Proxy
Documentation=https://docs.litellm.ai
After=network-online.target ollama.service
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

# Log to file so Promtail can ship to Loki
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
# Phase 8 — node_exporter (host metrics → monitoring VM)
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
# Phase 9 — Promtail (log shipping → monitoring VM Loki)
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
    # Allow promtail to read litellm log files
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

  # Systemd journal — catches startup/crash events
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

  # Ollama journal
  - job_name: ollama-journal
    journal:
      labels:
        job: ollama-journal
        host: router-vm
      matches: _SYSTEMD_UNIT=ollama.service
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
# Phase 10 — Health checks
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
    if curl -sf --max-time 5 "$url" > /dev/null 2>&1; then
      ok "HTTP OK: $name"
    else
      warn "HTTP FAIL: $name ($url)"
      all_ok=false
    fi
  }

  check_http_auth() {
    local name="$1"
    local url="$2"
    local key="$3"
    if curl -sf --max-time 5 -H "Authorization: Bearer ${key}" "$url" > /dev/null 2>&1; then
      ok "HTTP OK (auth): $name"
    else
      warn "HTTP FAIL (auth): $name ($url)"
      all_ok=false
    fi
  }

  echo ""
  log "Checking services..."
  check_service litellm
  check_service node_exporter
  check_service promtail
  if [[ "$OLLAMA_HOST" == "localhost" || "$OLLAMA_HOST" == "127.0.0.1" ]]; then
    check_service ollama
  fi

  echo ""
  log "Checking HTTP endpoints..."
  check_http      "LiteLLM health"    "http://localhost:4000/health"
  check_http      "Ollama"            "http://${OLLAMA_HOST}:11834"
  check_http      "node_exporter"     "http://localhost:9100/metrics"
  check_http_auth "LiteLLM /metrics"  "http://localhost:4000/metrics" "${LITELLM_MASTER_KEY}"

  echo ""
  log "Quick routing test (local model)..."
  TEST_RESPONSE=$(curl -sf --max-time 30 \
    -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
    -H "Content-Type: application/json" \
    -d '{"model":"fast","messages":[{"role":"user","content":"Reply with one word: working"}]}' \
    "http://localhost:4000/v1/chat/completions" 2>/dev/null || echo "FAIL")

  if echo "$TEST_RESPONSE" | grep -q "choices"; then
    ok "Routing test passed — local model responded"
  else
    warn "Routing test failed or timed out (model may still be loading)"
    warn "Re-run after a minute: curl -s http://localhost:4000/health"
  fi

  echo ""
  if $all_ok; then
    ok "All health checks passed"
  else
    warn "Some checks failed — see above. Check logs with:"
    warn "  sudo journalctl -u litellm -n 50 --no-pager"
  fi
}

# ------------------------------------------------------------------------------
# Phase 11 — Print monitoring VM instructions
# ------------------------------------------------------------------------------
print_monitoring_instructions() {
  phase "Monitoring VM — next steps"

  echo ""
  echo "  The router VM is ready. Now wire it into your monitoring VM."
  echo ""
  echo "  ┌─────────────────────────────────────────────────────────┐"
  echo "  │  On the monitoring VM (${MONITORING_VM_IP}):            │"
  echo "  └─────────────────────────────────────────────────────────┘"
  echo ""
  echo "  1. Open firewall for node_exporter scraping:"
  echo ""
  echo "     sudo ufw allow from $(get_local_ip) to any port 9100"
  echo "     sudo ufw allow from $(get_local_ip) to any port 9080"
  echo ""
  echo "  2. Add LiteLLM scrape job to Prometheus:"
  echo "     sudo nano /etc/prometheus/prometheus.yml"
  echo ""
  echo "     Add under scrape_configs:"
  echo ""
  cat << EOF
     - job_name: 'node-router-vm'
       static_configs:
         - targets: ['$(get_local_ip):9100']
           labels:
             host: 'router-vm'

     - job_name: 'litellm'
       scrape_interval: 15s
       metrics_path: '/metrics'
       bearer_token: '${LITELLM_MASTER_KEY}'
       static_configs:
         - targets: ['$(get_local_ip):4000']
           labels:
             host: 'router-vm'
EOF
  echo ""
  echo "  3. Reload Prometheus (no restart needed):"
  echo ""
  echo "     curl -X POST http://localhost:9090/-/reload"
  echo ""
  echo "  4. Verify targets are UP:"
  echo "     http://${MONITORING_VM_IP}:9090/targets"
  echo ""
}

# ------------------------------------------------------------------------------
# Phase 12 — Summary
# ------------------------------------------------------------------------------
print_summary() {
  local local_ip
  local_ip=$(get_local_ip)

  phase "Installation complete"

  cat << EOF

  ┌─────────────────────────────────────────────────────────┐
  │              LLM Router VM — Service Summary            │
  ├─────────────────────────────────────────────────────────┤
  │                                                         │
  │  LiteLLM proxy   http://${local_ip}:4000               │
  │  Auth header:    Authorization: Bearer ${LITELLM_MASTER_KEY:0:16}...  │
  │                                                         │
  │  Ollama API      http://${OLLAMA_HOST}:11834            │
  │  Loaded model:   ${OLLAMA_MODEL}                        │
  │                                                         │
  ├──────────────────────────────────────────────────────── │
  │  Virtual model names (use these in Hermes):             │
  │                                                         │
  │    default   local-first, cloud fallback                │
  │    agentic   cloud-first (best tool call support)       │
  │    fast      local only, cheapest                       │
  │    coding    cloud (Claude Sonnet via OpenRouter)       │
  │                                                         │
  ├─────────────────────────────────────────────────────────┤
  │  Point Hermes at the router:                            │
  │                                                         │
  │    hermes model                                         │
  │    > Provider: openai-compatible                        │
  │    > Base URL: http://${local_ip}:4000                  │
  │    > API Key:  ${LITELLM_MASTER_KEY:0:20}...            │
  │    > Model:    default  (or agentic for tool sessions)  │
  │                                                         │
  ├─────────────────────────────────────────────────────────┤
  │  Useful commands:                                       │
  │                                                         │
  │  Watch logs:    sudo journalctl -u litellm -f           │
  │  Restart:       sudo systemctl restart litellm          │
  │  Edit config:   sudo nano ${LITELLM_CONFIG}             │
  │  List models:   ollama list                             │
  │  Pull model:    ollama pull <model>                     │
  │                                                         │
  │  Step tracking: ${STEP_DIR}/                            │
  │  Re-run script anytime — completed steps are skipped.   │
  └─────────────────────────────────────────────────────────┘

EOF
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------
main() {
  echo ""
  echo "  ╔══════════════════════════════════════════════════════╗"
  echo "  ║         LLM Router VM Installation Script           ║"
  echo "  ║   LiteLLM + Ollama + OpenRouter + Monitoring        ║"
  echo "  ╚══════════════════════════════════════════════════════╝"
  echo ""

  preflight
  install_baseline
  configure_firewall
  install_ollama
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
