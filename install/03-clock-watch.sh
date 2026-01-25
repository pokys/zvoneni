#!/bin/bash
set -e

cat > /usr/local/bin/clock-watch.sh <<'EOF'
#!/bin/bash
GATE="/run/clock-ok"
MIN_UPTIME=300

while true; do
  uptime=$(cut -d. -f1 /proc/uptime)
  ntp=$(timedatectl show -p NTPSynchronized --value 2>/dev/null)

  if [ "$ntp" = "yes" ] || [ "$uptime" -ge "$MIN_UPTIME" ]; then
    touch "$GATE"
  else
    rm -f "$GATE"
  fi

  sleep 10
done
EOF

chmod +x /usr/local/bin/clock-watch.sh

cat > /etc/systemd/system/clock-watch.service <<EOF
[Unit]
Description=Clock state watchdog
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/clock-watch.sh
Restart=always

[Install]
WantedBy=multi-user.target
EOF