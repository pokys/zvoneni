#!/bin/bash
set -e

cat > /etc/systemd/system/zvoneni.target <<'EOF'
[Unit]
Description=School Bell System

[Install]
WantedBy=multi-user.target
EOF
