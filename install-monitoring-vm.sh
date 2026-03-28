#!/usr/bin/env bash
# ==============================================================================
# install-monitoring-vm.sh
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
  ufw allow 3000/tcp         > /dev/null   # Grafana (proxied via nginx on 80 too)
  ufw allow 80/tcp           > /dev/null   # nginx → Grafana
  ufw allow 9090/tcp         > /dev/null   # Prometheus
  ufw allow 3100/tcp         > /dev/null   # Loki (Promtail agents push here)
  ufw allow 9080/tcp         > /dev/null   # Promtail (this VM's own agent)

  ufw --force enable         > /dev/null

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

  # Grafana's user is created by the grafana package
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
    cat > /etc/prometheus/prometheus.yml << 'EOF'
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

  # ── Add new hosts below this line ──────────────────────────────
  #
  # Template for any host running node_exporter:
  #
  # - job_name: 'node-HOSTNAME'
  #   static_configs:
  #     - targets: ['HOST_IP:9100']
  #       labels:
  #         host: 'HOSTNAME'
  #
  # Template for LiteLLM router:
  #
  # - job_name: 'litellm'
  #   scrape_interval: 15s
  #   metrics_path: '/metrics'
  #   bearer_token: 'YOUR_LITELLM_MASTER_KEY'
  #   static_configs:
  #     - targets: ['ROUTER_VM_IP:4000']
  #       labels:
  #         host: 'router-vm'
  #
  # After editing, reload without restart:
  #   curl -X POST http://localhost:9090/-/reload
  # ───────────────────────────────────────────────────────────────
EOF
    chown prometheus:prometheus /etc/prometheus/prometheus.yml
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
# Phase 5 — node_exporter (for this VM's own host metrics)
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

    rm -rf "node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64" "node_exporter-${NODE_EXPORTER_VERSION}.tar.gz"

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

  # Systemd journal — catches all service events on this VM
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
    # Disable default nginx site and enable grafana
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

  log "Waiting for services to settle (10s)..."
  sleep 10

  local all_ok=true

  check_service() {
    local name="$1"
    if systemctl is-active "$name" > /dev/null 2>&1; then
      ok "Service running: $name"
    else
      warn "Service NOT running: $name"
      all_ok=false
    fi
  }

  check_http() {
    local name="$1"
    local url="$2"
    if curl -sf "$url" > /dev/null 2>&1; then
      ok "HTTP OK: $name ($url)"
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
  check_http "Prometheus"   "http://localhost:9090/-/healthy"
  check_http "Loki"         "http://localhost:3100/ready"
  check_http "Grafana"      "http://localhost:3000/api/health"
  check_http "nginx→Grafana" "http://localhost:80"

  echo ""
  if $all_ok; then
    ok "All health checks passed"
  else
    warn "Some checks failed — review above and check: journalctl -u <service-name> -n 30"
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
  │             Monitoring VM — Service Summary             │
  ├─────────────────────────────────────────────────────────┤
  │                                                         │
  │  Grafana UI      http://${local_ip}                     │
  │                  http://${local_ip}:3000                │
  │                  Login: admin / admin  ← CHANGE THIS    │
  │                                                         │
  │  Prometheus      http://${local_ip}:9090                │
  │  Prometheus UI   http://${local_ip}:9090/targets        │
  │                                                         │
  │  Loki push URL   http://${local_ip}:3100                │
  │  (use this in Promtail configs on other hosts)          │
  │                                                         │
  ├─────────────────────────────────────────────────────────┤
  │  Next steps:                                            │
  │                                                         │
  │  1. Log into Grafana and change the admin password      │
  │                                                         │
  │  2. Add data sources in Grafana:                        │
  │     - Prometheus: http://localhost:9090                 │
  │     - Loki:       http://localhost:3100                 │
  │                                                         │
  │  3. Import dashboards:                                  │
  │     - Node Exporter Full: ID 1860                       │
  │     - LiteLLM: from GitHub (see runbook)                │
  │                                                         │
  │  4. Wire in the router VM:                              │
  │     Edit /etc/prometheus/prometheus.yml                 │
  │     Add the litellm scrape job, then:                   │
  │       curl -X POST http://localhost:9090/-/reload       │
  │                                                         │
  │  5. Install node_exporter + Promtail on other hosts     │
  │     (see Runbook B) pointing Promtail at:               │
  │       http://${local_ip}:3100                           │
  │                                                         │
  │  Step tracking files: ${STEP_DIR}/                      │
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
  echo "  ║      Monitoring VM Installation Script              ║"
  echo "  ║      Prometheus + Loki + Grafana + nginx            ║"
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
