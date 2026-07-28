#!/usr/bin/env bash
set -Eeuo pipefail

SUPABASE_URL="https://vcabaubdlvjzeczfyfgc.supabase.co"
ACTIVATE_URL="${SUPABASE_URL}/functions/v1/activate-bridge"
REPO_BASE="https://raw.githubusercontent.com/abbashjz2/billflow-installer/main"
BRIDGE_DIR="/home/pi/bridge-server"
UPDATER_DIR="/opt/billflow-updater"
REQUEST_DIR="${UPDATER_DIR}/requests"
DEFAULT_BRIDGE_VERSION="1.0.25"

trap 'echo "❌ Installation failed on line $LINENO." >&2' ERR

if [ "${EUID}" -ne 0 ]; then
  echo "❌ Run with sudo:"
  echo "curl -fsSL https://install.billflow.com/install.sh | sudo bash"
  exit 1
fi

if ! grep -qi "Raspberry Pi OS" /etc/os-release; then
  echo "❌ This installer supports Raspberry Pi OS only."
  exit 1
fi

echo "======================================"
echo " Billflow Bridge Installer"
echo "======================================"

echo "[1/8] Installing prerequisites..."
apt-get update -qq
apt-get install -y -qq ca-certificates curl nodejs >/dev/null

if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | sh
fi

if ! docker compose version >/dev/null 2>&1; then
  apt-get install -y -qq docker-compose-plugin >/dev/null
fi

echo "[2/8] Creating directories..."
mkdir -p "$BRIDGE_DIR" "$UPDATER_DIR/services" "$REQUEST_DIR"

# A token prompt must read from /dev/tty because install.sh is normally piped to bash.
echo
read -r -p "Enter Billflow activation token: " ACTIVATION_TOKEN </dev/tty
ACTIVATION_TOKEN="$(printf '%s' "$ACTIVATION_TOKEN" | tr -d '\r\n')"
if [ -z "$ACTIVATION_TOKEN" ]; then
  echo "❌ Activation token cannot be empty."
  exit 1
fi

echo "[3/8] Generating hardware fingerprint..."
MACHINE_ID="$(cat /etc/machine-id 2>/dev/null || true)"
CPU_SERIAL="$(awk -F ': ' '/^Serial/{print $2; exit}' /proc/cpuinfo 2>/dev/null || true)"
if [ -z "$MACHINE_ID$CPU_SERIAL" ]; then
  echo "❌ Could not determine a stable hardware identity."
  exit 1
fi
HARDWARE_FINGERPRINT="$(printf 'mid:%s|serial:%s' "$MACHINE_ID" "$CPU_SERIAL" | sha256sum | awk '{print $1}')"
HOSTNAME_VALUE="$(hostname)"
OS_INFO="$(. /etc/os-release && printf '%s %s' "${PRETTY_NAME:-Raspberry Pi OS}" "$(uname -m)")"

echo "[4/8] Activating Bridge..."
REQUEST_JSON="$(python3 - "$ACTIVATION_TOKEN" "$HARDWARE_FINGERPRINT" "$HOSTNAME_VALUE" "$DEFAULT_BRIDGE_VERSION" "$OS_INFO" <<'PY'
import json, sys
print(json.dumps({
    "api_version": 1,
    "activation_token": sys.argv[1],
    "hardware_fingerprint": sys.argv[2],
    "hostname": sys.argv[3],
    "bridge_version": sys.argv[4],
    "os_info": sys.argv[5],
}))
PY
)"

HTTP_BODY="$(mktemp)"
HTTP_CODE="$(curl -sS -o "$HTTP_BODY" -w '%{http_code}' \
  --connect-timeout 15 --max-time 45 \
  -X POST "$ACTIVATE_URL" \
  -H 'Content-Type: application/json' \
  --data "$REQUEST_JSON")"

if [ "$HTTP_CODE" != "200" ]; then
  echo "❌ Activation failed (HTTP $HTTP_CODE)."
  python3 - "$HTTP_BODY" <<'PY'
import json, sys
try:
    data = json.load(open(sys.argv[1], encoding='utf-8'))
    print(data.get('error') or data.get('message') or 'Invalid or expired activation token.')
except Exception:
    print('Invalid or expired activation token.')
PY
  rm -f "$HTTP_BODY"
  exit 1
fi

# Parse only the permanent credentials. The bootstrap JWT is intentionally not persisted.
eval "$(python3 - "$HTTP_BODY" <<'PY'
import json, shlex, sys
x = json.load(open(sys.argv[1], encoding='utf-8'))
required = ['tenant_id', 'installation_id', 'device_secret']
missing = [k for k in required if not x.get(k)]
if missing:
    raise SystemExit('Activation response missing: ' + ', '.join(missing))
values = {
    'TENANT_ID': x['tenant_id'],
    'INSTALLATION_ID': x['installation_id'],
    'DEVICE_SECRET': x['device_secret'],
    'PUBLIC_REF': x.get('public_ref', ''),
    'BRIDGE_VERSION': x.get('bridge_version') or '1.0.25',
}
for k, v in values.items():
    print(f'{k}={shlex.quote(str(v))}')
PY
)"
rm -f "$HTTP_BODY"
unset ACTIVATION_TOKEN REQUEST_JSON

echo "[5/8] Downloading production files..."
download_file() {
  curl -fsSL --retry 3 --connect-timeout 15 "$1" -o "$2"
}

download_file "$REPO_BASE/docker-compose.prod.yml" "$BRIDGE_DIR/docker-compose.prod.yml"
download_file "$REPO_BASE/host-updater/updater.js" "$UPDATER_DIR/updater.js"
download_file "$REPO_BASE/host-updater/logger.js" "$UPDATER_DIR/logger.js"
download_file "$REPO_BASE/host-updater/requestService.js" "$UPDATER_DIR/requestService.js"
download_file "$REPO_BASE/host-updater/services/dockerService.js" "$UPDATER_DIR/services/dockerService.js"
download_file "$REPO_BASE/host-updater/services/envService.js" "$UPDATER_DIR/services/envService.js"
download_file "$REPO_BASE/host-updater/billflow-updater.service" "/etc/systemd/system/billflow-updater.service"

echo "[6/8] Writing secure configuration..."
cat > "$BRIDGE_DIR/.env" <<ENVEOF
SUPABASE_URL=${SUPABASE_URL}
SUPABASE_FUNCTIONS_URL=${SUPABASE_URL}/functions/v1
BRIDGE_AUTH_URL=${SUPABASE_URL}/functions/v1/bridge-auth
BRIDGE_HEALTH_REPORT_URL=${SUPABASE_URL}/functions/v1/report-bridge-health

TENANT_ID=${TENANT_ID}
INSTALLATION_ID=${INSTALLATION_ID}
DEVICE_SECRET=${DEVICE_SECRET}
BRIDGE_HW_FINGERPRINT=${HARDWARE_FINGERPRINT}
BRIDGE_VERSION=${BRIDGE_VERSION}
BRIDGE_API_VERSION=1

COMMAND_POLL_ENABLED=true
HEALTH_REPORT_ENABLED=true
TERMINAL_PORT=3066

MIKROTIK_USER=admin
MIKROTIK_PASSWORD=
MIKROTIK_PORT=22
MIKROTIK_API_PORT=8728
MONITOR_SHARED_SECRET=
TELEGRAM_BOT_TOKEN=
TELEGRAM_CHAT_ID=
ENVEOF
chmod 600 "$BRIDGE_DIR/.env"

echo "[7/8] Starting Billflow Bridge..."
cd "$BRIDGE_DIR"
docker compose -f docker-compose.prod.yml pull
docker compose -f docker-compose.prod.yml up -d

echo "[8/8] Enabling updater..."
systemctl daemon-reload
systemctl enable --now billflow-updater.service

sleep 5
if ! docker inspect -f '{{.State.Running}}' noc-server 2>/dev/null | grep -q true; then
  echo "❌ Bridge container did not start."
  docker compose -f "$BRIDGE_DIR/docker-compose.prod.yml" logs --tail=80 || true
  exit 1
fi

echo
echo "======================================"
echo " ✅ Billflow Bridge installed"
echo " Public reference: ${PUBLIC_REF:-not returned}"
echo " Installation ID: $INSTALLATION_ID"
echo "======================================"
