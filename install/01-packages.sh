#!/bin/bash
set -e

apt update
apt install -y dialog alsa-utils nano

# pinctrl drives the amplifier GPIO. It ships with Raspberry Pi OS Bookworm,
# so this is only a safety net for slimmed-down images.
command -v pinctrl >/dev/null 2>&1 || apt install -y raspi-utils