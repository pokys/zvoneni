#!/bin/bash
set -e

cat > /etc/systemd/system/zvoneni-generator.service <<'EOF'
[Unit]
Description=Generate bell timers on boot
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/generate-timers.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable zvoneni-generator.service
