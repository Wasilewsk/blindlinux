# ─── Blind Linux Kickstart ───────────────────────────────────────────────────
# Fedora 44 live ISO with MATE desktop, Orca, accessibility-first.
# Based on vojtux approach using livemedia-creator.
# ──────────────────────────────────────────────────────────────────────────────

# Repositories
repo --name=fedora --mirrorlist=https://mirrors.fedoraproject.org/mirrorlist?repo=fedora-44&arch=x86_64
repo --name=updates --mirrorlist=https://mirrors.fedoraproject.org/mirrorlist?repo=updates-released-f44&arch=x86_64
url --mirrorlist=https://mirrors.fedoraproject.org/mirrorlist?repo=fedora-44&arch=x86_64

# RPM Fusion repos
repo --name=rpmfusion-free --mirrorlist=https://mirrors.rpmfusion.org/metalink?repo=free-fedora-44&arch=x86_64
repo --name=rpmfusion-free-updates --mirrorlist=https://mirrors.rpmfusion.org/metalink?repo=free-fedora-updates-released-44&arch=x86_64
repo --name=rpmfusion-nonfree --mirrorlist=https://mirrors.rpmfusion.org/metalink?repo=nonfree-fedora-44&arch=x86_64
repo --name=rpmfusion-nonfree-updates --mirrorlist=https://mirrors.rpmfusion.org/metalink?repo=nonfree-fedora-updates-released-44&arch=x86_64

# System
selinux --disabled
lang en_US.UTF-8
keyboard us
timezone UTC

group --name brlapi
services --enabled="chronyd,brltty"

rootpw --plaintext --lock blindlinux

part / --size 10240 --fstype ext4

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

# Hardware
@hardware-support
gutenprint-cups
cups-filters
foomatic-db
foomatic-db-ppds
splix
hplip
xorg-x11-drv-nouveau
libsane-hpaio

# Audio
pipewire-pulseaudio
pavucontrol
alsa-utils
sox
audacity
soundconverter
timidity++

# Accessibility
orca
espeak-ng
brltty
brltty-xw
speech-dispatcher-utils
a11y-sound-theme

# Display manager
-slick-greeter
-slick-greeter-mate
lightdm-gtk-greeter
lightdm-gtk-greeter-settings

# OCR
tesseract-langpack-eng
ocrmypdf

# Software
chromium
vlc
git
curl
wget
sed
nano
vim
less
tmux
unrar
pandoc

# Firmware
linux-firmware

# Fonts
dejavu-sans-fonts
dejavu-serif-fonts
google-noto-sans-fonts
google-noto-serif-fonts
%end

# ─── Post-Install ────────────────────────────────────────────────────────────
%post --log=/root/ks-post.log
set -e

# Create live user
useradd -c "Blind Linux User" -G wheel -m blindlinux
passwd -d blindlinux > /dev/null

# Set livesys session
sed -i 's/^livesys_session=.*/livesys_session="mate"/' /etc/sysconfig/livesys 2>/dev/null || true

# Configure speech dispatcher
sed -i 's/#AddModule "espeak-ng"/AddModule "espeak-ng"/' /etc/speech-dispatcher/speechd.conf 2>/dev/null || true

# Orca login wrapper
mkdir -p /usr/local/bin
cat > /usr/local/bin/orca-login-wrapper << 'EOM'
#!/bin/bash
amixer -c 0 set Master playback 50% unmute
/usr/bin/orca &
EOM
chmod 755 /usr/local/bin/orca-login-wrapper

# LightDM config
mkdir -p /etc/lightdm
cat >> /etc/lightdm/lightdm-gtk-greeter.conf << 'EOM'
[greeter]
background = /usr/share/backgrounds/default.png
reader = /usr/local/bin/orca-login-wrapper
a11y-states = +reader
EOM

# Autologin for installed system
cat >> /etc/lightdm/lightdm.conf << 'EOM'
[Seat:*]
autologin-user=blindlinux
autologin-session=mate
EOM

# Copy custom sounds
mkdir -p /usr/share/blindlinux
if [ -d "/tmp/blindlinux-sounds" ]; then
    cp /tmp/blindlinux-sounds/*.mp3 /usr/share/blindlinux/ 2>/dev/null || true
fi

# Install Porta-Bop game
if [ -f "/tmp/Porta-Bop v3.0 linux.tar.gz" ]; then
    mkdir -p /usr/share/blindlinux/games
    tar -xzf "/tmp/Porta-Bop v3.0 linux.tar.gz" -C /usr/share/blindlinux/games/ 2>/dev/null || true
fi

# Welcome script
cat > /usr/local/bin/blindlinux-welcome << 'UTILITY'
#!/bin/bash
echo "=== Welcome to Blind Linux ==="
echo "Screenreader: Orca (starts automatically)"
echo ""
echo "Quick tips:"
echo "  Insert+Space: Open Orca preferences"
echo "  Insert+H: Learn mode (help)"
echo "  Insert+F: Find on screen"
echo ""
echo "Sounds: /usr/share/blindlinux/"
echo "Porta-Bop: /usr/share/blindlinux/games/"
UTILITY
chmod +x /usr/local/bin/blindlinux-welcome

# Enable graphical target
systemctl set-default graphical.target

# Add user to groups
usermod -aG audio,video,input,bluetooth blindlinux 2>/dev/null || true

# MATE panel
mkdir -p /etc/dconf/db/local.d
cat > /etc/dconf/db/local.d/00-panel <<- EOM
[org/mate/panel/general]
object-id-list=['clock', 'menu-bar', 'volume-control', 'notification-area', 'show-desktop', 'window-list']
toplevel-id-list=['top', 'bottom']

[org/mate/panel/objects/show-desktop]
applet-iid='WnckletFactory::ShowDesktopApplet'
locked=true
object-type='applet'
position=0
toplevel-id='bottom'

[org/mate/panel/objects/window-list]
applet-iid='WnckletFactory::WindowListApplet'
locked=true
object-type='applet'
position=20
toplevel-id='bottom'

[org/mate/panel/objects/clock]
applet-iid='ClockAppletFactory::ClockApplet'
locked=true
object-type='applet'
panel-right-stick=true
position=0
toplevel-id='top'

[org/mate/panel/objects/menu-bar]
locked=true
object-type='menu-bar'
position=0
toplevel-id='top'

[org/mate/panel/objects/notification-area]
applet-iid='NotificationAreaAppletFactory::NotificationArea'
locked=true
object-type='applet'
panel-right-stick=true
position=10
toplevel-id='top'

[org/mate/panel/objects/volume-control]
applet-iid='GvcAppletFactory::GvcApplet'
locked=true
object-type='applet'
panel-right-stick=true
position=20
toplevel-id='top'
EOM
dconf update

echo "=== Post-install complete ==="
%end

# ─── Cleanup ─────────────────────────────────────────────────────────────────
%post --log=/root/ks-cleanup.log
dnf clean all
rm -rf /tmp/* /var/tmp/*
rm -rf /var/cache/dnf/*
%end
