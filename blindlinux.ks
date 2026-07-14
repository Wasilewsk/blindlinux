# ─── Blind Linux Kickstart File ──────────────────────────────────────────────
# Fedora 44-based live ISO with MATE, Cthulhu screenreader,
# and accessibility-first design.
# ──────────────────────────────────────────────────────────────────────────────

# Use liveuser as the default user
liveuser --name=blindlinux --fullname="Blind Linux" --is-admin

# Locale and keyboard
lang en_US.UTF-8
keyboard --vckeymap=us
timezone UTC

# Network
network --bootproto=dhcp --activate --onboot=on --hostname=blindlinux

# Firewall (disable by default for live)
firewall --disabled

# SELinux (permissive for live)
selinux --permissive

# No bootloader needed for live ISO (ISOLINUX handles it)

# Disk image (live ISO uses tmpfs)
part / --size 4096 --fstype ext4 --ondisk=sda

# ─── Packages ────────────────────────────────────────────────────────────────
%packages
# Base
@core
kernel
dracut-live

# Desktop
@mate-desktop
@mate-applications
@input-methods

# Audio
pulseaudio
pulseaudio-utils
pavucontrol
alsamixer

# Accessibility
orca
espeak-ng
espeak-ng-server
espeak-ng-data
brltty
python3-brlapi

# Cthulhu screenreader runtime deps
python3-gobject
gtk3
at-spi2-core
at-spi2-atk
python3-speechd
python3-pluggy
python3-dasbus
gstreamer1-plugins-base
socat

# Cthulhu build deps (temporary, removed after build)
meson
ninja-build
pkgconf
intltool
gettext
git
gcc
python3-devel
gtk3-devel
at-spi2-core-devel
at-spi2-atk-devel
python3-gobject-devel

# Audio tools
sox
ffmpeg

# System
NetworkManager
chrony
plymouth
plymouth-theme-charge

# Firmware
linux-firmware

# Fonts
dejavu-fonts-common
dejavu-sans-fonts
dejavu-serif-fonts
google-noto-sans-fonts
google-noto-serif-fonts

# Tools
nano
vim
less
wget
curl
%end

# ─── Post-Install Scripts ────────────────────────────────────────────────────
%post --log=/root/ks-post.log
set -e

echo "=== Blind Linux post-install ==="

# Enable autologin
mkdir -p /etc/sddm.conf.d
cat > /etc/sddm.conf.d/autologin.conf << 'EOF'
[Autologin]
User=blindlinux
Session=mate.desktop
EOF

# Enable services
systemctl set-default graphical.target

# Install Cthulhu screenreader from source (meson build)
echo "Building Cthulhu screenreader..."
cd /tmp
git clone https://git.stormux.org/storm/cthulhu.git && cd cthulhu && {
    meson setup _build --prefix=/usr
    meson compile -C _build
    meson install -C _build
    cd /tmp
    rm -rf cthulhu
    echo "Cthulhu installed successfully."
} || echo "Cthulhu build failed, skipping"

# Install blindlinux utilities
mkdir -p /usr/local/bin

cat > /usr/local/bin/blindlinux-select-packages << 'UTILITY'
#!/bin/bash
echo "=== Blind Linux Package Selector ==="
echo "1. Accessibility (default)"
echo "2. Development"
echo "3. Office"
echo "4. All"
read -p "Selection [1]: " choice
choice=${choice:-1}
case $choice in
    1) echo "Accessibility packages selected" ;;
    2) dnf install -y gcc gcc-c++ make cmake git vim ;;
    3) dnf install -y libreoffice-calc libreoffice-writer libreoffice-impress ;;
    4) dnf install -y gcc gcc-c++ make cmake git vim libreoffice-calc libreoffice-writer libreoffice-impress ;;
    *) echo "Invalid choice" ;;
esac
UTILITY
chmod +x /usr/local/bin/blindlinux-select-packages

cat > /usr/local/bin/blindlinux-welcome << 'UTILITY'
#!/bin/bash
echo "=== Welcome to Blind Linux ==="
echo "This is an accessible Linux distribution."
echo "Screenreader: Orca (desktop), Cthulhu (desktop)"
echo "Press Enter to continue..."
read
echo "Running first-time setup..."
/usr/local/bin/blindlinux-select-packages
echo "Setup complete!"
UTILITY
chmod +x /usr/local/bin/blindlinux-welcome

cat > /usr/local/bin/blindlinux-postinstall << 'UTILITY'
#!/bin/bash
echo "=== Blind Linux Post-Install ==="
echo "Configuring accessibility..."
usermod -aG audio,video,input,bluetooth blindlinux 2>/dev/null || true
echo "Post-install complete."
UTILITY
chmod +x /usr/local/bin/blindlinux-postinstall

# Copy sound files if they exist in the build tree
if [ -d "/tmp/blindlinux-sounds" ]; then
    mkdir -p /home/blindlinux/.blindlinux
    cp /tmp/blindlinux-sounds/*.mp3 /home/blindlinux/.blindlinux/ 2>/dev/null || true
    chown -R blindlinux:blindlinux /home/blindlinux/.blindlinux
fi

# Copy Porta-Bop if it exists
if [ -f "/tmp/Porta-Bop v3.0 linux.tar.gz" ]; then
    mkdir -p /home/blindlinux/Games
    tar -xzf "/tmp/Porta-Bop v3.0 linux.tar.gz" -C /home/blindlinux/Games/ 2>/dev/null || true
    chown -R blindlinux:blindlinux /home/blindlinux/Games
fi

echo "=== Post-install complete ==="
%end

# ─── Cleanup ─────────────────────────────────────────────────────────────────
%post --log=/root/ks-cleanup.log
dnf remove -y git gcc make meson ninja-build pkgconf intltool gettext \
    python3-devel gtk3-devel at-spi2-core-devel at-spi2-atk-devel python3-gobject-devel 2>/dev/null || true
dnf clean all
rm -rf /tmp/* /var/tmp/*
rm -rf /var/cache/dnf/*
%end
