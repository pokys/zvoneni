#!/bin/bash
set -e
[ "$(id -u)" -eq 0 ] || { echo "Run as root"; exit 1; }