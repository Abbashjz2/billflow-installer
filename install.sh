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
echo "Installer started successfully."