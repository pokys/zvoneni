#!/bin/bash
set -e

mkdir -p /opt/zvoneni/sounds
mkdir -p /usr/local/bin

# Stock sounds are seeded, never imposed: an existing file is left alone,
# so a school that dropped in its own normal.wav keeps it across updates.
# They live under install/ rather than in /opt/zvoneni/sounds itself,
# because that directory is the git working tree - tracking the sounds
# there made a customised bell count as a local modification.
for f in /opt/zvoneni/install/sounds/*.wav; do
  [ -e "$f" ] || continue
  dst="/opt/zvoneni/sounds/$(basename "$f")"
  if [ -e "$dst" ]; then
    echo "[install] keeping existing sound $(basename "$f")"
  else
    cp "$f" "$dst"
    echo "[install] installed sound $(basename "$f")"
  fi
done

[ -f /opt/zvoneni/schedule.txt ] || cat > /opt/zvoneni/schedule.txt <<EOF
# DAY TIME TYPE
Mon 08:00 normal
EOF
