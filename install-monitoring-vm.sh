#!/usr/bin/env bash
# ==============================================================================
# install-monitoring-vm.sh  v2
# Central Monitoring VM — Prometheus + Loki + Grafana + nginx
#
# Usage:
#   sudo bash install-monitoring-vm.sh
#
# Re-runnable: completed steps are tracked in /var/lib/monitoring-install/
# and skipped on subsequent runs, so you can safely re-run after a failure.
#
# After completion:
#   - Grafana:    http://THIS_VM  (login: admin / admin — change immediately)
#   - Prometheus: http://THIS_VM:9090
#   - Loki:       http://THIS_VM:3100  (agent push endpoint)
#
# Changes from v1 (all learned from production troubleshooting):
#   - SNMP (161/udp) added to firewall for LibreNMS compatibility
#   - Router VM Loki push firewall rule added during install (was missing)
#   - Prometheus LiteLLM scrape job uses metrics_path '/metrics/' with
#     trailing slash and follow_redirects: false — LiteLLM issues a 307
#     on /metrics redirecting to localhost, which Prometheus cannot reach
#   - Prometheus uses 'authorization: credentials:' format instead of
#     bearer_token: which caused silent auth failures
#   - Prometheus config validated with promtool before starting service
#   - All scrape job YAML uses consistent 2-space indentation (bad indentation
#     caused "did not find expected key" parse errors)
#   - Loki health check waits up to 60s for ingester ready state
#   - Loki pipeline verified with query_range (not instant query — instant
#     query returns empty due to short default time window)
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Version pins — update these when newer stable releases are available
# ------------------------------------------------------------------------------
PROM_VERSION="2.53.4"
NODE_EXPORTER_VERSION="1.8.2"
LOKI_VERSION="3.5.1"

# Retention period for both Prometheus and Loki
RETENTION="30d"

# Step tracking directory (makes script resumable after failures)
STEP_DIR="/var/lib/monitoring-install"

# Router VM IP — populated during preflight, used for firewall + scrape config
ROUTER_VM_IP=""

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

require_ubuntu_24() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck source=/dev/null
    source /etc/os-release
    [[ "$ID" == "ubuntu" ]] || err "This script targets Ubuntu. Detected: $ID"
    [[ "$VERSION_ID" == "24.04" ]] \
      || warn "Designed for Ubuntu 24.04 — detected $VERSION_ID. Proceeding anyway."
  else
    warn "Cannot detect OS — proceeding anyway."
  fi
}

get_local_ip() {
  hostname -I | awk '{print $1}'
}

valid_ip() {
  [[ "$1" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]
}

# ------------------------------------------------------------------------------
# Preflight
# ------------------------------------------------------------------------------
preflight() {
  phase "Preflight checks"

  require_root
  require_ubuntu_24

  mkdir -p "$STEP_DIR"

  LOCAL_IP=$(get_local_ip)
  log "Detected IP: ${LOCAL_IP}"
  log "Prometheus version : ${PROM_VERSION}"
  log "Node exporter      : ${NODE_EXPORTER_VERSION}"
  log "Loki/Promtail      : ${LOKI_VERSION}"
  log "Retention period   : ${RETENTION}"
  echo ""

  echo "  ── Router VM (optional) ──────────────────────────────"
  echo "  Enter your LLM router VM IP to pre-configure:"
  echo "    - Firewall rule allowing it to push logs to Loki"
  echo "    - Prometheus scrape jobs for LiteLLM + node_exporter"
  echo "  Press Enter to skip (add manually later)."
  read -rp "  Router VM IP [skip]: " ROUTER_VM_IP
  if [[ -n "$ROUTER_VM_IP" ]] && ! valid_ip "$ROUTER_VM_IP"; then
    warn "Invalid IP format — skipping router VM pre-configuration"
    ROUTER_VM_IP=""
  fi

  echo ""
  read -rp "  Proceed with installation? [Y/n]: " confirm
  [[ "${confirm,,}" != "n" ]] || { echo "Aborted."; exit 0; }

  ok "Preflight passed"
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
    apt-transport-https \
    software-properties-common \
    wget curl unzip \
    nginx \
    python3 \
    ufw \
    adduser

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
  ufw allow 80/tcp           > /dev/null   # nginx → Grafana
  ufw allow 3000/tcp         > /dev/null   # Grafana direct
  ufw allow 9090/tcp         > /dev/null   # Prometheus
  ufw allow 3100/tcp         > /dev/null   # Loki (all agents push here)
  ufw allow 9080/tcp         > /dev/null   # Promtail metrics
  ufw allow 9100/tcp         > /dev/null   # node_exporter scrape
  ufw allow 161/udp          > /dev/null   # SNMP (LibreNMS)

  # Targeted rule for router VM Loki push — belt-and-suspenders alongside
  # the broad 3100 rule above, in case the broad rule is later tightened
  if [[ -n "$ROUTER_VM_IP" ]]; then
    ufw allow from "${ROUTER_VM_IP}" to any port 3100 > /dev/null
    ok "Added Loki push rule for router VM: ${ROUTER_VM_IP}"
  fi

  ufw --force enable > /dev/null

  ok "Firewall configured:"
  echo ""
  ufw status | sed 's/^/     /'
  echo ""

  step_done "firewall"
}

# ------------------------------------------------------------------------------
# Phase 3 — Service users
# ------------------------------------------------------------------------------
create_users() {
  phase "Service users"

  if step_complete "users"; then
    skip "service users"
    return
  fi

  for user in prometheus loki promtail; do
    if id "$user" &>/dev/null; then
      log "User $user already exists — skipping"
    else
      useradd --system --no-create-home --shell /usr/sbin/nologin "$user"
      ok "Created user: $user"
    fi
  done

  # Grafana user is created by the grafana package itself
  step_done "users"
}

# ------------------------------------------------------------------------------
# Phase 4 — Prometheus
# ------------------------------------------------------------------------------
install_prometheus() {
  phase "Prometheus ${PROM_VERSION}"

  if ! step_complete "prometheus_binary"; then
    log "Downloading Prometheus ${PROM_VERSION}..."
    cd /tmp
    wget -q "https://github.com/prometheus/prometheus/releases/download/v${PROM_VERSION}/prometheus-${PROM_VERSION}.linux-amd64.tar.gz" \
      -O "prometheus-${PROM_VERSION}.tar.gz"

    log "Extracting..."
    tar xf "prometheus-${PROM_VERSION}.tar.gz"
    cd "prometheus-${PROM_VERSION}.linux-amd64"

    cp prometheus promtool /usr/local/bin/
    chmod 755 /usr/local/bin/prometheus /usr/local/bin/promtool

    mkdir -p /etc/prometheus /var/lib/prometheus
    cp -r consoles console_libraries /etc/prometheus/
    chown -R prometheus:prometheus /etc/prometheus /var/lib/prometheus

    cd /tmp
    rm -rf "prometheus-${PROM_VERSION}.linux-amd64" "prometheus-${PROM_VERSION}.tar.gz"

    step_done "prometheus_binary"
    ok "Prometheus binary installed"
  else
    skip "prometheus binary"
  fi

  if ! step_complete "prometheus_config"; then
    log "Writing Prometheus config..."

    # Build the router VM scrape block conditionally.
    #
    # IMPORTANT LESSONS FROM PRODUCTION:
    # 1. metrics_path must be '/metrics/' WITH trailing slash.
    #    LiteLLM returns a 307 redirect on /metrics (no slash) pointing to
    #    http://localhost:4000/metrics/ — Prometheus follows this redirect
    #    but 'localhost' resolves to the monitoring VM, not the router VM,
    #    causing a connection timeout. The trailing slash avoids the redirect.
    #
    # 2. follow_redirects: false is a safety net. If LiteLLM ever changes
    #    its redirect behaviour, this prevents Prometheus chasing a redirect
    #    to a host it can't reach.
    #
    # 3. Use 'authorization: credentials:' NOT 'bearer_token:'.
    #    The bearer_token field caused silent auth failures in testing.
    #    Both send the same Authorization: Bearer header but the credentials
    #    format is more reliably handled by the Prometheus scrape engine.
    #
    # 4. YAML indentation must be exactly 2 spaces for all scrape job entries.
    #    Prometheus YAML parser is strict — 1 space causes "did not find
    #    expected key" errors that crash the service on startup.

    if [[ -n "$ROUTER_VM_IP" ]]; then
      ROUTER_BLOCK="
  # ── LiteLLM router ───────────────────────────────────────────────────────────
  # UPDATE: Replace YOUR_LITELLM_MASTER_KEY with your actual key
  - job_name: 'litellm'
    scrape_interval: 15s
    metrics_path: '/metrics/'
    follow_redirects: false
    authorization:
      credentials: 'YOUR_LITELLM_MASTER_KEY'
    static_configs:
      - targets: ['${ROUTER_VM_IP}:4000']
        labels:
          host: 'router-vm'

  - job_name: 'node-router-vm'
    static_configs:
      - targets: ['${ROUTER_VM_IP}:9100']
        labels:
          host: 'router-vm'
  # ─────────────────────────────────────────────────────────────────────────────"
    else
      ROUTER_BLOCK="
  # ── LiteLLM router (add when ready) ─────────────────────────────────────────
  # See header comments above for why metrics_path has a trailing slash
  # and why follow_redirects: false is required.
  #
  # - job_name: 'litellm'
  #   scrape_interval: 15s
  #   metrics_path: '/metrics/'
  #   follow_redirects: false
  #   authorization:
  #     credentials: 'YOUR_LITELLM_MASTER_KEY'
  #   static_configs:
  #     - targets: ['ROUTER_VM_IP:4000']
  #       labels:
  #         host: 'router-vm'
  #
  # - job_name: 'node-router-vm'
  #   static_configs:
  #     - targets: ['ROUTER_VM_IP:9100']
  #       labels:
  #         host: 'router-vm'
  #
  # After editing, reload without restart:
  #   /usr/local/bin/promtool check config /etc/prometheus/prometheus.yml
  #   curl -X POST http://localhost:9090/-/reload
  # ─────────────────────────────────────────────────────────────────────────────"
    fi

    cat > /etc/prometheus/prometheus.yml << EOF
# Prometheus configuration
# Generated by install-monitoring-vm.sh v2
#
# KEY NOTES for adding LiteLLM scrape jobs:
#   - Use metrics_path: '/metrics/'  (trailing slash — avoids 307 redirect)
#   - Use follow_redirects: false    (safety net against redirect to localhost)
#   - Use authorization: credentials: (not bearer_token:)
#   - All job entries must have exactly 2-space indentation
#   - Validate before reload: promtool check config /etc/prometheus/prometheus.yml

global:
  scrape_interval: 15s
  evaluation_interval: 15s

rule_files: []

scrape_configs:

  # Prometheus monitors itself
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']

  # This VM's own host metrics
  - job_name: 'node-monitoring-vm'
    static_configs:
      - targets: ['localhost:9100']
        labels:
          host: 'monitoring-vm'
${ROUTER_BLOCK}

  # ── Add further hosts below ──────────────────────────────────────────────────
  #
  # - job_name: 'node-HOSTNAME'
  #   static_configs:
  #     - targets: ['HOST_IP:9100']
  #       labels:
  #         host: 'HOSTNAME'
  #
  # ─────────────────────────────────────────────────────────────────────────────
EOF
    chown prometheus:prometheus /etc/prometheus/prometheus.yml

    # Always validate before starting — a bad config crashes the service
    log "Validating Prometheus config..."
    if /usr/local/bin/promtool check config /etc/prometheus/prometheus.yml > /dev/null 2>&1; then
      ok "Prometheus config validated"
    else
      /usr/local/bin/promtool check config /etc/prometheus/prometheus.yml
      err "Prometheus config validation failed — see above"
    fi

    step_done "prometheus_config"
    ok "Prometheus config written"
  else
    skip "prometheus config"
  fi

  if ! step_complete "prometheus_service"; then
    log "Installing Prometheus systemd service..."
    cat > /etc/systemd/system/prometheus.service << EOF
[Unit]
Description=Prometheus Metrics Server
Documentation=https://prometheus.io/docs/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=prometheus
Group=prometheus
ExecStart=/usr/local/bin/prometheus \\
    --config.file=/etc/prometheus/prometheus.yml \\
    --storage.tsdb.path=/var/lib/prometheus \\
    --storage.tsdb.retention.time=${RETENTION} \\
    --web.console.templates=/etc/prometheus/consoles \\
    --web.console.libraries=/etc/prometheus/console_libraries \\
    --web.listen-address=0.0.0.0:9090 \\
    --web.enable-lifecycle
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable prometheus > /dev/null
    systemctl start prometheus
    step_done "prometheus_service"
    ok "Prometheus service started"
  else
    skip "prometheus service"
    systemctl is-active prometheus > /dev/null || systemctl start prometheus
  fi
}

# ------------------------------------------------------------------------------
# Phase 5 — node_exporter (this VM's own host metrics)
# ------------------------------------------------------------------------------
install_node_exporter() {
  phase "node_exporter ${NODE_EXPORTER_VERSION}"

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
# Phase 6 — Loki
# ------------------------------------------------------------------------------
install_loki() {
  phase "Loki ${LOKI_VERSION}"

  if ! step_complete "loki_binary"; then
    log "Downloading Loki ${LOKI_VERSION}..."
    cd /tmp
    wget -q "https://github.com/grafana/loki/releases/download/v${LOKI_VERSION}/loki-linux-amd64.zip" \
      -O loki-linux-amd64.zip
    unzip -q -o loki-linux-amd64.zip
    cp loki-linux-amd64 /usr/local/bin/loki
    chmod 755 /usr/local/bin/loki
    rm -f loki-linux-amd64.zip loki-linux-amd64

    step_done "loki_binary"
    ok "Loki binary installed"
  else
    skip "loki binary"
  fi

  if ! step_complete "loki_dirs"; then
    log "Creating Loki storage directories..."
    mkdir -p /var/lib/loki/{chunks,index,cache,wal,compactor}
    mkdir -p /etc/loki
    chown -R loki:loki /var/lib/loki /etc/loki
    step_done "loki_dirs"
    ok "Loki directories created"
  else
    skip "loki directories"
  fi

  if ! step_complete "loki_config"; then
    log "Writing Loki config..."
    cat > /etc/loki/config.yml << EOF
auth_enabled: false

server:
  http_listen_port: 3100
  grpc_listen_port: 9096

common:
  instance_addr: 0.0.0.0
  path_prefix: /var/lib/loki
  replication_factor: 1
  ring:
    kvstore:
      store: inmemory

schema_config:
  configs:
    - from: 2024-01-01
      store: tsdb
      object_store: filesystem
      schema: v13
      index:
        prefix: index_
        period: 24h

storage_config:
  tsdb_shipper:
    active_index_directory: /var/lib/loki/index
    cache_location: /var/lib/loki/cache
  filesystem:
    directory: /var/lib/loki/chunks

ingester:
  wal:
    enabled: true
    dir: /var/lib/loki/wal

compactor:
  working_directory: /var/lib/loki/compactor
  compaction_interval: 10m
  retention_enabled: true
  retention_delete_delay: 2h
  delete_request_store: filesystem

limits_config:
  allow_structured_metadata: false
  retention_period: ${RETENTION}

query_range:
  results_cache:
    cache:
      embedded_cache:
        enabled: true
        max_size_mb: 100
EOF
    chown loki:loki /etc/loki/config.yml
    step_done "loki_config"
    ok "Loki config written"
  else
    skip "loki config"
  fi

  if ! step_complete "loki_service"; then
    log "Installing Loki systemd service..."
    cat > /etc/systemd/system/loki.service << 'EOF'
[Unit]
Description=Grafana Loki Log Aggregation
Documentation=https://grafana.com/docs/loki/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=loki
Group=loki
ExecStart=/usr/local/bin/loki --config.file=/etc/loki/config.yml
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable loki > /dev/null
    systemctl start loki
    step_done "loki_service"
    ok "Loki service started"
  else
    skip "loki service"
    systemctl is-active loki > /dev/null || systemctl start loki
  fi
}

# ------------------------------------------------------------------------------
# Phase 7 — Promtail (ships this VM's own logs to Loki)
# ------------------------------------------------------------------------------
install_promtail() {
  phase "Promtail ${LOKI_VERSION} (local log agent)"

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
    mkdir -p /var/lib/promtail
    chown promtail:promtail /var/lib/promtail
    mkdir -p /etc/promtail
    step_done "promtail_dirs"
    ok "Promtail directories created"
  else
    skip "promtail directories"
  fi

  if ! step_complete "promtail_config"; then
    log "Writing Promtail config..."
    cat > /etc/promtail/config.yml << 'EOF'
server:
  http_listen_port: 9080
  grpc_listen_port: 0

positions:
  filename: /var/lib/promtail/positions.yaml

clients:
  - url: http://localhost:3100/loki/api/v1/push

scrape_configs:

  # Systemd journal — all service events on this VM
  - job_name: system-journal
    journal:
      labels:
        job: system-journal
        host: monitoring-vm
    relabel_configs:
      - source_labels: ['__journal__systemd_unit']
        target_label: unit
      - source_labels: ['__journal_priority_keyword']
        target_label: level
EOF
    chown promtail:promtail /etc/promtail/config.yml
    step_done "promtail_config"
    ok "Promtail config written"
  else
    skip "promtail config"
  fi

  if ! step_complete "promtail_service"; then
    log "Installing Promtail systemd service..."
    cat > /etc/systemd/system/promtail.service << 'EOF'
[Unit]
Description=Promtail Log Shipping Agent
Documentation=https://grafana.com/docs/loki/latest/clients/promtail/
After=network-online.target loki.service
Wants=network-online.target

[Service]
Type=simple
User=promtail
Group=promtail
ExecStart=/usr/local/bin/promtail --config.file=/etc/promtail/config.yml
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
# Phase 8 — Grafana
# ------------------------------------------------------------------------------
install_grafana() {
  phase "Grafana (latest stable)"

  if ! step_complete "grafana_repo"; then
    log "Adding Grafana apt repository..."
    mkdir -p /etc/apt/keyrings
    wget -q -O /etc/apt/keyrings/grafana.asc https://apt.grafana.com/gpg-full.key
    chmod 644 /etc/apt/keyrings/grafana.asc
    echo "deb [signed-by=/etc/apt/keyrings/grafana.asc] https://apt.grafana.com stable main" \
      > /etc/apt/sources.list.d/grafana.list
    apt-get update -qq
    step_done "grafana_repo"
    ok "Grafana repo added"
  else
    skip "grafana repo"
  fi

  if ! step_complete "grafana_install"; then
    log "Installing Grafana..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq grafana
    step_done "grafana_install"
    ok "Grafana installed"
  else
    skip "grafana install"
  fi

  if ! step_complete "grafana_service"; then
    log "Starting Grafana service..."
    systemctl daemon-reload
    systemctl enable grafana-server > /dev/null
    systemctl start grafana-server
    step_done "grafana_service"
    ok "Grafana service started"
  else
    skip "grafana service"
    systemctl is-active grafana-server > /dev/null || systemctl start grafana-server
  fi
}

# ------------------------------------------------------------------------------
# Phase 9 — nginx reverse proxy for Grafana
# ------------------------------------------------------------------------------
configure_nginx() {
  phase "nginx reverse proxy (Grafana on port 80)"

  if ! step_complete "nginx_config"; then
    log "Writing nginx config for Grafana..."
    cat > /etc/nginx/sites-available/grafana << 'EOF'
server {
    listen 80;
    server_name _;

    location / {
        proxy_pass         http://localhost:3000;
        proxy_set_header   Host              $host;
        proxy_set_header   X-Real-IP         $remote_addr;
        proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade           $http_upgrade;
        proxy_set_header   Connection        "upgrade";
    }
}
EOF
    rm -f /etc/nginx/sites-enabled/default
    ln -sf /etc/nginx/sites-available/grafana /etc/nginx/sites-enabled/grafana

    nginx -t 2>/dev/null || err "nginx config test failed"
    systemctl reload nginx

    step_done "nginx_config"
    ok "nginx configured and reloaded"
  else
    skip "nginx config"
  fi
}

# ------------------------------------------------------------------------------
# Phase 10 — Health checks
# ------------------------------------------------------------------------------
run_health_checks() {
  phase "Health checks"

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

  echo ""
  log "Checking services..."
  check_service prometheus
  check_service node_exporter
  check_service loki
  check_service promtail
  check_service grafana-server
  check_service nginx

  echo ""
  log "Checking HTTP endpoints..."
  check_http "Prometheus"    "http://localhost:9090/-/healthy"
  check_http "Grafana"       "http://localhost:3000/api/health"
  check_http "nginx→Grafana" "http://localhost:80"

  # Loki ingester takes ~15s after service start to become ready.
  # Wait up to 60s before marking as failed.
  log "Waiting for Loki ingester (up to 60s)..."
  local loki_ready=false
  for i in {1..12}; do
    LOKI_STATUS=$(curl -sf --max-time 5 http://localhost:3100/ready 2>/dev/null || echo "")
    if [[ "$LOKI_STATUS" == "ready" ]]; then
      loki_ready=true
      break
    fi
    sleep 5
  done

  if $loki_ready; then
    ok "HTTP OK: Loki (ready)"
  else
    warn "Loki ingester not ready after 60s — check: journalctl -u loki -n 30"
    all_ok=false
  fi

  # Verify the full Loki ingest pipeline with a test push + query.
  # Uses query_range with explicit timestamps — the instant /query endpoint
  # uses a very short default time window and returns empty even when data
  # was just ingested. query_range with explicit start/end is reliable.
  if $loki_ready; then
    log "Testing Loki ingest pipeline..."
    TEST_TS=$(date +%s%N)
    curl -sf -X POST http://localhost:3100/loki/api/v1/push \
      -H "Content-Type: application/json" \
      -d "{\"streams\":[{\"stream\":{\"job\":\"install-test\"},\"values\":[[\"${TEST_TS}\",\"install health check\"]]}]}" \
      > /dev/null 2>&1
    sleep 3
    START_TS=$(( (TEST_TS / 1000000000) - 60 ))
    END_TS=$(( (TEST_TS / 1000000000) + 60 ))
    LOKI_RESULT=$(curl -sf -G http://localhost:3100/loki/api/v1/query_range \
      --data-urlencode 'query={job="install-test"}' \
      --data-urlencode "start=${START_TS}000000000" \
      --data-urlencode "end=${END_TS}000000000" \
      --data-urlencode 'limit=1' 2>/dev/null || echo "")
    if echo "$LOKI_RESULT" | grep -q "install health check"; then
      ok "Loki ingest pipeline working"
    else
      warn "Loki test entry not found — pipeline may need more time to settle"
    fi
  fi

  echo ""
  log "Verifying Prometheus config..."
  if /usr/local/bin/promtool check config /etc/prometheus/prometheus.yml > /dev/null 2>&1; then
    ok "Prometheus config valid"
  else
    warn "Prometheus config has errors — run: promtool check config /etc/prometheus/prometheus.yml"
    all_ok=false
  fi

  echo ""
  if $all_ok; then
    ok "All health checks passed"
  else
    warn "Some checks failed — review above. Logs: journalctl -u <service> -n 30"
  fi
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
  │          Monitoring VM — Service Summary  v2            │
  ├─────────────────────────────────────────────────────────┤
  │                                                         │
  │  Grafana UI      http://${local_ip}                     │
  │                  http://${local_ip}:3000                │
  │                  Login: admin / admin  ← CHANGE THIS    │
  │                                                         │
  │  Prometheus      http://${local_ip}:9090                │
  │  Targets         http://${local_ip}:9090/targets        │
  │                                                         │
  │  Loki push URL   http://${local_ip}:3100                │
  │  (use this in Promtail configs on other hosts)          │
  │                                                         │
  ├─────────────────────────────────────────────────────────┤
  │  Next steps:                                            │
  │                                                         │
  │  1. Log into Grafana — change the admin password        │
  │                                                         │
  │  2. Add data sources (Connections → Data Sources):      │
  │     Prometheus: http://localhost:9090                   │
  │     Loki:       http://localhost:3100                   │
  │                                                         │
  │  3. Import dashboards:                                  │
  │     Node Exporter Full — Grafana ID: 1860               │
  │     LiteLLM custom    — litellm-dashboard-fixed.json    │
  │                                                         │
EOF

  if [[ -n "$ROUTER_VM_IP" ]]; then
    cat << EOF
  │  4. Prometheus scrape jobs for ${ROUTER_VM_IP} added.   │
  │     Update YOUR_LITELLM_MASTER_KEY in:                  │
  │       /etc/prometheus/prometheus.yml                    │
  │     Validate + reload:                                  │
  │       promtool check config /etc/prometheus/...yml      │
  │       curl -X POST http://localhost:9090/-/reload       │
  │                                                         │
  │  5. On router VM (${ROUTER_VM_IP}):                     │
  │     Ensure node_exporter running on :9100               │
  │     Ensure Promtail pushing to http://${local_ip}:3100  │
  │     Ensure ufw allows ${local_ip} to reach :9100/:4000  │
  │                                                         │
EOF
  else
    cat << EOF
  │  4. Add router VM scrape jobs to Prometheus:            │
  │     sudo nano /etc/prometheus/prometheus.yml            │
  │     (See file header comments for correct format)       │
  │     Validate + reload after editing:                    │
  │       promtool check config /etc/prometheus/...yml      │
  │       curl -X POST http://localhost:9090/-/reload       │
  │                                                         │
EOF
  fi

  cat << EOF
  │  Troubleshooting:                                       │
  │    journalctl -u prometheus -n 30 --no-pager            │
  │    journalctl -u loki -n 30 --no-pager                  │
  │    journalctl -u grafana-server -n 30 --no-pager        │
  │                                                         │
  │  Step tracking: ${STEP_DIR}/                            │
  │  Re-run this script anytime — completed steps skip.     │
  └─────────────────────────────────────────────────────────┘

EOF
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------
main() {
  echo ""
  echo "  ╔══════════════════════════════════════════════════════╗"
  echo "  ║    Monitoring VM Installation Script  v2            ║"
  echo "  ║    Prometheus + Loki + Grafana + nginx              ║"
  echo "  ╚══════════════════════════════════════════════════════╝"
  echo ""

  preflight
  install_baseline
  configure_firewall
  create_users
  install_prometheus
  install_node_exporter
  install_loki
  install_promtail
  install_grafana
  configure_nginx
  run_health_checks
  print_summary
}

main "$@"
