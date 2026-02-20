#!/bin/bash
# Cleanup script to remove residual DSVideoServer data from Synology NAS
# Run this via SSH if installation fails with error 263

set -euo pipefail

echo "═══════════════════════════════════════════════════════════════════════════════"
echo "Synology NAS Cleanup Script for DSVideoServer"
echo "═══════════════════════════════════════════════════════════════════════════════"
echo ""
echo "This script removes residual data from previous installation attempts."
echo "Run this on your Synology NAS via SSH if you get error 263."
echo ""
echo "⚠️  WARNING: This will delete any existing DSVideoServer package data!"
echo ""
read -p "Continue? (y/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Cancelled."
    exit 1
fi

PACKAGE="DSVideoServer"

echo ""
echo "🧹 Cleaning up residual data..."

# Stop package if running
if synopkg status "$PACKAGE" &>/dev/null; then
    echo "   Stopping package..."
    synopkg stop "$PACKAGE" 2>/dev/null || true
fi

# Remove package if installed
if synopkg list | grep -q "$PACKAGE"; then
    echo "   Uninstalling package..."
    synopkg uninstall "$PACKAGE" 2>/dev/null || true
fi

# Clean up directories
echo "   Removing directories..."

# Package directory
if [ -d "/var/packages/${PACKAGE}" ]; then
    echo "      Removing /var/packages/${PACKAGE}"
    sudo rm -rf "/var/packages/${PACKAGE}"
fi

# App data directory
if [ -d "/volume1/@appdata/${PACKAGE}" ]; then
    echo "      Removing /volume1/@appdata/${PACKAGE}"
    sudo rm -rf "/volume1/@appdata/${PACKAGE}"
fi

# Check other volumes
for vol in /volume*; do
    if [ -d "${vol}/@appdata/${PACKAGE}" ]; then
        echo "      Removing ${vol}/@appdata/${PACKAGE}"
        sudo rm -rf "${vol}/@appdata/${PACKAGE}"
    fi
done

# Log files
if [ -f "/var/log/packages/${PACKAGE}.log" ]; then
    echo "      Removing log file"
    sudo rm -f "/var/log/packages/${PACKAGE}.log"
fi

echo ""
echo "✅ Cleanup complete!"
echo ""
echo "You can now try installing the SPK again."
