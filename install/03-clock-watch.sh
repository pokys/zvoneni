#!/bin/bash
set -e

cat > /usr/local/bin/clock-watch.sh <<'EOF'
#!/bin/bash
set -e

GATE="/run/clock-ok"
MAX_WAIT=180   # 3 minuty
START=$(date +%s)

# Pokud už jednou povoleno, nikdy znovu neblokuj
[ -f "$GATE" ] && exit 0

echo "[clock-watch] waiting for time sync"

while true; do
  if timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -q yes; then
    echo "[clock-watch] time synchronized"
    touch "$GATE"
    exit 0
  fi

  NOW=$(date +%s)
  if (( NOW - START > MAX_WAIT )); then
    echo "[clock-watch] timeout reached, allowing bells anyway"
    touch "$GATE"
    exit 0
  fi

  sleep 10
done
EOF

chmod +x /usr/local/bin/clock-watch.sh

cat > /etc/systemd/system/clock-watch.service <<EOF
[Unit]
Description=Clock state watchdog
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/clock-watch.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF