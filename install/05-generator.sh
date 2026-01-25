#!/bin/bash
set -e

cat > /usr/local/bin/generate-timers.sh <<'EOF'
#!/bin/bash
set -e

rm -f /etc/systemd/system/zvoneni-*.timer
rm -f /etc/systemd/system/zvoneni-*.service

while read day time type; do
  [[ -z "$day" || "$day" =~ ^# ]] && continue

  name="zvoneni-${day}-${time//:/}"

  cat > "/etc/systemd/system/${name}.timer" <<EOT
[Unit]
Description=Bell $day $time ($type)

[Timer]
OnCalendar=$day $time
AccuracySec=1s

[Install]
WantedBy=zvoneni.target
EOT

  cat > "/etc/systemd/system/${name}.service" <<EOT
[Service]
ExecStart=/usr/bin/systemctl start zvoneni@${type}.service
EOT

done < /opt/zvoneni/schedule.txt

systemctl daemon-reload
systemctl restart zvoneni.target
EOF

chmod +x /usr/local/bin/generate-timers.sh