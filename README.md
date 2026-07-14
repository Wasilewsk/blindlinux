# Blind Linux

An accessible Linux distribution built on Fedora 44 with MATE desktop and screenreader-first design.

## Features

- **MATE Desktop** - Lightweight, accessible desktop environment
- **Orca Screenreader** - Full desktop screenreading support
- **Cthulhu Screenreader** - Additional screenreader built from source
- **BRLTTY** - Braille display support
- **Auto-login** - Boots straight to desktop
- **ESpeak-ng** - Text-to-speech engine
- **Porta-Bop** - Bundled audio game

## Building

Requires a Fedora machine (or VM) with root access.

```bash
# Install dependencies
sudo ./build.sh deps

# Build the ISO
sudo ./build.sh build
```

The ISO will be created in the current directory.

## CI/CD

Pushes to `main`/`master` trigger a GitHub Actions build using a Fedora container. The ISO is uploaded as an artifact. Tagged pushes create draft releases.

## Project Structure

```
blindlinux.ks              # Fedora kickstart file
build.sh                   # Build script
.github/workflows/build.yml # CI workflow
start.mp3                  # Startup sound
logon.mp3                  # Login sound
livestart.mp3              # Live session sound
Porta-Bop v3.0 linux.tar.gz # Audio game
```
