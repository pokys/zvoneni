#!/bin/bash
set -e

cat > /etc/systemd/system/zvoneni@.service <<'EOF'
[Unit]
Description=School bell (%i)
ConditionPathExists=/run/clock-ok
ConditionPathExists=/opt/zvoneni/sounds/%i.wav

[Service]
Type=oneshot
ExecStart=/usr/bin/aplay /opt/zvoneni/sounds/%i.wav
EOF