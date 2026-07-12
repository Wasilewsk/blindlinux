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
        syslinux-common \
        syslinux \
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
    # The original lb_binary_syslinux script tries to install these packages and fails.
    # Solution: pre-create binary/isolinux with real syslinux files from the host,
    # and replace lb_binary_syslinux with a minimal no-op since the files are already there.

    info "Pre-creating binary/isolinux with host syslinux files..."
    mkdir -p "${BUILD_DIR}/binary/isolinux"

    # Find isolinux.bin from the host's isolinux package and copy explicitly
    for dir in /usr/lib/ISOLINUX /usr/lib/syslinux /usr/share/syslinux /usr/lib/syslinux/bios; do
        if [ -f "${dir}/isolinux.bin" ]; then
            cp -f "${dir}/isolinux.bin" "${BUILD_DIR}/binary/isolinux/isolinux.bin"
            ok "Copied isolinux.bin from ${dir}"
            break
        fi
    done

    if [ ! -f "${BUILD_DIR}/binary/isolinux/isolinux.bin" ]; then
        ISOLINUX_PATH=$(dpkg -L isolinux 2>/dev/null | grep 'isolinux.bin$' | head -1 || true)
        if [ -n "$ISOLINUX_PATH" ] && [ -f "$ISOLINUX_PATH" ]; then
            cp -f "$ISOLINUX_PATH" "${BUILD_DIR}/binary/isolinux/isolinux.bin"
            ok "Copied isolinux.bin from dpkg path ${ISOLINUX_PATH}"
        fi
    fi

    # Copy ldlinux and .c32 modules from syslinux-common
    for dir in /usr/lib/syslinux /usr/lib/syslinux/modules/bios /usr/share/syslinux; do
        if [ -d "$dir" ]; then
            cp -f "${dir}"/ldlinux.c32 "${BUILD_DIR}/binary/isolinux/" 2>/dev/null || true
            cp -f "${dir}"/ldlinux.sys "${BUILD_DIR}/binary/isolinux/" 2>/dev/null || true
            cp -f "${dir}"/*.c32 "${BUILD_DIR}/binary/isolinux/" 2>/dev/null || true
        fi
    done

    # Also check /usr/lib/ISOLINUX for any additional files
    if [ -d /usr/lib/ISOLINUX ]; then
        for f in /usr/lib/ISOLINUX/*; do
            [ -f "$f" ] && cp -f "$f" "${BUILD_DIR}/binary/isolinux/" 2>/dev/null || true
        done
    fi

    # Verify isolinux.bin is present
    if [ -f "${BUILD_DIR}/binary/isolinux/isolinux.bin" ]; then
        ok "isolinux.bin verified in binary/isolinux/"
    else
        err "CRITICAL: isolinux.bin not found in binary/isolinux/"
    fi
    ls -la "${BUILD_DIR}/binary/isolinux/" 2>&1 | head -5 || warn "binary/isolinux is empty!"

    # Create minimal live.cfg for isolinux
    cat > "${BUILD_DIR}/binary/isolinux/live.cfg" << 'LIVECFG'
DEFAULT live
MENU LABEL ^Live
LABEL live
  MENU LABEL ^Live - Try Blinbuntu without installing
  LINUX /live/vmlinuz
  INITRD /live/initrd
  APPEND boot=live components quiet splash
LIVECFG

    # Ensure isohybrid is in PATH (needed by live-build binary.sh)
    # Put wrapper in /usr/bin (not /usr/local/bin — live-build's PATH may not include it)
    ISOHYBRID_FOUND=false
    for dir in /usr/lib/ISOLINUX /usr/lib/syslinux /usr/bin /usr/sbin; do
        if [ -f "${dir}/isohybrid" ]; then
            cp -f "${dir}/isohybrid" /usr/bin/isohybrid
            chmod +x /usr/bin/isohybrid
            ISOHYBRID_FOUND=true
            ok "isohybrid installed from ${dir}"
            break
        fi
    done
    if [ "$ISOHYBRID_FOUND" = false ]; then
        ISOHYBRID_PATH=$(dpkg -S isohybrid 2>/dev/null | grep -v '^diversion' | head -1 | cut -d: -f2 | tr -d ' ' || true)
        if [ -n "$ISOHYBRID_PATH" ] && [ -f "$ISOHYBRID_PATH" ]; then
            cp -f "$ISOHYBRID_PATH" /usr/bin/isohybrid
            chmod +x /usr/bin/isohybrid
            ok "isohybrid installed from dpkg path ${ISOHYBRID_PATH}"
        else
            cat > /usr/bin/isohybrid << 'ISOHYBRIDWrapper'
#!/bin/sh
exit 0
ISOHYBRIDWrapper
            chmod +x /usr/bin/isohybrid
            warn "isohybrid not found — created no-op wrapper in /usr/bin"
        fi
    fi

    # Patch binary.sh to skip isohybrid (it may not be available on Ubuntu resolute)
    if [ -f /usr/lib/live/build/binary.sh ]; then
        sed -i 's|\bisohybrid\b|true|g' /usr/lib/live/build/binary.sh 2>/dev/null || true
        ok "Patched binary.sh to skip isohybrid"
    fi

    # Replace lb_binary_syslinux with a standalone script that copies real syslinux files
    # from the host (which has isolinux + syslinux-common installed as build deps).
    # The original script fails because gfxboot-theme-ubuntu and syslinux-themes-ubuntu-oneiric
    # don't exist for Ubuntu 26.04 resolute.
    info "Replacing lb_binary_syslinux with resolute-compatible version..."
    cat > /usr/lib/live/build/lb_binary_syslinux << 'SYSLINUXSCRIPT'
#!/bin/sh
# Replacement lb_binary_syslinux for Ubuntu 26.04 resolute
# Copies real syslinux/isolinux files from the host system into binary/isolinux/

_SUFFIX="binary/isolinux"
case "${LB_BINARY_IMAGES}" in
    iso*) _BOOTLOADER="isolinux"; _SUFFIX="binary/isolinux" ;;
    net*) _BOOTLOADER="pxelinux"; _SUFFIX="tftpboot" ;;
    hdd*|*) _BOOTLOADER="syslinux"; _SUFFIX="binary/syslinux" ;;
esac

mkdir -p "${_SUFFIX}"

# Copy isolinux.bin
for dir in /usr/lib/ISOLINUX /usr/lib/syslinux /usr/share/syslinux; do
    if [ -f "${dir}/isolinux.bin" ]; then
        cp -f "${dir}/isolinux.bin" "${_SUFFIX}/isolinux.bin"
        echo "[lb_binary_syslinux] Copied isolinux.bin from ${dir}"
        break
    fi
done

if [ ! -f "${_SUFFIX}/isolinux.bin" ]; then
    # Fallback: search via dpkg
    _PATH=$(dpkg -L isolinux 2>/dev/null | grep 'isolinux.bin$' | head -1 || true)
    if [ -n "$_PATH" ] && [ -f "$_PATH" ]; then
        cp -f "$_PATH" "${_SUFFIX}/isolinux.bin"
        echo "[lb_binary_syslinux] Copied isolinux.bin from dpkg: ${_PATH}"
    fi
fi

if [ ! -f "${_SUFFIX}/isolinux.bin" ]; then
    echo "[lb_binary_syslinux] ERROR: isolinux.bin not found!" >&2
    exit 1
fi

# Copy ldlinux.c32 and other .c32 modules
for dir in /usr/lib/syslinux /usr/lib/syslinux/modules/bios /usr/share/syslinux; do
    if [ -d "$dir" ]; then
        cp -f "${dir}"/ldlinux.c32 "${_SUFFIX}/" 2>/dev/null || true
        cp -f "${dir}"/ldlinux.sys "${_SUFFIX}/" 2>/dev/null || true
        cp -f "${dir}"/*.c32 "${_SUFFIX}/" 2>/dev/null || true
    fi
done

# Copy any additional files from /usr/lib/ISOLINUX
for _f in /usr/lib/ISOLINUX/*; do
    [ -f "$_f" ] && cp -f "$_f" "${_SUFFIX}/" 2>/dev/null || true
done

# Create syslinux.cfg (live.cfg equivalent for syslinux)
cat > "${_SUFFIX}/syslinux.cfg" << 'SYSLINUXCFG'
DEFAULT live
TIMEOUT 0
PROMPT 0

LABEL live
  MENU LABEL ^Live - Try Blinbuntu without installing
  LINUX /live/vmlinuz
  INITRD /live/initrd
  APPEND boot=live components quiet splash

LABEL live-install
  MENU LABEL ^Install Blinbuntu
  LINUX /live/vmlinuz
  INITRD /live/initrd
  APPEND boot=live components quiet splash preseed/file=/cdrom/preseed/blinbuntu.seed
SYSLINUXSCRIPT
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
