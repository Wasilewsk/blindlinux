#!/bin/bash
set -euo pipefail

# ─── Blinbuntu Build Script ───────────────────────────────────────────────────
# Builds a custom Ubuntu-based live ISO with MATE, Cthulhu screenreader,
# Fenrir console screenreader, and accessibility-first design.
# ───────────────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/build"
CUSTOM_DIR="${SCRIPT_DIR}/custom"
SOUND_DIR="${SCRIPT_DIR}"

# Configuration
DISTRO_NAME="Blinbuntu"
DISTRO_VERSION="${DISTRO_VERSION:-26.04}"
UBUNTU_CODENAME="${UBUNTU_CODENAME:-resolute}"
ARCHITECTURE="${ARCHITECTURE:-amd64}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# Check if running as root or with sudo
if [ "$EUID" -ne 0 ]; then
    err "This script must be run as root (use sudo)."
    exit 1
fi

# Install build dependencies
install_build_deps() {
    info "Installing build dependencies..."
    apt-get update
    apt-get install -y \
        live-build \
        debootstrap \
        squashfs-tools \
        xorriso \
        isolinux \
        syslinux-efi \
        grub-efi-amd64-bin \
        grub-pc-bin \
        mtools \
        dosfstools \
        parted \
        git \
        wget \
        curl \
        ca-certificates \
        gnupg
    ok "Build dependencies installed."
}

# Set up build directory
setup_build() {
    info "Setting up build directory..."
    mkdir -p "${BUILD_DIR}"
    cd "${BUILD_DIR}"

    # Clean any previous build
    lb clean --purge 2>/dev/null || true

    info "Configuring live-build for ${DISTRO_NAME} ${DISTRO_VERSION} (${UBUNTU_CODENAME})..."
    lb config \
        --architectures "${ARCHITECTURE}" \
        --distribution "${UBUNTU_CODENAME}" \
        --archive-areas "main restricted universe multiverse" \
        --bootloaders "grub-efi,syslinux" \
        --iso-application "${DISTRO_NAME}" \
        --iso-publisher "${DISTRO_NAME}; https://github.com/blinbuntu/blinbuntu" \
        --iso-volume "${DISTRO_NAME} ${DISTRO_VERSION}" \
        --apt-indices false \
        --apt-recommends true \
        --firmware-binary true \
        --firmware-chroot true \
        --memtest none \
        --security true \
        --updates true \
        --backports false \
        --debian-installer live \
        --iso-language "en_US.UTF-8" \
        --iso-country "US"

    ok "live-build configured."
}

# Apply custom configuration
apply_custom() {
    info "Applying custom configuration..."

    # Package lists
    if [ -d "${CUSTOM_DIR}/package-lists" ]; then
        mkdir -p "${BUILD_DIR}/config/package-lists"
        cp -r "${CUSTOM_DIR}/package-lists/"* "${BUILD_DIR}/config/package-lists/"
    fi

    # Hooks (live-build hooks must be in config/hooks/live/)
    if [ -d "${CUSTOM_DIR}/hooks" ]; then
        mkdir -p "${BUILD_DIR}/config/hooks/live"
        mkdir -p "${BUILD_DIR}/config/hooks/boot"
        mkdir -p "${BUILD_DIR}/config/hooks/binary"
        cp -r "${CUSTOM_DIR}/hooks/"* "${BUILD_DIR}/config/hooks/"
    fi

    # Includes (files placed directly into the filesystem)
    if [ -d "${CUSTOM_DIR}/includes.chroot" ]; then
        mkdir -p "${BUILD_DIR}/config/includes.chroot"
        cp -r "${CUSTOM_DIR}/includes.chroot/"* "${BUILD_DIR}/config/includes.chroot/"
    fi

    # Bootloaders
    if [ -d "${CUSTOM_DIR}/bootloaders" ]; then
        mkdir -p "${BUILD_DIR}/config/bootloaders"
        cp -r "${CUSTOM_DIR}/bootloaders/"* "${BUILD_DIR}/config/bootloaders/"
    fi

    # Copy sound files into the includes
    mkdir -p "${BUILD_DIR}/config/includes.chroot/usr/share/blinbuntu"
    for sound in start.mp3 logon.mp3 livestart.mp3; do
        if [ -f "${SOUND_DIR}/${sound}" ]; then
            cp "${SOUND_DIR}/${sound}" "${BUILD_DIR}/config/includes.chroot/usr/share/blinbuntu/"
        else
            warn "Sound file ${sound} not found in project root."
        fi
    done

    # Copy Porta-Bop if present
    for portabop in "${SOUND_DIR}"/Porta-Bop*linux*.tar.gz "${SOUND_DIR}"/portabop*.tar.gz; do
        if [ -f "${portabop}" ]; then
            mkdir -p "${BUILD_DIR}/config/includes.chroot/usr/share/blinbuntu"
            cp "${portabop}" "${BUILD_DIR}/config/includes.chroot/usr/share/blinbuntu/portabop.tar.gz"
            ok "Porta-Bop installer found: $(basename "${portabop}")"
            break
        fi
    done

    # Make hooks executable
    find "${BUILD_DIR}/config/hooks" -name "*.chroot" -exec chmod +x {} \; 2>/dev/null || true
    find "${BUILD_DIR}/config/hooks" -name "*.binary" -exec chmod +x {} \; 2>/dev/null || true

    ok "Custom configuration applied."
}

# Build the ISO
build_iso() {
    info "Building ISO image..."
    cd "${BUILD_DIR}"
    lb build 2>&1 | tee "${SCRIPT_DIR}/build.log"
    ok "Build complete."

    # Find the generated ISO
    ISO_FILE=$(find "${BUILD_DIR}" -name "*.iso" -type f | head -1)
    if [ -n "${ISO_FILE}" ]; then
        ok "ISO created: ${ISO_FILE}"
        cp "${ISO_FILE}" "${SCRIPT_DIR}/" 2>/dev/null || true
    else
        err "No ISO file found after build. Check build.log for errors."
        exit 1
    fi
}

# ─── Main ─────────────────────────────────────────────────────────────────────

case "${1:-build}" in
    deps)
        install_build_deps
        ;;
    config)
        setup_build
        apply_custom
        ;;
    build)
        install_build_deps
        setup_build
        apply_custom
        build_iso
        ;;
    clean)
        info "Cleaning build directory..."
        rm -rf "${BUILD_DIR}"
        rm -f "${SCRIPT_DIR}/build.log"
        ok "Clean complete."
        ;;
    *)
        echo "Usage: $0 {deps|config|build|clean}"
        echo "  deps   - Install build dependencies only"
        echo "  config - Configure live-build without building"
        echo "  build  - Full build (default)"
        echo "  clean  - Remove build artifacts"
        exit 1
        ;;
esac
