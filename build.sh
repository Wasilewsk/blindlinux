#!/bin/bash
set -euo pipefail

# ─── Blind Linux Build Script ────────────────────────────────────────────────
# Builds a Fedora 44-based live ISO with MATE, Cthulhu screenreader,
# and accessibility-first design.
# Uses livecd-creator (Fedora's live ISO tool).
# ──────────────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KS_FILE="${SCRIPT_DIR}/blindlinux.ks"
ISO_LABEL="BlindLinux"
FEDORA_RELEASE="44"

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

if [ "$EUID" -ne 0 ]; then
    err "This script must be run as root (use sudo)."
    exit 1
fi

install_deps() {
    info "Installing build dependencies..."
    dnf install -y \
        livecd-tools \
        squashfs-tools \
        xorriso \
        syslinux \
        isolinux \
        mtools \
        dosfstools \
        git \
        wget
    ok "Dependencies installed."
}

build() {
    info "Copying assets to staging area..."
    rm -rf /tmp/blindlinux-sounds
    mkdir -p /tmp/blindlinux-sounds
    cp "${SCRIPT_DIR}/start.mp3" "${SCRIPT_DIR}/logon.mp3" "${SCRIPT_DIR}/livestart.mp3" /tmp/blindlinux-sounds/ 2>/dev/null || warn "Sound files not found"
    cp "${SCRIPT_DIR}/Porta-Bop v3.0 linux.tar.gz" /tmp/ 2>/dev/null || warn "Porta-Bop tarball not found"

    info "Building Blind Linux ISO (Fedora ${FEDORA_RELEASE})..."
    livecd-creator \
        --file-config="${KS_FILE}" \
        --fslabel="${ISO_LABEL}" \
        --title="Blind Linux" \
        --project="Blind Linux - Accessible Linux" \
        --publisher="Blind Linux" \
        --releasever="${FEDORA_RELEASE}" \
        --no-virt \
        2>&1 | tee "${SCRIPT_DIR}/build.log"
    ok "Build complete."

    ISO_FILE=$(find "${SCRIPT_DIR}" -maxdepth 1 -name "${ISO_LABEL}*.iso" -type f | head -1)
    if [ -n "${ISO_FILE}" ]; then
        ok "ISO: ${ISO_FILE}"
        sha256sum "${ISO_FILE}" > "${ISO_FILE}.sha256"
        ok "Checksum: ${ISO_FILE}.sha256"
    else
        err "No ISO file found after build."
        exit 1
    fi
}

clean() {
    info "Cleaning build artifacts..."
    rm -f "${SCRIPT_DIR}/${ISO_LABEL}"*.iso "${SCRIPT_DIR}/${ISO_LABEL}"*.iso.sha256
    rm -f "${SCRIPT_DIR}/build.log"
    ok "Clean complete."
}

case "${1:-build}" in
    deps)   install_deps ;;
    build)  install_deps; build ;;
    clean)  clean ;;
    *)
        echo "Usage: $0 {deps|build|clean}"
        exit 1
        ;;
esac
