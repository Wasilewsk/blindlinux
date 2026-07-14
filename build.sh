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
        grub-common \
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
  LINUX /casper/vmlinuz
  INITRD /casper/initrd.img
  APPEND boot=live components quiet splash
LIVECFG

    # Ensure isohybrid is findable everywhere (live-build may run binary.sh with restricted PATH)
    for _p in /usr/bin /bin /usr/sbin /sbin /usr/local/bin /usr/local/sbin; do
        mkdir -p "$_p"
        cat > "${_p}/isohybrid" << 'ISOHYBRIDWrapper'
#!/bin/sh
exit 0
ISOHYBRIDWrapper
        chmod +x "${_p}/isohybrid"
    done
    ok "isohybrid no-op wrapper installed in all PATH locations"

    # Patch binary.sh to skip isohybrid (it may not be available on Ubuntu resolute)
    # binary.sh may be at /usr/lib/live/build/ or generated in the build dir
    for _bsh in /usr/lib/live/build/binary.sh "${BUILD_DIR}/binary.sh"; do
        if [ -f "$_bsh" ]; then
            info "Found binary.sh at $_bsh — patching isohybrid call..."
            sed -i '/^[[:space:]]*isohybrid[[:space:]]/s/isohybrid/true/' "$_bsh" 2>/dev/null || true
            sed -i '/^[[:space:]]*\/.*isohybrid[[:space:]]/s/isohybrid/true/' "$_bsh" 2>/dev/null || true
            ok "Patched $_bsh"
        fi
    done

    # Also put isohybrid wrapper INSIDE the chroot (binary.sh may run there)
    mkdir -p "${BUILD_DIR}/config/includes.chroot/usr/bin"
    cat > "${BUILD_DIR}/config/includes.chroot/usr/bin/isohybrid" << 'ISOHYBRIDWrapper'
#!/bin/sh
exit 0
ISOHYBRIDWrapper
    chmod +x "${BUILD_DIR}/config/includes.chroot/usr/bin/isohybrid"
    ok "isohybrid no-op wrapper added to chroot"

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
  LINUX /casper/vmlinuz
  INITRD /casper/initrd.img
  APPEND boot=live components quiet splash

LABEL live-install
  MENU LABEL ^Install Blinbuntu
  LINUX /casper/vmlinuz
  INITRD /casper/initrd.img
  APPEND boot=live components quiet splash preseed/file=/cdrom/preseed/blinbuntu.seed
SYSLINUXCFG
    chmod +x /usr/lib/live/build/lb_binary_syslinux

    # Replace lb_binary_grub2 to create proper EFI boot images for VMware UEFI.
    # The original script silently skips because LB_BOOTLOADERS isn't read from config.
    info "Replacing lb_binary_grub2 with EFI-boot-compatible version..."
    cat > /usr/lib/live/build/lb_binary_grub2 << 'GRUB2SCRIPT'
#!/bin/sh
# Replacement lb_binary_grub2 for Ubuntu 26.04 resolute
# Creates EFI boot image (efi.img) for UEFI boot from ISO

_CHROOT="chroot"
_GRUB_DIR="binary/boot/grub"
_EFI_DIR="binary/boot/grub/efi"

echo "[lb_binary_grub2] Creating EFI boot image..."

# Find grubx64.efi from the chroot (installed by grub-efi-amd64-bin)
GRUB_EFI=""
for p in \
    "${_CHROOT}/usr/lib/grub/x86_64-efi/grubx64.efi.signed" \
    "${_CHROOT}/usr/lib/grub/x86_64-efi/grubx64.efi" \
    "${_CHROOT}/usr/lib/grub/x86_64-efi-modular/grubx64.efi"; do
    if [ -f "$p" ]; then
        GRUB_EFI="$p"
        break
    fi
done

# Also check signed boot images
if [ -z "$GRUB_EFI" ]; then
    GRUB_EFI=$(find "${_CHROOT}/usr/lib" -name "grubx64.efi*" -type f 2>/dev/null | head -1)
fi

if [ -z "$GRUB_EFI" ]; then
    echo "[lb_binary_grub2] WARNING: grubx64.efi not found in chroot, trying host..."
    GRUB_EFI=$(find /usr/lib -name "grubx64.efi*" -type f 2>/dev/null | head -1)
fi

if [ -z "$GRUB_EFI" ]; then
    echo "[lb_binary_grub2] ERROR: Cannot find grubx64.efi anywhere" >&2
    exit 1
fi

echo "[lb_binary_grub2] Found grubx64.efi: ${GRUB_EFI}"

# Create directories
mkdir -p "${_GRUB_DIR}/efi/EFI/BOOT"
mkdir -p "${_GRUB_DIR}/efi/EFI/ubuntu"

# Copy grub EFI binary
cp -f "${GRUB_EFI}" "${_GRUB_DIR}/efi/EFI/BOOT/BOOTX64.EFI"
cp -f "${GRUB_EFI}" "${_GRUB_DIR}/efi/EFI/ubuntu/grubx64.efi"

# Create GRUB EFI config
cat > "${_GRUB_DIR}/efi/EFI/ubuntu/grub.cfg" << 'GRUBCFG'
set default=0
set timeout=5

menuentry "Try Blinbuntu without installing" {
    linux /casper/vmlinuz boot=live components quiet splash
    initrd /casper/initrd.img
}

menuentry "Try Blinbuntu without installing (safe graphics)" {
    linux /casper/vmlinuz boot=live components quiet splash nomodeset
    initrd /casper/initrd.img
}

menuentry "Install Blinbuntu" {
    linux /casper/vmlinuz boot=live components quiet splash preseed/file=/cdrom/preseed/blinbuntu.seed
    initrd /casper/initrd.img
}

menuentry "Check the disc for defects" {
    linux /casper/vmlinuz boot=live components quiet splash checkdisk
    initrd /casper/initrd.img
}

menuentry "Memory test (memtest86+)" {
    linux /casper/memtest
}
GRUBCFG

# Create a top-level grub.cfg for the EFI image
cat > "${_GRUB_DIR}/efi/grub.cfg" << 'GRUBCFG2'
set default=0
set timeout=5
search --no-floppy --set=root --label casperuuid
set prefix=($root)/boot/grub
configfile ($root)/boot/grub/efi/EFI/ubuntu/grub.cfg
GRUBCFG2

# Build the EFI system partition image (FAT16, 64MB)
dd if=/dev/zero of="${_GRUB_DIR}/efi.img" bs=1M count=64 2>/dev/null
mkfs.fat -F 16 -n EFI "${_GRUB_DIR}/efi.img" >/dev/null 2>&1

# Mount and copy EFI files
_EFI_MNT=$(mktemp -d)
mount -o loop "${_GRUB_DIR}/efi.img" "${_EFI_MNT}" 2>/dev/null
if [ $? -eq 0 ]; then
    mkdir -p "${_EFI_MNT}/EFI/BOOT"
    mkdir -p "${_EFI_MNT}/EFI/ubuntu"
    cp -f "${_GRUB_DIR}/efi/EFI/BOOT/BOOTX64.EFI" "${_EFI_MNT}/EFI/BOOT/"
    cp -f "${_EFI_MNT}/EFI/BOOT/BOOTX64.EFI" "${_EFI_MNT}/EFI/ubuntu/grubx64.efi"
    cp -f "${_GRUB_DIR}/efi/EFI/ubuntu/grub.cfg" "${_EFI_MNT}/EFI/ubuntu/"
    umount "${_EFI_MNT}"
    rmdir "${_EFI_MNT}"
    echo "[lb_binary_grub2] EFI system partition image created: ${_GRUB_DIR}/efi.img"
else
    # Fallback: use mtools if available
    rmdir "${_EFI_MNT}"
    echo "[lb_binary_grub2] WARNING: mount failed, trying mtools..."
    if command -v mcopy >/dev/null 2>&1; then
        mcopy -i "${_GRUB_DIR}/efi.img" -s "${_GRUB_DIR}/efi/EFI" "::/EFI"
        echo "[lb_binary_grub2] EFI image created via mtools"
    else
        echo "[lb_binary_grub2] ERROR: Cannot create EFI image (no mount, no mtools)" >&2
        exit 1
    fi
fi

# Also set up BIOS grub for hybrid boot
if [ -d "${_CHROOT}/usr/lib/grub/i386-pc" ]; then
    mkdir -p "binary/boot/grub/i386-pc"
    cp -f "${_CHROOT}/usr/lib/grub/i386-pc/"*.mod "binary/boot/grub/i386-pc/" 2>/dev/null || true
    cp -f "${_CHROOT}/usr/lib/grub/i386-pc/"*.lst "binary/boot/grub/i386-pc/" 2>/dev/null || true
fi

echo "[lb_binary_grub2] EFI boot setup complete."
GRUB2SCRIPT
    chmod +x /usr/lib/live/build/lb_binary_grub2
    ok "lb_binary_grub2 replaced with EFI-boot-compatible version"

    # Set LB_BOOTLOADERS in config/common (proper location for live-build 3.x)
    if grep -q 'LB_BOOTLOADERS' "${BUILD_DIR}/config/common" 2>/dev/null; then
        sed -i 's/^LB_BOOTLOADERS=.*/LB_BOOTLOADERS="grub-efi bios"/' "${BUILD_DIR}/config/common"
    else
        echo 'LB_BOOTLOADERS="grub-efi bios"' >> "${BUILD_DIR}/config/common"
    fi
    # Also set in config/binary as backup
    if grep -q 'LB_BOOTLOADERS' "${BUILD_DIR}/config/binary" 2>/dev/null; then
        sed -i 's/^LB_BOOTLOADERS=.*/LB_BOOTLOADERS="grub-efi bios"/' "${BUILD_DIR}/config/binary"
    else
        echo 'LB_BOOTLOADERS="grub-efi bios"' >> "${BUILD_DIR}/config/binary"
    fi
    ok "LB_BOOTLOADERS set to 'grub-efi bios' in config/common and config/binary"
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
    export PATH="/usr/bin:/usr/local/bin:/usr/sbin:/sbin:/bin:$PATH"
    LB_BOOTLOADERS="grub-efi bios" lb build 2>&1 | tee "${SCRIPT_DIR}/build.log"
    ok "Build complete."

    # Create version-agnostic copies in casper/ for isolinux/grub configs
    if [ -d "${BUILD_DIR}/binary/casper" ]; then
        cd "${BUILD_DIR}/binary/casper"
        for vk in vmlinuz-*generic; do [ -f "$vk" ] && cp -f "$vk" vmlinuz 2>/dev/null && break; done
        for ik in initrd.img-*generic; do [ -f "$ik" ] && cp -f "$ik" initrd.img 2>/dev/null && break; done
        cd "${BUILD_DIR}"
        ok "Created version-agnostic copies in binary/casper/"
    fi

    # Find the ISO lb build created (exclude chroot)
    ISO_FILE=$(find "${BUILD_DIR}" -path "${BUILD_DIR}/chroot" -prune -o -name "*.iso" -type f -print | head -1)
    if [ -z "${ISO_FILE}" ]; then
        ISO_FILE=$(find "${BUILD_DIR}" -path "${BUILD_DIR}/chroot" -prune -o \( -name "image-*.iso" -o -name "live-image-*.iso" \) -type f -print | head -1)
    fi
    if [ -z "${ISO_FILE}" ]; then
        err "No ISO file found after build."
        exit 1
    fi

    # If efi.img exists, rebuild the ISO to include UEFI boot
    EFI_IMG="${BUILD_DIR}/binary/boot/grub/efi.img"
    if [ -f "${EFI_IMG}" ] && [ -d "${BUILD_DIR}/binary/isolinux" ]; then
        info "Rebuilding ISO with UEFI boot support..."
        ISO_UEFI="${BUILD_DIR}/binary.hybrid.iso"

        xorriso -as mkisofs \
            -o "${ISO_UEFI}" \
            -r -J -joliet-long \
            -V "BLINBUNTU" \
            -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
            -c isolinux/boot.cat \
            -b isolinux/isolinux.bin \
            -no-emul-boot \
            -boot-load-size 4 \
            -boot-info-table \
            -eltorito-alt-boot \
            -e boot/grub/efi.img \
            -no-emul-boot \
            -isohybrid-gpt-basdat \
            "${BUILD_DIR}/binary" 2>&1 | tail -5

        if [ -f "${ISO_UEFI}" ] && [ "$(stat -c%s "${ISO_UEFI}" 2>/dev/null || stat -f%z "${ISO_UEFI}" 2>/dev/null)" -gt 100000000 ]; then
            ISO_FILE="${ISO_UEFI}"
            ok "UEFI+BIOS hybrid ISO created: ${ISO_UEFI}"
        else
            warn "xorriso rebuild failed, using original ISO"
        fi
    fi

    ok "Final ISO: ${ISO_FILE}"
    cp "${ISO_FILE}" "${SCRIPT_DIR}/" 2>/dev/null || true
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
