#!/usr/bin/env bash
set -Eeuo pipefail

DEV_MODE=false
for arg in "$@"; do
  case "$arg" in
    --dev) DEV_MODE=true ;;
    *)
      echo "❌ Unknown argument: $arg"
      echo "Supported option: --dev"
      exit 1
      ;;
  esac
done

SUPABASE_URL="https://vcabaubdlvjzeczfyfgc.supabase.co"
ACTIVATE_URL="${SUPABASE_URL}/functions/v1/activate-bridge"
REPO_BASE="https://raw.githubusercontent.com/abbashjz2/billflow-installer/main"
BRIDGE_DIR="/opt/billflow-bridge"
LEGACY_BRIDGE_DIR="/home/pi/bridge-server"
UPDATE_AGENT_DIR="/opt/bridge-update-agent"
DEFAULT_BRIDGE_VERSION="1.0.32"
EXISTING_ENV="${BRIDGE_DIR}/.env"
ENV_BACKUP=""

cleanup() {
  if [ -n "${ENV_BACKUP:-}" ] && [ -f "$ENV_BACKUP" ]; then
    rm -f "$ENV_BACKUP"
  fi
}
trap cleanup EXIT
trap 'echo "❌ Installation failed on line $LINENO." >&2' ERR

if [ "${EUID}" -ne 0 ]; then
  echo "❌ Run with sudo."
  exit 1
fi

if [ ! -f /etc/os-release ]; then
  echo "❌ Unsupported Linux system: /etc/os-release was not found."
  exit 1
fi

# shellcheck disable=SC1091
source /etc/os-release

case "${ID:-}" in
  debian|ubuntu|raspbian)
    ;;
  *)
    echo "❌ Unsupported Linux distribution: ${PRETTY_NAME:-unknown}"
    echo "Supported systems: Debian, Ubuntu, and Raspberry Pi OS."
    exit 1
    ;;
esac

if [ -r /proc/device-tree/model ]; then
  PI_MODEL="$(tr -d '\0' < /proc/device-tree/model)"
else
  PI_MODEL=""
fi

if [[ "$PI_MODEL" == *"Raspberry Pi"* ]]; then
  PLATFORM_TYPE="raspberry-pi"
  echo "✅ Raspberry Pi detected: $PI_MODEL"
else
  PLATFORM_TYPE="linux"
  echo "✅ Supported Linux detected: ${PRETTY_NAME}"
fi

echo " Architecture: $(uname -m)"
echo "======================================"
echo " Billflow Bridge Installer"
echo "======================================"

if [ "$DEV_MODE" = true ]; then
  echo "⚠️  DEVELOPMENT MODE"
  echo "Existing legacy credentials will be reused."
fi

echo "[1/8] Installing prerequisites..."
apt-get update -qq
apt-get install -y -qq ca-certificates curl nodejs python3 openssl >/dev/null

if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | sh
fi

if ! docker compose version >/dev/null 2>&1; then
  apt-get install -y -qq docker-compose-plugin >/dev/null
fi

echo "[2/8] Creating directories..."
mkdir -p "$BRIDGE_DIR" "$UPDATE_AGENT_DIR"

if [ -f "$LEGACY_BRIDGE_DIR/.env" ] && [ ! -f "$BRIDGE_DIR/.env" ]; then
  echo "ℹ️  Migrating existing Bridge configuration..."

  cp "$LEGACY_BRIDGE_DIR/.env" "$BRIDGE_DIR/.env"
  chmod 600 "$BRIDGE_DIR/.env"

  echo "✅ Existing configuration migrated to $BRIDGE_DIR"
fi

if [ "$DEV_MODE" = true ]; then
  echo "[DEV] Loading existing Bridge credentials..."

  if [ ! -f "$EXISTING_ENV" ]; then
    echo "❌ Existing Bridge environment was not found:"
    echo "   $EXISTING_ENV"
    exit 1
  fi

  set -a
  # shellcheck disable=SC1090
  source "$EXISTING_ENV"
  set +a

  REQUIRED_DEV_VARIABLES=(
    SUPABASE_URL
    TENANT_ID
    INSTALLATION_ID
    LICENSE_KEY
    BRIDGE_VALIDATION_SECRET
  )

  for variable_name in "${REQUIRED_DEV_VARIABLES[@]}"; do
    if [ -z "${!variable_name:-}" ]; then
      echo "❌ Missing $variable_name in $EXISTING_ENV"
      exit 1
    fi
  done

  ENV_BACKUP="$(mktemp)"
  cp "$EXISTING_ENV" "$ENV_BACKUP"
  chmod 600 "$ENV_BACKUP"
  echo "✅ Existing credentials loaded and backed up."
else
  echo
  read -r -p "Enter Billflow activation token: " ACTIVATION_TOKEN </dev/tty
  ACTIVATION_TOKEN="$(printf '%s' "$ACTIVATION_TOKEN" | tr -d '\r\n')"
  if [ -z "$ACTIVATION_TOKEN" ]; then
    echo "❌ Activation token cannot be empty."
    exit 1
  fi
fi

echo "[3/8] Generating hardware fingerprint..."

MACHINE_ID="$(cat /etc/machine-id 2>/dev/null || true)"
CPU_SERIAL="$(awk -F ': ' '/^Serial/{print $2; exit}' /proc/cpuinfo 2>/dev/null || true)"
PRODUCT_UUID="$(cat /sys/class/dmi/id/product_uuid 2>/dev/null || true)"
PRIMARY_MAC="$(ip link 2>/dev/null | awk '/link\/ether/ {print $2; exit}')"

if [ -z "$MACHINE_ID$CPU_SERIAL$PRODUCT_UUID$PRIMARY_MAC" ]; then
  echo "❌ Could not determine a stable hardware identity."
  exit 1
fi

HARDWARE_FINGERPRINT="$(
  printf 'mid:%s|serial:%s|uuid:%s|mac:%s' \
    "$MACHINE_ID" \
    "$CPU_SERIAL" \
    "$PRODUCT_UUID" \
    "$PRIMARY_MAC" |
  sha256sum |
  awk '{print $1}'
)"

HOSTNAME_VALUE="$(hostname)"
OS_INFO="$(. /etc/os-release && printf '%s %s' "${PRETTY_NAME:-Linux}" "$(uname -m)")"
ARCHITECTURE="$(uname -m)"

case "$ARCHITECTURE" in
  x86_64)
    PLATFORM_ARCH="amd64"
    ;;
  aarch64)
    PLATFORM_ARCH="arm64"
    ;;
  armv7l|armv6l)
    PLATFORM_ARCH="armv7"
    ;;
  *)
    echo "❌ Unsupported CPU architecture: $ARCHITECTURE"
    exit 1
    ;;
esac

echo " Architecture: $PLATFORM_ARCH"
if [ "$DEV_MODE" = true ]; then
  echo "[4/8] Skipping activation in development mode..."
  PUBLIC_REF="development-mode"
  BRIDGE_VERSION="${BRIDGE_VERSION:-$DEFAULT_BRIDGE_VERSION}"
else
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
    'BRIDGE_VERSION': x.get('bridge_version') or '1.0.32',
}
for k, v in values.items():
    print(f'{k}={shlex.quote(str(v))}')
PY
)"
  rm -f "$HTTP_BODY"
  unset ACTIVATION_TOKEN REQUEST_JSON
fi

echo "[5/8] Downloading production files..."
download_file() {
  curl -fsSL --retry 3 --connect-timeout 15 "$1" -o "$2"
}

download_file "$REPO_BASE/bridge-update-agent/server.js" \
  "$UPDATE_AGENT_DIR/server.js"

download_file "$REPO_BASE/bridge-update-agent/update-bridge.sh" \
  "$UPDATE_AGENT_DIR/update-bridge.sh"

download_file "$REPO_BASE/bridge-update-agent/bridge-update-agent.service" \
  "/etc/systemd/system/bridge-update-agent.service"


download_file "$REPO_BASE/docker-compose.prod.yml" \
  "$BRIDGE_DIR/docker-compose.prod.yml"

if [ ! -s "$BRIDGE_DIR/docker-compose.prod.yml" ]; then
  echo "❌ Failed to download docker-compose.prod.yml"
  exit 1
fi

chmod 600 "$UPDATE_AGENT_DIR/server.js"
chmod 700 "$UPDATE_AGENT_DIR/update-bridge.sh"

UPDATE_AGENT_SECRET="$(openssl rand -hex 32)"

echo "[6/8] Writing secure configuration..."
if [ "$DEV_MODE" = true ]; then
  cp "$ENV_BACKUP" "$BRIDGE_DIR/.env"
  chmod 600 "$BRIDGE_DIR/.env"

  if ! grep -q '^UPDATE_AGENT_URL=' "$BRIDGE_DIR/.env"; then
  echo 'UPDATE_AGENT_URL=http://172.18.0.1:3067' >> "$BRIDGE_DIR/.env"
fi

if ! grep -q '^UPDATE_AGENT_SECRET=' "$BRIDGE_DIR/.env"; then
  echo "UPDATE_AGENT_SECRET=${UPDATE_AGENT_SECRET}" >> "$BRIDGE_DIR/.env"
fi

if ! grep -q '^UPDATE_AGENT_TIMEOUT_MS=' "$BRIDGE_DIR/.env"; then
  echo 'UPDATE_AGENT_TIMEOUT_MS=10000' >> "$BRIDGE_DIR/.env"
fi


  rm -f "$ENV_BACKUP"
  ENV_BACKUP=""
  echo "✅ Existing .env restored unchanged."
else
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

UPDATE_AGENT_URL=http://172.18.0.1:3067
UPDATE_AGENT_SECRET=${UPDATE_AGENT_SECRET}
UPDATE_AGENT_TIMEOUT_MS=10000

MIKROTIK_USER=admin
MIKROTIK_PASSWORD=
MIKROTIK_PORT=22
MIKROTIK_API_PORT=8728
MONITOR_SHARED_SECRET=
TELEGRAM_BOT_TOKEN=
TELEGRAM_CHAT_ID=
ENVEOF
  chmod 600 "$BRIDGE_DIR/.env"
fi

echo "[7/8] Starting Billflow Bridge..."
cd "$BRIDGE_DIR"

docker compose \
  --env-file .env \
  -f docker-compose.prod.yml \
  pull

docker compose \
  --env-file .env \
  -f docker-compose.prod.yml \
  up -d


echo "[8/8] Enabling Bridge update agent..."

systemctl disable --now billflow-updater.service 2>/dev/null || true
systemctl daemon-reload
systemctl enable --now bridge-update-agent.service

sleep 5
if ! docker inspect -f '{{.State.Running}}' noc-server 2>/dev/null | grep -q true; then
  echo "❌ Bridge container did not start."
  docker compose -f "$BRIDGE_DIR/docker-compose.prod.yml" logs --tail=80 || true
  exit 1
fi

echo
echo "======================================"
echo " ✅ Billflow Bridge installed"
if [ "$DEV_MODE" = true ]; then
  echo " Mode: development (legacy credentials)"
else
  echo " Mode: production activation"
fi
echo " Public reference: ${PUBLIC_REF:-not returned}"
echo " Installation ID: $INSTALLATION_ID"
echo "======================================"
