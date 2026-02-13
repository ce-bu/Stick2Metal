#!/bin/bash
# Post-install configuration for bare metal systems
# Run this script after deploying to physical hardware

set -e

SWAP_SIZE="${1:-8G}"

echo "=== Bare Metal Post-Install Configuration ==="

# Check if running on bare metal
if [ "$(systemd-detect-virt)" != "none" ]; then
    echo "Warning: This system appears to be a VM ($(systemd-detect-virt)), not bare metal."
    read -p "Continue anyway? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 1
    fi
fi

# Create swap file
if [ -f /swapfile ]; then
    echo "Swap file already exists, skipping..."
else
    echo "Creating ${SWAP_SIZE} swap file..."
    sudo fallocate -l "$SWAP_SIZE" /swapfile
    sudo chmod 600 /swapfile
    sudo mkswap /swapfile
    sudo swapon /swapfile
    
    # Add to fstab if not already present
    if ! grep -q '/swapfile' /etc/fstab; then
        echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
    fi
    
    echo "Swap file created and enabled."
fi

# Show current swap status
echo ""
echo "=== Swap Status ==="
swapon --show
free -h

echo ""
echo "=== Post-install complete ==="
