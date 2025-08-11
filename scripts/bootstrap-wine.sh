#!/usr/bin/env bash
set -euo pipefail

# Config (override via env)
# On the VM, set PROJECT_DIR to where this repo lives on that host.
PROJECT_DIR="${PROJECT_DIR:-/opt/wine-project}"
GIT_URL="${GIT_URL:-}"                           # e.g. https://github.com/you/wine-project.git
PORT="${PORT:-8082}"
BASIC_USER="${BASIC_USER:-cardano}"
BASIC_PASS="${BASIC_PASS:-lovelace}"

require_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo "Please run as root (sudo)." >&2
    exit 1
  fi
}

install_docker() {
  if command -v docker >/dev/null 2>&1; then return; fi
  echo "Installing Docker..."
  curl -fsSL https://get.docker.com | sh
  systemctl enable --now docker
}

ensure_compose() {
  if docker compose version >/dev/null 2>&1; then return; fi

  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y && apt-get install -y docker-compose-plugin
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y docker-compose-plugin || true
  elif command -v yum >/dev/null 2>&1; then
    yum install -y docker-compose-plugin || true
  fi

  if docker compose version >/dev/null 2>&1; then return; fi

  echo "Installing docker compose plugin manually..."
  arch="$(uname -m)"
  case "$arch" in
    x86_64) c_arch="x86_64" ;;
    aarch64|arm64) c_arch="aarch64" ;;
    *) echo "Unsupported arch: $arch"; exit 1 ;;
  esac
  mkdir -p /usr/local/lib/docker/cli-plugins
  curl -fsSL -o /usr/local/lib/docker/cli-plugins/docker-compose \
    "https://github.com/docker/compose/releases/download/v2.27.1/docker-compose-linux-${c_arch}"
  chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
}

ensure_git() {
  if command -v git >/dev/null 2>&1; then return; fi
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y && apt-get install -y git
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y git || true
  elif command -v yum >/dev/null 2>&1; then
    yum install -y git || true
  fi
}

fetch_project() {
  if [ -f "${PROJECT_DIR}/docker-compose.yml" ]; then return; fi
  if [ -n "$GIT_URL" ]; then
    mkdir -p "$(dirname "$PROJECT_DIR")"
    git clone --depth 1 "$GIT_URL" "$PROJECT_DIR"
  else
    echo "Project not found at ${PROJECT_DIR} and GIT_URL not set." >&2
    exit 1
  fi
}

prepare_dirs_and_env() {
  mkdir -p "${PROJECT_DIR}/ipfs/data" "${PROJECT_DIR}/ipfs/staging"
  cat >/etc/wine-project.env <<EOF
PORT=${PORT}
BASIC_USER=${BASIC_USER}
BASIC_PASS=${BASIC_PASS}
EOF
}

install_systemd_unit_from_repo() {
  local unit_src="${PROJECT_DIR}/systemd/wine-project.service"
  local unit_dst="/etc/systemd/system/wine-project.service"
  if [ ! -f "$unit_src" ]; then
    echo "Unit file not found at ${unit_src}" >&2
    exit 1
  fi

  # Copy and normalize WorkingDirectory to PROJECT_DIR
  local tmp
  tmp="$(mktemp)"; cp "$unit_src" "$tmp"
  sed -i "s|^WorkingDirectory=.*|WorkingDirectory=${PROJECT_DIR}|" "$tmp"
  install -D -m 0644 "$tmp" "$unit_dst"
  rm -f "$tmp"

  # Add EnvironmentFile via drop-in override
  mkdir -p /etc/systemd/system/wine-project.service.d
  cat >/etc/systemd/system/wine-project.service.d/override.conf <<EOF
[Service]
EnvironmentFile=/etc/wine-project.env
EOF

  systemctl daemon-reload
  systemctl enable --now wine-project.service
}

open_firewall_ports() {
  # Best-effort; ignore errors if ufw/firewalld missing
  if command -v ufw >/dev/null 2>&1; then
    ufw allow ${PORT}/tcp >/dev/null 2>&1 || true
    ufw allow 8080/tcp >/dev/null 2>&1 || true  # IPFS gateway
    ufw allow 4001/tcp >/dev/null 2>&1 || true  # IPFS swarm
  elif command -v firewall-cmd >/dev/null 2>&1; then
    firewall-cmd --add-port=${PORT}/tcp --permanent >/dev/null 2>&1 || true
    firewall-cmd --add-port=8080/tcp --permanent >/dev/null 2>&1 || true
    firewall-cmd --add-port=4001/tcp --permanent >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
  fi
}

verify() {
  echo "Waiting for containers..."
  sleep 4
  docker compose -f "${PROJECT_DIR}/docker-compose.yml" ps | cat || true
  echo "Try: curl -u ${BASIC_USER}:${BASIC_PASS} http://localhost:${PORT}/swagger-ui"
}

main() {
  require_root
  install_docker
  ensure_compose
  ensure_git
  fetch_project
  prepare_dirs_and_env
  open_firewall_ports
  install_systemd_unit_from_repo
  verify
}

main "$@"


