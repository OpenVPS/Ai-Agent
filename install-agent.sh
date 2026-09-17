#!/usr/bin/env bash
set -euo pipefail

APP_NAME="openvps-agent"
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/openvps"
CONFIG_FILE="${CONFIG_DIR}/agent.env"
SERVICE_FILE="/etc/systemd/system/${APP_NAME}.service"
AGENT_REPO="OpenVPS/Ai-Agent"
DOWNLOAD_BASE="https://github.com/${AGENT_REPO}/releases/latest/download"

TOKEN=""
BACKEND_URL=""

usage() {
    cat <<'USAGE'
Usage:
  sudo bash install-agent.sh --token TOKEN --backend BACKEND_URL

Example:
  curl -fsSL https://raw.githubusercontent.com/OpenVPS/Ai-Agent/main/install-agent.sh \
    | sudo bash -s -- \
      --token "YOUR_ENROLLMENT_TOKEN" \
      --backend "wss://app.openvps.dev/api/v1/agent/ws"

The installer:
  - detects Linux and CPU architecture
  - installs missing curl/python3 on supported package managers
  - downloads the matching OpenVPS Agent release
  - verifies SHA-256
  - enrolls this machine using the one-time token
  - installs /etc/openvps/agent.env
  - installs a systemd service
  - starts the agent and verifies the service
USAGE
}

log() { printf '[openvps-installer] %s\n' "$*"; }
fail() { printf '[openvps-installer] ERROR: %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --token)
            [[ $# -ge 2 ]] || fail "--token requires a value."
            TOKEN="$2"
            shift 2
            ;;
        --backend)
            [[ $# -ge 2 ]] || fail "--backend requires a value."
            BACKEND_URL="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            fail "Unknown argument: $1"
            ;;
    esac
done

[[ "${EUID}" -eq 0 ]] || fail "Run this installer with sudo/root."
[[ -n "${TOKEN}" ]] || fail "--token is required."
[[ -n "${BACKEND_URL}" ]] || fail "--backend is required."

install_dependency() {
    local command_name="$1"
    local package_name="$2"

    command -v "${command_name}" >/dev/null 2>&1 && return 0

    log "${command_name} is missing; installing ${package_name}..."

    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${package_name}"
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y -q "${package_name}"
    elif command -v yum >/dev/null 2>&1; then
        yum install -y -q "${package_name}"
    elif command -v zypper >/dev/null 2>&1; then
        zypper --non-interactive install -y "${package_name}"
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache "${package_name}"
    elif command -v pacman >/dev/null 2>&1; then
        pacman -Sy --noconfirm "${package_name}"
    else
        fail "Cannot install ${package_name}: unsupported package manager."
    fi

    command -v "${command_name}" >/dev/null 2>&1 \
        || fail "${command_name} is still unavailable after installation."
}

command -v systemctl >/dev/null 2>&1 \
    || fail "systemd/systemctl is required by the current OpenVPS service model."

install_dependency curl curl
install_dependency python3 python3

ARCH="$(uname -m)"
case "${ARCH}" in
    x86_64|amd64)
        AGENT_ASSET="openvps-agent-linux-amd64"
        ;;
    aarch64|arm64)
        AGENT_ASSET="openvps-agent-linux-arm64"
        ;;
    armv7l|armv7)
        AGENT_ASSET="openvps-agent-linux-armv7"
        ;;
    *)
        fail "Unsupported architecture: ${ARCH}. Supported: amd64, arm64, armv7."
        ;;
esac

case "${BACKEND_URL}" in
    ws://*)
        API_BASE="${BACKEND_URL#ws://}"
        API_SCHEME="http://"
        ;;
    wss://*)
        API_BASE="${BACKEND_URL#wss://}"
        API_SCHEME="https://"
        ;;
    *)
        fail "Backend URL must start with ws:// or wss://"
        ;;
esac

EXPECTED_SUFFIX="/api/v1/agent/ws"
case "${API_BASE}" in
    *"${EXPECTED_SUFFIX}")
        API_BASE="${API_BASE%"${EXPECTED_SUFFIX}"}"
        ;;
    *)
        fail "Backend URL must end with ${EXPECTED_SUFFIX}"
        ;;
esac

HTTP_BASE="${API_SCHEME}${API_BASE}"
ENROLL_URL="${HTTP_BASE}/api/v1/servers/enroll/agent"
HEALTH_URL="${HTTP_BASE}/health"

TMP_DIR="$(mktemp -d -t openvps-agent.XXXXXX)"
cleanup() { rm -rf "${TMP_DIR}"; }
trap cleanup EXIT

verify_sha256() {
    local file="$1"
    local expected="$2"
    local actual

    if command -v sha256sum >/dev/null 2>&1; then
        actual="$(sha256sum "${file}" | awk '{print $1}')"
    elif command -v openssl >/dev/null 2>&1; then
        actual="$(openssl dgst -sha256 "${file}" | awk '{print $NF}')"
    else
        fail "sha256sum or openssl is required for checksum verification."
    fi

    [[ "${actual}" == "${expected}" ]] \
        || fail "SHA-256 verification failed for ${AGENT_ASSET}."
}

log "OpenVPS Agent one-command installer"
log "Architecture: ${ARCH}"
log "Agent asset: ${AGENT_ASSET}"
log "Backend: ${BACKEND_URL}"

log "Checking backend connectivity..."
curl -fsS --connect-timeout 10 --max-time 15 "${HEALTH_URL}" >/dev/null \
    || fail "Backend health check failed: ${HEALTH_URL}"

BINARY_FILE="${TMP_DIR}/${AGENT_ASSET}"
CHECKSUM_FILE="${TMP_DIR}/SHA256SUMS"

log "Downloading ${AGENT_ASSET}..."
curl -fL --retry 3 --retry-all-errors --connect-timeout 10 --max-time 120 \
    "${DOWNLOAD_BASE}/${AGENT_ASSET}" -o "${BINARY_FILE}" \
    || fail "Failed to download ${AGENT_ASSET}."

log "Downloading checksums..."
curl -fL --retry 3 --retry-all-errors --connect-timeout 10 --max-time 30 \
    "${DOWNLOAD_BASE}/SHA256SUMS" -o "${CHECKSUM_FILE}" \
    || fail "Failed to download SHA256SUMS."

EXPECTED_HASH="$(awk -v name="${AGENT_ASSET}" '$2 == name || $2 == "*"name {print $1; exit}' "${CHECKSUM_FILE}")"
[[ -n "${EXPECTED_HASH}" ]] \
    || fail "No checksum entry found for ${AGENT_ASSET}."

verify_sha256 "${BINARY_FILE}" "${EXPECTED_HASH}"
chmod 0755 "${BINARY_FILE}"
log "Agent binary verified."

HOSTNAME_VALUE="$(hostname)"
OS_VALUE="$(uname -s | tr '[:upper:]' '[:lower:]')"

log "Registering this machine with OpenVPS..."
PAYLOAD="$(python3 - "${TOKEN}" "${HOSTNAME_VALUE}" "${OS_VALUE}" <<'PY'
import json
import sys

print(json.dumps({
    "token": sys.argv[1],
    "hostname": sys.argv[2],
    "os_name": sys.argv[3],
}))
PY
)"

RESPONSE="$(
    curl -fsS \
        --connect-timeout 10 \
        --max-time 30 \
        -X POST \
        "${ENROLL_URL}" \
        -H "Content-Type: application/json" \
        --data "${PAYLOAD}"
)" || fail "Enrollment request failed. The token may be expired or already used."

extract_json() {
    local key="$1"
    python3 - "${key}" "${RESPONSE}" <<'PY'
import json
import sys

key = sys.argv[1]
raw = sys.argv[2]

data = json.loads(raw)
value = data.get(key)

if value is None or value == "":
    raise SystemExit(f"missing field: {key}")

print(value)
PY
}

SERVER_ID="$(extract_json server_id)" || fail "Missing server_id."
AGENT_ID="$(extract_json agent_id)" || fail "Missing agent_id."
CREDENTIAL_ID="$(extract_json credential_id)" || fail "Missing credential_id."
CREDENTIAL_VALUE="$(extract_json credential_value)" || fail "Missing credential_value."

log "Enrollment successful."
log "Server ID: ${SERVER_ID}"
log "Agent ID: ${AGENT_ID}"

install -m 0755 "${BINARY_FILE}" "${INSTALL_DIR}/${APP_NAME}"

mkdir -p "${CONFIG_DIR}"
chmod 0700 "${CONFIG_DIR}"

umask 077
cat > "${CONFIG_FILE}" <<EOF_CONFIG
OPENVPS_BACKEND_URL=${BACKEND_URL}
OPENVPS_AGENT_ID=${AGENT_ID}
OPENVPS_SERVER_ID=${SERVER_ID}
OPENVPS_CREDENTIAL_ID=${CREDENTIAL_ID}
OPENVPS_CREDENTIAL_VALUE=${CREDENTIAL_VALUE}
OPENVPS_HOSTNAME=${HOSTNAME_VALUE}
OPENVPS_OS_NAME=${OS_VALUE}
OPENVPS_AGENT_VERSION=latest
EOF_CONFIG
chmod 0600 "${CONFIG_FILE}"
umask 022

cat > "${SERVICE_FILE}" <<EOF_SERVICE
[Unit]
Description=OpenVPS Agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=${CONFIG_FILE}
ExecStart=${INSTALL_DIR}/${APP_NAME}
Restart=always
RestartSec=5

NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/run

[Install]
WantedBy=multi-user.target
EOF_SERVICE

chmod 0644 "${SERVICE_FILE}"

systemctl daemon-reload
systemctl enable "${APP_NAME}" >/dev/null
systemctl restart "${APP_NAME}"

log "Waiting for agent service..."
for _ in $(seq 1 20); do
    if systemctl is-active --quiet "${APP_NAME}"; then
        log "Agent service is running."
        break
    fi
    sleep 1
done

if ! systemctl is-active --quiet "${APP_NAME}"; then
    log "Agent service failed to start."
    journalctl -u "${APP_NAME}" --no-pager -n 100 || true
    exit 1
fi

log "Installation complete."
log "Status: systemctl status ${APP_NAME} --no-pager"
log "Logs: journalctl -u ${APP_NAME} -f"
