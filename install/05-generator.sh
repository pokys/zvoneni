#!/bin/bash
set -euo pipefail

GENERATOR="/usr/local/bin/generate-timers.sh"

cat > "$GENERATOR" <<'EOF'
#!/bin/bash
set -euo pipefail

SCHEDULE="/opt/zvoneni/schedule.txt"
SOUNDS_DIR="/opt/zvoneni/sounds"

# NOTE: the bell system is deliberately NOT stopped here. It is stopped
# further down, only once we know the schedule is valid AND something
# actually changed - otherwise a rejected schedule would leave the
# appliance silent.

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
# GENERATE UNITS INTO A STAGING DIR
# ------------------------------------------------------------
# Units are built in /run (tmpfs, i.e. RAM) and only copied onto the SD
# card when they actually differ from what is already installed. The
# generator runs on every boot, so unconditional rewrites would burn the
# card for nothing.
echo "[generator] generating timers"

STAGE=$(mktemp -d /run/zvoneni-gen.XXXXXX)
trap 'rm -rf "$STAGE"' EXIT

while read -r DAY TIME TYPE; do
  [[ -z "$DAY" ]] && continue
  [[ "$DAY" =~ ^# ]] && continue

  UNIT="zvoneni-${DAY}-${TIME//:/}"

  cat > "$STAGE/${UNIT}.service" <<EOL
[Unit]
Description=School bell ${DAY} ${TIME} (${TYPE})

[Service]
Type=oneshot
ExecStart=/bin/systemctl start zvoneni@${TYPE}.service
EOL

  cat > "$STAGE/${UNIT}.timer" <<EOL
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

shopt -s nullglob
staged_timers=("$STAGE"/*.timer)
shopt -u nullglob

if [ ${#staged_timers[@]} -eq 0 ]; then
  echo "[generator] no timers generated – no changes applied"
  exit 1
fi

# ------------------------------------------------------------
# DIFF AGAINST INSTALLED UNITS
# ------------------------------------------------------------
# Match ONLY generated per-bell units (zvoneni-Mon-0800 ...).
# A bare zvoneni-* glob would also match zvoneni-generator.service,
# i.e. the generator would touch its own boot unit.
INSTALLED_GLOB='/etc/systemd/system/zvoneni-[MTWF][a-z][a-z]-*'
WANTS_DIR="/etc/systemd/system/zvoneni.target.wants"

CHANGED=0

# new or modified units
for f in "$STAGE"/*; do
  cmp -s "$f" "/etc/systemd/system/$(basename "$f")" || CHANGED=1
done

# missing enable symlinks
for f in "${staged_timers[@]}"; do
  [ -L "$WANTS_DIR/$(basename "$f")" ] || CHANGED=1
done

# units on disk that the schedule no longer contains
shopt -s nullglob
stale=()
for f in ${INSTALLED_GLOB}.timer ${INSTALLED_GLOB}.service; do
  [ -e "$STAGE/$(basename "$f")" ] || stale+=("$f")
done
shopt -u nullglob
[ ${#stale[@]} -eq 0 ] || CHANGED=1

if [ "$CHANGED" -eq 0 ]; then
  echo "[generator] schedule unchanged – nothing written to disk"
  systemctl start zvoneni.target
  echo "[generator] done"
  exit 0
fi

# ------------------------------------------------------------
# APPLY
# ------------------------------------------------------------
echo "[generator] stopping bell system"
systemctl stop zvoneni.target 2>/dev/null || true

if [ ${#stale[@]} -gt 0 ]; then
  echo "[generator] removing ${#stale[@]} obsolete unit(s)"
  for f in "${stale[@]}"; do
    rm -f "$f" "$WANTS_DIR/$(basename "$f")"
  done
fi

WRITTEN=0
for f in "$STAGE"/*; do
  target="/etc/systemd/system/$(basename "$f")"
  if ! cmp -s "$f" "$target"; then
    cp "$f" "$target"
    WRITTEN=$((WRITTEN+1))
  fi
done
echo "[generator] wrote $WRITTEN unit file(s)"

echo "[generator] reloading systemd"
systemctl daemon-reload

echo "[generator] enabling timers"
for t in "${staged_timers[@]}"; do
  systemctl enable "$(basename "$t")"
done

echo "[generator] starting bell system"
systemctl start zvoneni.target

echo "[generator] done"
EOF

chmod +x "$GENERATOR"
