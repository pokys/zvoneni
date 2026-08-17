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
# AMPLIFIER PRE-ROLL
# ------------------------------------------------------------
# The amplifier needs to be powered up before the bell, but the sound
# still has to start exactly at the scheduled time. So the timer itself
# is moved earlier by the pre-roll and zvoneni-ring sleeps it off.
AMP_ENABLED=0
AMP_PRE_SECONDS=0
if [ -x /usr/local/bin/zvoneni-amp ]; then
  eval "$(/usr/local/bin/zvoneni-amp config 2>/dev/null)" || true
fi

PRE=0
if [ "$AMP_ENABLED" -eq 1 ]; then
  PRE="$AMP_PRE_SECONDS"
  echo "[generator] amplifier pre-roll: ${PRE}s"
fi

# DAY HH:MM offset_seconds -> "DAY HH:MM:SS", borrowing into the previous
# day when the pre-roll crosses midnight (Mon 00:00 -> Sun 23:59:50).
# Removing a unit file is not enough: systemd keeps an already loaded unit
# around in the not-found/failed state, where it clutters list-timers for
# good. Clearing that state is a separate, explicit step.
clear_orphan_units() {
  local u
  systemctl list-units --all --plain --no-legend 'zvoneni-*' 2>/dev/null \
    | awk '$2 == "not-found" { print $1 }' \
    | while read -r u; do
        echo "[generator] clearing orphaned unit $u"
        systemctl reset-failed "$u" 2>/dev/null || true
      done
}

shift_time() {
  local day="$1" t="$2" off="$3" back=0 i
  local total=$(( 10#${t%%:*} * 3600 + 10#${t##*:} * 60 - off ))

  while [ "$total" -lt 0 ]; do
    total=$((total + 86400))
    back=$((back + 1))
  done

  local -a W=(Mon Tue Wed Thu Fri Sat Sun)
  for i in "${!W[@]}"; do
    if [ "${W[$i]}" = "$day" ]; then break; fi
  done

  printf '%s %02d:%02d:%02d\n' "${W[$(( (i - back + 7) % 7 ))]}" \
    $((total / 3600)) $((total % 3600 / 60)) $((total % 60))
}

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

  # Unit names stay keyed on the scheduled time, not the shifted one, so
  # changing the pre-roll does not churn every file name.
  UNIT="zvoneni-${DAY}-${TIME//:/}"
  CAL=$(shift_time "$DAY" "$TIME" "$PRE")

  cat > "$STAGE/${UNIT}.service" <<EOL
[Unit]
Description=School bell ${DAY} ${TIME} (${TYPE})

[Service]
Type=oneshot
ExecStart=/bin/systemctl start --no-block zvoneni@${TYPE}.service
EOL

  cat > "$STAGE/${UNIT}.timer" <<EOL
[Unit]
Description=Timer for ${UNIT} (fires ${CAL}, pre-roll ${PRE}s)

[Timer]
OnCalendar=${CAL}
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
# Match ONLY generated per-bell units: zvoneni-<Day>-<HHMM>. A bare
# zvoneni-* glob would also match zvoneni-generator.service and
# zvoneni-amp-reset.service, i.e. the generator would eat units it does
# not own. The day part is matched generically rather than against the
# five weekdays we accept today, so adding weekends later cannot leave
# orphaned units behind.
INSTALLED_GLOB='/etc/systemd/system/zvoneni-[A-Z][a-z][a-z]-[0-9][0-9][0-9][0-9]'
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
  clear_orphan_units
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
    unit=$(basename "$f")
    # Stop and disable while the file is still there, otherwise the unit
    # survives as a not-found/failed leftover once the file is gone.
    systemctl stop "$unit" 2>/dev/null || true
    systemctl disable "$unit" 2>/dev/null || true
    rm -f "$f" "$WANTS_DIR/$unit"
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

# Also catches leftovers from earlier versions, which removed unit files
# without ever stopping them.
clear_orphan_units

echo "[generator] enabling timers"
for t in "${staged_timers[@]}"; do
  systemctl enable "$(basename "$t")"
done

echo "[generator] starting bell system"
systemctl start zvoneni.target

echo "[generator] done"
EOF

chmod +x "$GENERATOR"

# ------------------------------------------------------------
# zvoneni-next-bell - when the next bell actually rings
# ------------------------------------------------------------
cat > /usr/local/bin/zvoneni-next-bell <<'EOF'
#!/bin/bash
# Print when the next bell rings, as "<timestamp> (in <duration>)".
#
# Timers fire AMP_PRE_SECONDS early so the amplifier can warm up, so the
# NEXT column of `systemctl list-timers` is the pre-roll moment, not the
# bell. Read the scheduled time from systemd and add the pre-roll back.
# Parsing list-timers columns is deliberately avoided: their layout has
# changed between systemd releases.
set -uo pipefail

PRE=0
if [ -x /usr/local/bin/zvoneni-amp ]; then
  AMP_ENABLED=0
  AMP_PRE_SECONDS=0
  eval "$(/usr/local/bin/zvoneni-amp config 2>/dev/null)" || true
  if [ "$AMP_ENABLED" -eq 1 ]; then
    PRE="$AMP_PRE_SECONDS"
  fi
fi

shopt -s nullglob
units=()
for t in /etc/systemd/system/zvoneni-[A-Z][a-z][a-z]-[0-9][0-9][0-9][0-9].timer; do
  units+=("$(basename "$t")")
done
shopt -u nullglob

if [ ${#units[@]} -eq 0 ]; then
  echo "-"
  exit 0
fi

# systemd 257 prints this property as a human timestamp ("Mon 2026-08-24
# 10:46:50 CEST"); older versions print raw microseconds. --timestamp=unix
# does not affect it. Accept whatever comes.
#
# Careful with the rejects: `date -d ""` and `date -d 0` both succeed and
# return today's midnight, so non-times have to be filtered before date
# ever sees them.
to_epoch() {
  local v="$1"
  case "$v" in
    ''|0|n/a|infinity) return 1 ;;
    @*)                v=${v#@}; [ -n "$v" ] || return 1; echo "$v" ;;
    *[!0-9]*)          date -d "$v" +%s 2>/dev/null || return 1 ;;
    *)                 echo $(( v / 1000000 )) ;;
  esac
}

BEST=
while IFS= read -r value; do
  epoch=$(to_epoch "$value") || continue
  [ -n "$epoch" ] || continue
  if [ -z "$BEST" ] || [ "$epoch" -lt "$BEST" ]; then
    BEST="$epoch"
  fi
done < <(systemctl show -p NextElapseUSecRealtime --value "${units[@]}" 2>/dev/null)

if [ -z "$BEST" ]; then
  echo "-"
  exit 0
fi

WHEN=$(( BEST + PRE ))
LEFT=$(( WHEN - $(date +%s) ))

if [ "$LEFT" -le 0 ]; then
  HUMAN="now"
elif [ "$LEFT" -ge 86400 ]; then
  HUMAN="$((LEFT / 86400))d $((LEFT % 86400 / 3600))h"
elif [ "$LEFT" -ge 3600 ]; then
  HUMAN="$((LEFT / 3600))h $((LEFT % 3600 / 60))min"
else
  HUMAN="$((LEFT / 60))min"
fi

echo "$(date -d "@$WHEN" '+%Y-%m-%d %H:%M:%S') (in $HUMAN)"
EOF

chmod +x /usr/local/bin/zvoneni-next-bell
