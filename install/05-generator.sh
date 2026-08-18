#!/bin/bash
set -euo pipefail

GENERATOR="/usr/local/bin/generate-timers.sh"

cat > "$GENERATOR" <<'EOF'
#!/bin/bash
set -euo pipefail

SCHEDULE="/opt/zvoneni/schedule.txt"
SOUNDS_DIR="/opt/zvoneni/sounds"

# Everything below mutates /etc/systemd - fail with a clear message
# instead of a raw mktemp/permission error several steps in.
if [ "$(id -u)" -ne 0 ]; then
  echo "generate-timers.sh: run as root, e.g. sudo generate-timers.sh" >&2
  exit 1
fi

# NOTE: the bell system is deliberately NOT stopped here. It is stopped
# further down, only once we know the schedule is valid AND something
# actually changed - otherwise a rejected schedule would leave the
# appliance silent.

# ------------------------------------------------------------
# VALIDATION
# ------------------------------------------------------------
echo "[generator] validating schedule"

# The schedule is read twice (validate, then generate). Snapshot it first
# so a concurrent edit between the passes cannot smuggle unvalidated
# content into the generated units.
SNAP=$(mktemp /run/zvoneni-schedule.XXXXXX)
trap 'rm -f "$SNAP"' EXIT
cat "$SCHEDULE" > "$SNAP"
SCHEDULE="$SNAP"

# The full week, deliberately - not a leftover of a weekday-only design.
# Everything downstream (shift_time's day array, the unit name glob,
# OnCalendar itself) already handles Sat/Sun; this was the only gate.
valid_day() {
  case "$1" in
    Mon|Tue|Wed|Thu|Fri|Sat|Sun) return 0 ;;
    *) return 1 ;;
  esac
}

ERROR=0
VALID_COUNT=0
lineno=0
SEEN_SLOTS=""

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

  # Exact match, not grep: a regexy value like "M.n" used to slip through
  # a grep -w check and then mis-plan in shift_time.
  if ! valid_day "$DAY"; then
    echo "ERROR line $lineno: invalid day '$DAY' (use Mon..Sun)"
    ERROR=1
  fi

  if ! [[ "$TIME" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
    echo "ERROR line $lineno: invalid time '$TIME'"
    ERROR=1
  fi

  # TYPE becomes part of a path and a unit name - constrain the format,
  # then check the actual file (grep -w against a list accepted "foo"
  # when only foo-bar.wav existed).
  if ! [[ "$TYPE" =~ ^[A-Za-z0-9_-]+$ ]]; then
    echo "ERROR line $lineno: invalid sound name '$TYPE' (letters, digits, - and _ only)"
    ERROR=1
  elif [ ! -f "$SOUNDS_DIR/$TYPE.wav" ]; then
    echo "ERROR line $lineno: sound '$TYPE' not found in $SOUNDS_DIR"
    ERROR=1
  fi

  # Two lines with the same DAY+TIME would silently overwrite each other's
  # generated unit (the name is keyed on the slot) - refuse instead.
  if echo "$SEEN_SLOTS" | grep -qx "$DAY $TIME"; then
    echo "ERROR line $lineno: duplicate bell at $DAY $TIME"
    ERROR=1
  fi
  SEEN_SLOTS="${SEEN_SLOTS}${DAY} ${TIME}"$'\n'

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
#
# The timers below do NOT set Persistent=true, on purpose. That directive
# makes systemd fire a timer immediately if it judges the current week's
# slot already elapsed - and that check re-runs whenever the unit's
# OnCalendar is reloaded, not only after a real power outage. Changing
# ANY amplifier setting recomputes OnCalendar for every bell (the pre-roll
# shifts them all), so saving a setting after today's bell had already
# rung made it ring again right there in the TUI. A school bell that is
# late should be skipped, not rung out of context mid-lesson, so this
# stays off rather than trying to distinguish "missed by an outage" from
# "moved by an edit".
echo "[generator] generating timers"

STAGE=$(mktemp -d /run/zvoneni-gen.XXXXXX)
trap 'rm -rf "$STAGE"; rm -f "$SNAP"' EXIT

while read -r DAY TIME TYPE; do
  [[ -z "$DAY" ]] && continue
  [[ "$DAY" =~ ^# ]] && continue

  # Unit names stay keyed on the scheduled time, not the shifted one, so
  # changing the pre-roll does not churn every file name.
  UNIT="zvoneni-${DAY}-${TIME//:/}"
  CAL=$(shift_time "$DAY" "$TIME" "$PRE")

  # The slot unit runs zvoneni-ring directly rather than delegating to
  # the zvoneni@TYPE template. Two bells of the same TYPE overlapping
  # (long pre-roll or a long wav) would share one template instance, and
  # `systemctl start` on an already-active unit is a no-op - the second
  # bell was silently skipped. Distinct units per slot, each holding the
  # amplifier under its own name. zvoneni@ stays for manual/TUI tests.
  cat > "$STAGE/${UNIT}.service" <<EOL
[Unit]
Description=School bell ${DAY} ${TIME} (${TYPE})
ConditionPathExists=/run/clock-ok
ConditionPathExists=/opt/zvoneni/sounds/${TYPE}.wav

[Service]
Type=oneshot
TimeoutStartSec=900
ExecStart=/usr/local/bin/zvoneni-ring ${TYPE} ring-${DAY}-${TIME//:/}
ExecStopPost=/usr/local/bin/zvoneni-amp off ring-${DAY}-${TIME//:/}
EOL

  cat > "$STAGE/${UNIT}.timer" <<EOL
[Unit]
Description=Timer for ${UNIT} (fires ${CAL}, pre-roll ${PRE}s)

[Timer]
OnCalendar=${CAL}
AccuracySec=1s
# No Persistent=true - a missed bell is skipped, not rung late. See
# 05-generator.sh for why.

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
  # --no-block everywhere the generator starts the target: at boot this
  # script runs Before=zvoneni.target, so a blocking start of that very
  # target would deadlock until the job timeout.
  systemctl start --no-block zvoneni.target
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
systemctl start --no-block zvoneni.target

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
  # ${t##*/} rather than basename: this runs once per timer, and a full
  # schedule is 80 of them - that was 80 forks per menu redraw.
  units+=("${t##*/}")
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
# Split the values by shape first, without spawning anything: numeric
# forms are converted in the shell, and the human timestamps are handed
# to ONE `date -f -` instead of one `date -d` per timer. With a full
# 80-bell schedule that was 80 forks - measured at 0.175s against 0.004s
# for the batched call, on every single menu redraw.
BEST=
HUMAN_VALS=""

while IFS= read -r value; do
  case "$value" in
    ''|0|n/a|infinity) continue ;;
    @*)
      value=${value#@}
      [ -n "$value" ] || continue
      ;;
    *[!0-9]*)
      HUMAN_VALS="${HUMAN_VALS}${value}"$'\n'
      continue
      ;;
    *) value=$(( value / 1000000 )) ;;
  esac

  if [ -z "$BEST" ] || [ "$value" -lt "$BEST" ]; then
    BEST="$value"
  fi
done < <(systemctl show -p NextElapseUSecRealtime --value "${units[@]}" 2>/dev/null)

if [ -n "$HUMAN_VALS" ]; then
  while IFS= read -r epoch; do
    [[ "$epoch" =~ ^[0-9]+$ ]] || continue
    if [ -z "$BEST" ] || [ "$epoch" -lt "$BEST" ]; then
      BEST="$epoch"
    fi
  done < <(printf '%s' "$HUMAN_VALS" | date -f - +%s 2>/dev/null)
fi

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
