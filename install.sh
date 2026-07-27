#!/usr/bin/env bash

set -e
if [ "$EUID" -ne 0 ]; then
    echo "❌ Please run this installer with sudo."
    echo
    echo "Example:"
    echo "sudo bash install.sh"
    exit 1
fi
echo "======================================"
echo " Billflow Bridge Installer"
echo "======================================"
echo

echo "Checking operating system..."

if ! grep -qi "Raspberry Pi OS" /etc/os-release; then
    echo "❌ This installer only supports Raspberry Pi OS."
    exit 1
fi

echo "✅ Raspberry Pi OS detected."
echo
echo "Checking Docker..."

if command -v docker >/dev/null 2>&1; then
    echo "✅ Docker is already installed."
else
    echo "Docker is not installed. Installing Docker..."

    apt-get update
    apt-get install -y ca-certificates curl

    curl -fsSL https://get.docker.com | sh

    echo "✅ Docker installed successfully."
fi
echo
echo "Checking Docker Compose..."

if docker compose version >/dev/null 2>&1; then
    echo "✅ Docker Compose is available."
else
    echo "❌ Docker Compose is not available."
    echo "Reinstalling Docker Compose plugin..."

    apt-get update
    apt-get install -y docker-compose-plugin

    if docker compose version >/dev/null 2>&1; then
        echo "✅ Docker Compose installed successfully."
    else
        echo "❌ Docker Compose installation failed."
        exit 1
    fi
fi
echo
echo "Creating Billflow directories..."

BRIDGE_DIR="/home/pi/bridge-server"
UPDATER_DIR="/opt/billflow-updater"
REQUEST_DIR="/opt/billflow-updater/requests"

mkdir -p "$BRIDGE_DIR"
mkdir -p "$UPDATER_DIR"
mkdir -p "$REQUEST_DIR"

echo "✅ Created:"
echo "   $BRIDGE_DIR"
echo "   $UPDATER_DIR"
echo "   $REQUEST_DIR"

echo
echo "Downloading Billflow files..."

REPO_BASE="https://raw.githubusercontent.com/abbashjz2/billflow-installer/main"

download_file() {
    local source_url="$1"
    local destination="$2"

    echo "Downloading: $destination"

    curl -fsSL "$source_url" -o "$destination"
}

download_file \
    "$REPO_BASE/docker-compose.prod.yml" \
    "$BRIDGE_DIR/docker-compose.prod.yml"

download_file \
    "$REPO_BASE/.env.example" \
    "$BRIDGE_DIR/.env.example"

download_file \
    "$REPO_BASE/host-updater/updater.js" \
    "$UPDATER_DIR/updater.js"

download_file \
    "$REPO_BASE/host-updater/logger.js" \
    "$UPDATER_DIR/logger.js"

download_file \
    "$REPO_BASE/host-updater/requestService.js" \
    "$UPDATER_DIR/requestService.js"

mkdir -p "$UPDATER_DIR/services"

download_file \
    "$REPO_BASE/host-updater/services/dockerService.js" \
    "$UPDATER_DIR/services/dockerService.js"

download_file \
    "$REPO_BASE/host-updater/services/envService.js" \
    "$UPDATER_DIR/services/envService.js"

download_file \
    "$REPO_BASE/host-updater/billflow-updater.service" \
    "/etc/systemd/system/billflow-updater.service"

echo "✅ Billflow files downloaded successfully."


echo
echo "✅ Installer checks completed successfully."