#!/bin/bash
set -euo pipefail

GENERATOR="/usr/local/bin/generate-timers.sh"

cat > "$GENERATOR" <<'EOF'
#!/bin/bash
set -euo pipefail

SCHEDULE="/opt/zvoneni/schedule.txt"
SOUNDS_DIR="/opt/zvoneni/sounds"

echo "[generator] stopping bell system"
systemctl stop zvoneni.target 2>/dev/null || true

# ------------------------------------------------------------
# VALIDATION
# ------------------------------------------------------------
echo "[generator] validating schedule"

DAYS="Mon Tue Wed Thu Fri"
ERROR=0
lineno=0

AVAILABLE_SOUNDS=$(ls "$SOUNDS_DIR" | sed 's/\.wav$//')

while read -r line; do
  lineno=$((lineno+1))

  [[ -z "$line" ]] && continue
  [[ "$line" =~ ^# ]] && continue

  read -r DAY TIME TYPE <<<"$line"

  if [[ -z "${TYPE:-}" ]]; then
    echo "ERROR line $lineno: invalid format (need DAY TIME TYPE)"
    ERROR=1
    continue
  fi

  if ! echo "$DAYS" | grep -qw "$DAY"; then
    echo "ERROR line $lineno: invalid day '$DAY'"
    ERROR=1
  fi

  if ! [[ "$TIME" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
    echo "ERROR line $lineno: invalid time '$TIME'"
    ERROR=1
  fi

  if ! echo "$AVAILABLE_SOUNDS" | grep -qw "$TYPE"; then
    echo "ERROR line $lineno: sound '$TYPE' not found in $SOUNDS_DIR"
    ERROR=1
  fi

done < "$SCHEDULE"

if [ "$ERROR" -ne 0 ]; then
  echo
  echo "[generator] schedule validation FAILED – no changes applied"
  exit 1
fi

echo "[generator] validation OK"

# ------------------------------------------------------------
# CLEAN OLD UNITS
# ------------------------------------------------------------
echo "[generator] cleaning old timers"

rm -f /etc/systemd/system/zvoneni-*.timer
rm -f /etc/systemd/system/zvoneni-*.service
rm -f /etc/systemd/system/zvoneni.target.wants/zvoneni-*.timer

# ------------------------------------------------------------
# GENERATE UNITS
# ------------------------------------------------------------
echo "[generator] generating timers"

while read -r DAY TIME TYPE; do
  [[ -z "$DAY" ]] && continue
  [[ "$DAY" =~ ^# ]] && continue

  UNIT="zvoneni-${DAY}-${TIME//:/}"

  cat > "/etc/systemd/system/${UNIT}.service" <<EOL
[Unit]
Description=School bell ${DAY} ${TIME} (${TYPE})

[Service]
Type=oneshot
ExecStart=/usr/bin/aplay ${SOUNDS_DIR}/${TYPE}.wav
EOL

  cat > "/etc/systemd/system/${UNIT}.timer" <<EOL
[Unit]
Description=Timer for ${UNIT}

[Timer]
OnCalendar=${DAY} ${TIME}
Persistent=true

[Install]
WantedBy=zvoneni.target
EOL

done < "$SCHEDULE"

# ------------------------------------------------------------
# ENABLE + RELOAD
# ------------------------------------------------------------
echo "[generator] reloading systemd"
systemctl daemon-reload

echo "[generator] enabling timers"
for t in /etc/systemd/system/zvoneni-*.timer; do
  systemctl enable "$(basename "$t")"
done

echo "[generator] starting bell system"
systemctl start zvoneni.target

echo "[generator] done"
EOF

chmod +x "$GENERATOR"
