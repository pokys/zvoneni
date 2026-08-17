#!/bin/bash
set -e

cat > /etc/systemd/system/zvoneni-generator.service <<'EOF'
[Unit]
Description=Generate bell timers on boot
# Ordered before the target so stale timers from the previous schedule
# cannot activate and ring in the window before regeneration. The
# generator itself starts the target with --no-block, so this ordering
# cannot deadlock. No After=network.target - the generator only reads
# local files.
Before=zvoneni.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/generate-timers.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable zvoneni-generator.service
