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
VALID_COUNT=0
lineno=0

if [ ! -d "$SOUNDS_DIR" ]; then
  echo "ERROR: sounds directory not found: $SOUNDS_DIR"
  exit 1
fi

shopt -s nullglob
sound_files=("$SOUNDS_DIR"/*.wav)
shopt -u nullglob

if [ ${#sound_files[@]} -eq 0 ]; then
  echo "ERROR: no sounds found in $SOUNDS_DIR"
  exit 1
fi

AVAILABLE_SOUNDS=""
for f in "${sound_files[@]}"; do
  name=$(basename "$f" .wav)
  AVAILABLE_SOUNDS="${AVAILABLE_SOUNDS}${name}"$'\n'
done

while read -r line; do
  lineno=$((lineno+1))

  [[ -z "$line" ]] && continue
  [[ "$line" =~ ^[[:space:]]*# ]] && continue

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

  if [ "$ERROR" -eq 0 ]; then
    VALID_COUNT=$((VALID_COUNT+1))
  fi

done < "$SCHEDULE"

if [ "$ERROR" -ne 0 ]; then
  echo
  echo "[generator] schedule validation FAILED – no changes applied"
  exit 1
fi

if [ "$VALID_COUNT" -eq 0 ]; then
  echo
  echo "[generator] schedule is empty – no changes applied"
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
ExecStart=/bin/systemctl start zvoneni@${TYPE}.service
EOL

  cat > "/etc/systemd/system/${UNIT}.timer" <<EOL
[Unit]
Description=Timer for ${UNIT}

[Timer]
OnCalendar=${DAY} ${TIME}
AccuracySec=1s
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
shopt -s nullglob
timers=(/etc/systemd/system/zvoneni-*.timer)
shopt -u nullglob

if [ ${#timers[@]} -eq 0 ]; then
  echo "[generator] no timers generated – no changes applied"
  exit 1
fi

for t in "${timers[@]}"; do
  systemctl enable "$(basename "$t")"
done

echo "[generator] starting bell system"
systemctl start zvoneni.target

echo "[generator] done"
EOF

chmod +x "$GENERATOR"
