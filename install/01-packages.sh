#!/bin/bash
set -e

apt update
apt install -y dialog alsa-utils nano

# pinctrl drives the amplifier GPIO. It ships with Raspberry Pi OS (Bookworm
# and Trixie alike), so this is only a safety net for slimmed-down images.
# Deliberately non-fatal: if the package is unavailable the install must
# still finish, and zvoneni-amp reports the missing tool at runtime.
if ! command -v pinctrl >/dev/null 2>&1; then
  apt install -y raspi-utils || echo "[install] WARNING: pinctrl not available - amplifier switching will not work"
fi