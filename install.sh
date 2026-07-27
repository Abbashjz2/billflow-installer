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
echo "✅ Installer checks completed successfully."