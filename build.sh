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
        --iso-application "${DISTRO_NAME}" \
        --iso-publisher "${DISTRO_NAME}; https://github.com/blinbuntu/blinbuntu" \
        --iso-volume "${DISTRO_NAME} ${DISTRO_VERSION}" \
        --apt-indices false \
        --apt-recommends true \
        --memtest none \
        --security true \
        --backports false

    ok "live-build configured."

    # Ubuntu 26.04 resolute lacks gfxboot-theme-ubuntu and syslinux-themes-ubuntu-oneiric.
    # The original lb_binary_syslinux uses ${LB_SYSLINUX_THEME} which defaults to
    # ubuntu-oneiric — not available. Replace the script with a simplified version
    # that just installs syslinux and copies basic isolinux files for genisoimage.
    info "Replacing lb_binary_syslinux with resolute-compatible version..."
    cat > /usr/lib/live/build/lb_binary_syslinux << 'SYSLINUX_EOF'
#!/bin/sh

. "${LB_BASE:-/usr/lib/live/build}"/scripts/build.sh

DESCRIPTION="$(Echo 'installs syslinux into binary')"
HELP=""
USAGE="${PROGRAM} [--force]"

Arguments "${@}"

Read_conffiles config/all config/common config/bootstrap config/chroot config/binary config/source
Set_defaults

Echo_message "Begin installing syslinux (resolute-compatible)..."

Require_stagefile .stage/config .stage/bootstrap
Check_stagefile .stage/binary_syslinux
Check_lockfile .lock
Create_lockfile .lock

case "${LB_BINARY_IMAGES}" in
    iso*)
        _BOOTLOADER="isolinux"
        _SUFFIX="binary/isolinux"
        ;;
    net*)
        _BOOTLOADER="pxelinux"
        _SUFFIX="tftpboot"
        ;;
    hdd*|*)
        _BOOTLOADER="syslinux"
        _SUFFIX="binary/syslinux"
        ;;
esac

case "${LB_BUILD_WITH_CHROOT}" in
    true)
        Check_package chroot/usr/bin/syslinux syslinux

        Restore_cache cache/packages_binary
        Install_package

        mkdir -p ${_SUFFIX}

        for f in isolinux.bin ldlinux.c32 libcom32.c32 libutil.c32 \
                 menu.c32 reboot.c32 poweroff.c32 chain.c32; do
            src="chroot/usr/lib/ISOLINUX/${f}"
            if [ -e "${src}" ] 2>/dev/null; then
                cp "${src}" ${_SUFFIX}/ 2>/dev/null || true
            fi
        done

        if [ -f chroot/usr/lib/syslinux/modules/bios/ldlinux.c32 ]; then
            cp chroot/usr/lib/syslinux/modules/bios/ldlinux.c32 ${_SUFFIX}/ 2>/dev/null || true
        fi

        cat > ${_SUFFIX}/live.cfg << 'LIVECFG'
DEFAULT live
MENU LABEL ^Live
LABEL live
  MENU LABEL ^Live - Try Blinbuntu without installing
  LINUX /live/vmlinuz
  INITRD /live/initrd
  APPEND boot=live components quiet splash
LIVECFG

        Save_cache cache/packages_binary
        Remove_package
        ;;

    false)
        mkdir -p ${_SUFFIX}
        ;;
esac

if [ -e ${_SUFFIX}/live.cfg ]; then
    sed -i -e "s|@LB_BOOTAPPEND_LIVE@|${LB_BOOTAPPEND_LIVE}|g" \
        ${_SUFFIX}/live.cfg
fi

Create_stagefile .stage/binary_syslinux
SYSLINUX_EOF
    chmod +x /usr/lib/live/build/lb_binary_syslinux

    # Also set LB_BOOTLOADERS
    echo 'LB_BOOTLOADERS="grub-efi"' >> "${BUILD_DIR}/config/binary"
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
    LB_BOOTLOADERS="grub-efi" lb build 2>&1 | tee "${SCRIPT_DIR}/build.log"
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
