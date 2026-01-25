#!/bin/bash
set -e
echo "=== School Bell install ==="

for f in /opt/zvoneni/install/[0-9][0-9]-*.sh; do
  echo ">> $f"
  bash "$f"
done

echo "=== DONE ==="