#!/bin/bash
set -euo pipefail

# ─── Blind Linux Build Script ────────────────────────────────────────────────
# Builds a Fedora 44-based live ISO using livemedia-creator.
# Based on vojtux approach.
# ──────────────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KS_FILE="${SCRIPT_DIR}/blindlinux.ks"
ISO_NAME="blindlinux-44-x86_64.iso"
TMPDIR="${SCRIPT_DIR}/live/tmp"
FEDORA_RELEASE="44"

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
        lorax-lmc-novirt \
        pykickstart \
        squashfs-tools \
        xorriso \
        syslinux \
        mtools \
        dosfstools \
        git \
        wget
    ok "Dependencies installed."
}

copy_assets() {
    info "Copying assets to staging area..."
    rm -rf /tmp/blindlinux-sounds
    mkdir -p /tmp/blindlinux-sounds
    cp "${SCRIPT_DIR}/start.mp3" "${SCRIPT_DIR}/logon.mp3" "${SCRIPT_DIR}/livestart.mp3" /tmp/blindlinux-sounds/ 2>/dev/null || warn "Sound files not found"
    cp "${SCRIPT_DIR}/Porta-Bop v3.0 linux.tar.gz" /tmp/ 2>/dev/null || warn "Porta-Bop tarball not found"
}

build() {
    copy_assets

    info "Building Blind Linux ISO (Fedora ${FEDORA_RELEASE})..."
    mkdir -p "${TMPDIR}"

    livemedia-creator \
        --make-iso \
        --no-virt \
        --iso-only \
        --iso-name="${ISO_NAME}" \
        --project="Blind Linux" \
        --releasever="${FEDORA_RELEASE}" \
        --ks="${KS_FILE}" \
        --tmp="${TMPDIR}" \
        --anaconda-arg="--noselinux" \
        2>&1 | tee "${SCRIPT_DIR}/build.log"

    ISO_FILE="${TMPDIR}/${ISO_NAME}"
    if [ -f "${ISO_FILE}" ]; then
        cp "${ISO_FILE}" "${SCRIPT_DIR}/"
        ok "ISO: ${SCRIPT_DIR}/${ISO_FILE}"
        sha256sum "${SCRIPT_DIR}/${ISO_FILE}" > "${SCRIPT_DIR}/${ISO_FILE}.sha256"
        ok "Checksum: ${SCRIPT_DIR}/${ISO_FILE}.sha256"
    else
        err "No ISO file found after build."
        exit 1
    fi
}

clean() {
    info "Cleaning build artifacts..."
    rm -rf "${SCRIPT_DIR}/live" "${SCRIPT_DIR}/build.log"
    rm -f "${SCRIPT_DIR}/blindlinux-"*.iso "${SCRIPT_DIR}/blindlinux-"*.iso.sha256
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
