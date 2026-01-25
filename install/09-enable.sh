#!/bin/bash
set -e

systemctl daemon-reload
systemctl enable clock-watch
systemctl start clock-watch
systemctl enable zvoneni.target