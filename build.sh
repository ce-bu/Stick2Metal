#!/bin/bash
#
# Build Ubuntu 24.04 Autoinstall USB Image using Packer
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Check dependencies
check_deps() {
    local missing=()
    
    if ! command -v packer &> /dev/null; then
        missing+=("packer")
    fi
    
    if ! command -v qemu-system-x86_64 &> /dev/null; then
        missing+=("qemu-system-x86")
    fi
    
    if [ ! -f /usr/share/OVMF/OVMF_CODE_4M.fd ]; then
        missing+=("ovmf")
    fi
    
    if [ ${#missing[@]} -ne 0 ]; then
        log_error "Missing dependencies: ${missing[*]}"
        echo ""
        echo "Install Packer:"
        echo "  curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo apt-key add -"
        echo "  sudo apt-add-repository \"deb [arch=amd64] https://apt.releases.hashicorp.com \$(lsb_release -cs) main\""
        echo "  sudo apt-get update && sudo apt-get install packer"
        echo ""
        echo "Install QEMU and OVMF:"
        echo "  sudo apt-get install -y qemu-system-x86 qemu-utils ovmf"
        exit 1
    fi
}

# Prepare UEFI variables file
prepare_uefi() {
    log_info "Preparing UEFI firmware..."
    cp /usr/share/OVMF/OVMF_VARS_4M.fd OVMF_VARS.fd
    chmod 644 OVMF_VARS.fd
}

# Initialize Packer plugins
init_packer() {
    log_info "Initializing Packer plugins..."
    packer init .
}

# Build the image
build_image() {
    log_info "Building Ubuntu 24.04 autoinstall image..."
    log_info "This will take 30-60 minutes depending on your system and network speed."
    log_info ""
    log_info "The QEMU window will open (non-headless mode with VGA)."
    log_info "You can watch the installation progress there."
    log_info ""
    
    # Remove old output if exists and prepare UEFI
    rm -rf output/
    prepare_uefi
    
    # Run Packer build
    PACKER_LOG=1 packer build \
        -var "headless=false" \
        ubuntu.pkr.hcl
}

# Post-build instructions
post_build() {
    log_info "============================================"
    log_info "Build complete!"
    log_info ""
    log_info "Output image: output/ubuntu-24.04-autoinstall"
    log_info ""
    log_info "To write to USB drive:"
    log_info "  sudo dd if=output/ubuntu-24.04-autoinstall of=/dev/sdX bs=4M status=progress conv=fsync"
    log_info ""
    log_info "Replace /dev/sdX with your USB device."
    log_info ""
    log_info "Default credentials:"
    log_info "  Username: ubuser"
    log_info "  Password: ubuser"
}

main() {
    log_info "Ubuntu 24.04 Autoinstall USB Builder (Packer + UEFI)"
    log_info "===================================================="
    
    check_deps
    init_packer
    build_image
    post_build
}

main "$@"
