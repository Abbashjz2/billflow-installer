#!/bin/bash

set -euo pipefail

TARGET_VERSION="${1:-}"

# Dedicated installations keep /opt/billflow-bridge.
# Multi-instance installations receive their own BRIDGE_DIR
# from the instance .env loaded by systemd.
BRIDGE_DIR="${BRIDGE_DIR:-/opt/billflow-bridge}"

ENV_FILE="$BRIDGE_DIR/.env"
PROD_ENV_FILE="$BRIDGE_DIR/.env"
if [ -n "${BRIDGE_INSTANCE_ID:-}" ]; then
  COMPOSE_FILE="$BRIDGE_DIR/docker-compose.multi.prod.yml"
else
  COMPOSE_FILE="$BRIDGE_DIR/docker-compose.prod.yml"
fi

if [[ ! "$TARGET_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Invalid version. Expected format: MAJOR.MINOR.PATCH"
  exit 1
fi

if [ ! -d "$BRIDGE_DIR" ]; then
  echo "Bridge directory not found: $BRIDGE_DIR"
  exit 1
fi

cd "$BRIDGE_DIR"

CURRENT_VERSION="$(grep '^BRIDGE_VERSION=' "$PROD_ENV_FILE" | cut -d= -f2)"

if [ "$CURRENT_VERSION" = "$TARGET_VERSION" ]; then
  echo "Bridge is already configured for version $TARGET_VERSION"
  exit 0
fi

sed -i "s/^BRIDGE_VERSION=.*/BRIDGE_VERSION=$TARGET_VERSION/" "$ENV_FILE"
sed -i "s/^BRIDGE_VERSION=.*/BRIDGE_VERSION=$TARGET_VERSION/" "$PROD_ENV_FILE"

unset BRIDGE_VERSION

docker compose \
  --env-file "$PROD_ENV_FILE" \
  -f "$COMPOSE_FILE" \
  pull

docker compose \
  --env-file "$PROD_ENV_FILE" \
  -f "$COMPOSE_FILE" \
  up -d

echo "Bridge updated from $CURRENT_VERSION to $TARGET_VERSION"
