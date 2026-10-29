#!/usr/bin/env bash
# rollback-nexus.sh — swap the app directory back to the most recent <dir>.bak-<timestamp>
# created by deploy-nexus.sh, then restart the service. Does NOT restore the database:
# the pg_dump taken before the deploy stays in the deploy user's home directory.
# Usage: bash rollback-nexus.sh <systemd-service-name>
set -euo pipefail
SVC="${1:?usage: rollback-nexus.sh <service-name>}"; SVC="${SVC%.service}"
SUDO=""; if [ "$(id -u)" -ne 0 ]; then SUDO="sudo"; fi
APP_DIR=$(systemctl show "$SVC" -p WorkingDirectory --value); APP_DIR="${APP_DIR#!}"; APP_DIR="${APP_DIR#-}"
[ -n "$APP_DIR" ] && [ -d "$APP_DIR" ] || { echo "ABORT: WorkingDirectory for $SVC not found"; exit 1; }
BAK=$(ls -1d "${APP_DIR}".bak-* 2>/dev/null | sort | tail -1 || true)
[ -n "$BAK" ] || { echo "ABORT: no ${APP_DIR}.bak-* directory to roll back to"; exit 1; }
TS=$(date +%Y%m%d-%H%M%S)
echo "Rolling back: $APP_DIR <- $BAK"
$SUDO systemctl stop "$SVC"
$SUDO mv "$APP_DIR" "${APP_DIR}.rolledback-$TS"
$SUDO mv "$BAK" "$APP_DIR"
$SUDO systemctl start "$SVC"
sleep 20
ACTIVE=$(systemctl is-active "$SVC" || true)
echo "systemd: $ACTIVE"
[ "$ACTIVE" = active ] || { echo "ABORT: service not active after rollback; check: journalctl -u $SVC -n 100"; exit 1; }
echo "Rollback complete. Replaced directory kept at ${APP_DIR}.rolledback-$TS"
