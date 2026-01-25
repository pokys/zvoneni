#!/bin/bash
set -e

echo "[generator] installing generator script"

cat > /usr/local/bin/generate-timers.sh <<'EOF'
#!/bin/bash
set -e

SCHEDULE="/opt/zvoneni/schedule.txt"
SYSTEMD="/etc/systemd/system"
WANTS="$SYSTEMD/zvoneni.target.wants"

echo "[generator] stopping bell system"
systemctl stop zvoneni.target 2>/dev/null || true

echo "[generator] cleaning old timers"
rm -f "$SYSTEMD"/zvoneni-*.timer
rm -f "$SYSTEMD"/zvoneni-*.service
rm -f "$WANTS"/zvoneni-*.timer

echo "[generator] generating timers"

while read -r day time type; do
  [[ "$day" =~ ^#|^$ ]] && continue

  # normalize day (Mon Tue Wed ...)
  DAY=$(echo "$day" | tr '[:upper:]' '[:lower:]')
  DAY=${DAY^}

  NAME="zvoneni-${DAY}-${time//:/}"

  cat > "$SYSTEMD/$NAME.timer" <<TIMER
[Unit]
Description=School bell $DAY $time

[Timer]
OnCalendar=$DAY *-*-* $time:00
Persistent=true
Unit=$NAME.service

[Install]
WantedBy=zvoneni.target
TIMER

  cat > "$SYSTEMD/$NAME.service" <<SERVICE
[Unit]
Description=Play bell sound

[Service]
Type=oneshot
ExecStart=/usr/bin/aplay /opt/zvoneni/sounds/$type.wav
SERVICE

done < "$SCHEDULE"

echo "[generator] reloading systemd"
systemctl daemon-reload

echo "[generator] enabling timers"
for t in "$SYSTEMD"/zvoneni-*.timer; do
  systemctl enable "$(basename "$t")"
done

echo "[generator] starting bell system"
systemctl start zvoneni.target

echo "[generator] done"
EOF

chmod +x /usr/local/bin/generate-timers.sh
