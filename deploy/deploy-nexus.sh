#!/usr/bin/env bash
# deploy-nexus.sh — upgrade a systemd-managed Nexus/MCPHub (behind nginx) to a deploy bundle.
# CI sets AUTO_YES=1 to skip the confirmation prompt; the health check and rollback still run.
# Run ON THE SERVER as a sudo-capable user (or root), with the tarball next to this script:
#   bash deploy-nexus.sh [nexus-v1.1.3-deploy.tar.gz] [systemd-service-name]
# Never prints DB credentials. Old app dir is kept as <dir>.bak-<timestamp>. nginx is only READ, never changed.
set -euo pipefail

say(){ printf '\n\033[1m== %s\033[0m\n' "$*"; }
die(){ printf '\033[31mABORT: %s\033[0m\n' "$*" >&2; exit 1; }
mask(){ sed -E 's#(://[^:/@ ]+:)[^@ ]+@#\1***@#g'; }

# ---- pure helpers (unit-tested) ----
parse_exec_path(){ sed -n 's/.*path=\([^ ;]*\).*/\1/p' <<<"$1" | head -1; }
parse_entry(){ { sed -n 's/.*argv\[\]=\([^;]*\);.*/\1/p' <<<"$1" | grep -oE '[^ ]*dist/index\.js' | head -1; } || true; }
parse_files(){ { grep -oE '(^|[ ])-?/[^ ()]+' <<<"$1" | tr -d ' ' | sed 's/^-//'; } || true; }
envtxt_get(){ tr ' ' '\n' <<<"$1" | sed -n "s/^\"\{0,1\}$2=//p" | head -1 | sed 's/"$//'; }
envfile_get(){ sed -n "s/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}$2=//p" <<<"$1" | head -1 | sed -e 's/^["'"'"']//' -e 's/["'"'"']$//'; }
to_seconds(){ local n="${1%%[a-z]*}" u="${1##*[0-9]}"; case "$u" in ms) echo 0;; m) echo $((n*60));; h) echo $((n*3600));; d) echo $((n*86400));; *) echo "$n";; esac; }
if [ "${NEXUS_TEST:-}" = 1 ]; then return 0 2>/dev/null || exit 0; fi

TAR="${1:-nexus-v1.1.3-deploy.tar.gz}"; SVC="${2:-}"; TS=$(date +%Y%m%d-%H%M%S)
[ -f "$TAR" ] || die "tarball '$TAR' not found next to the script"
SUDO=""; if [ "$(id -u)" -ne 0 ]; then command -v sudo >/dev/null || die "need root or sudo"; SUDO="sudo"; fi
command -v systemctl >/dev/null || die "systemctl not found"; command -v npx >/dev/null || die "npm/npx not found in PATH"

say "1/9 Locate the systemd service"
if [ -z "$SVC" ]; then
  CANDS=$(systemctl list-unit-files --type=service --no-legend 2>/dev/null | awk '{print $1}' | grep -iE 'mcphub|nexus' || true)
  [ "$(printf '%s\n' "$CANDS" | grep -c .)" = 1 ] || { echo "Candidates: ${CANDS:-none}"; echo "Running node-ish services:"; systemctl list-units --type=service --state=running --no-legend | grep -iE 'node|mcp|nexus' || true; die "pass the service name as the 2nd argument"; }
  SVC="$CANDS"
fi
SVC="${SVC%.service}"; prop(){ systemctl show "$SVC" -p "$1" --value 2>/dev/null; }
[ "$(prop LoadState)" = loaded ] || die "service '$SVC' not found"
EXECSTART=$(prop ExecStart); SVC_USER=$(prop User); SVC_USER="${SVC_USER:-root}"
EXEC_PATH=$(parse_exec_path "$EXECSTART"); ENTRY=$(parse_entry "$EXECSTART")
APP_DIR=$(prop WorkingDirectory); APP_DIR="${APP_DIR#!}"; APP_DIR="${APP_DIR#-}"
[ "$APP_DIR" = "~" ] && APP_DIR=""
if [ -z "$APP_DIR" ] || [ ! -f "$APP_DIR/dist/index.js" ]; then
  [ -n "$ENTRY" ] && { case "$ENTRY" in /*) ;; *) ENTRY="$APP_DIR/$ENTRY";; esac; APP_DIR=$(dirname "$(dirname "$ENTRY")"); }
fi
[ -f "$APP_DIR/dist/index.js" ] || die "couldn't find dist/index.js (WorkingDirectory='$(prop WorkingDirectory)'). Check: systemctl cat $SVC"
ENVTXT=$(prop Environment); ENVFILES=$( { parse_files "$(prop EnvironmentFiles)"; echo "$APP_DIR/.env"; } | awk 'NF && !s[$0]++')
getvar(){ local v; v=$(envtxt_get "$ENVTXT" "$1")
  if [ -z "$v" ]; then local f; while read -r f; do [ -n "$f" ] || continue; v=$(envfile_get "$($SUDO cat "$f" 2>/dev/null || true)" "$1"); [ -n "$v" ] && break; done <<<"$ENVFILES"; fi
  printf '%s' "$v"; }
PORT=$(getvar PORT); PORT="${PORT:-3000}"; DBURL=$(getvar DB_URL)
if [ "$(basename "${EXEC_PATH:-x}")" = node ]; then NODE_BIN="$EXEC_PATH"; else NODE_BIN=$(command -v node || true); echo "note: service doesn't start 'node' directly; using $NODE_BIN for the version check/install"; fi
[ -x "${NODE_BIN:-}" ] || die "no node binary found"; NODE_MAJOR=$("$NODE_BIN" -p 'process.versions.node.split(".")[0]')
[ "$NODE_MAJOR" -ge 20 ] || die "service Node is v$NODE_MAJOR; v1.1.x needs Node >= 20 (upgrade Node first)"
echo "service: $SVC | user: $SVC_USER | dir: $APP_DIR | port: $PORT | node: $("$NODE_BIN" -v) | DB_URL: $([ -n "$DBURL" ] && echo found || echo 'not found')"

say "2/9 Database backup (pg_dump, custom format)"
DUMP=""
if [ -z "$DBURL" ]; then echo "No DB_URL found for this service."; [ "${SKIP_DB_BACKUP:-}" = 1 ] || die "refusing to continue without a DB backup. If you truly run without a database, re-run with SKIP_DB_BACKUP=1"
else
  command -v pg_dump >/dev/null || die "pg_dump not installed (e.g. apt install postgresql-client)"
  DUMP="$HOME/nexus-pre-v1.1.3-$TS.dump"; umask 077
  pg_dump "$DBURL" -Fc -f "$DUMP" 2>/tmp/pgdump.$$.err || { mask </tmp/pgdump.$$.err | tail -3; rm -f /tmp/pgdump.$$.err; die "pg_dump failed (client older than server is the usual cause)"; }
  rm -f /tmp/pgdump.$$.err; [ -s "$DUMP" ] || die "backup file is empty"; echo "backup OK: $DUMP ($(du -h "$DUMP" | cut -f1))"
fi

say "3/9 Unpack new version beside the old one"
NEW="${APP_DIR}.new-$TS"; BAK="${APP_DIR}.bak-$TS"
$SUDO mkdir -p "$NEW"; $SUDO chown "$(id -un)": "$NEW"; tar xzf "$TAR" -C "$NEW"
while read -r f; do [ -e "$APP_DIR/$f" ] && $SUDO cp -a "$APP_DIR/$f" "$NEW/" && echo "carried over: $f"; done < <(printf '%s\n' .env mcp_settings.json data)

say "4/9 Install dependencies (fresh, using the service's Node)"
# NOTE: deliberately NOT --prod: upstream v1.1.3 imports 'zod' at runtime but lists it as a devDependency.
LOG="/tmp/nexus-install-$TS.log"
if ! ( cd "$NEW" && PATH="$(dirname "$NODE_BIN"):$PATH" npx -y pnpm@10.12.4 install --frozen-lockfile >"$LOG" 2>&1 ); then
  echo "---- install output (last 30 lines) ----"; tail -30 "$LOG" | mask; echo "---- full log: $LOG ----"
  $SUDO rm -rf "$NEW"; die "dependency install failed; the running service was NOT touched and the side folder was removed"
fi
tail -2 "$LOG"; [ -d "$NEW/node_modules" ] || { $SUDO rm -rf "$NEW"; die "install produced no node_modules; running service untouched"; }
$SUDO chown -R "$SVC_USER": "$NEW"

echo; if [ "${AUTO_YES:-}" = 1 ]; then OK=yes; echo "AUTO_YES=1: proceeding without prompt"; else read -r -p "Ready to stop '$SVC', swap in the new version and start it. Type 'yes' to continue: " OK; fi
[ "$OK" = yes ] || { echo "Cancelled. Service untouched; prepared files are in $NEW"; exit 0; }

say "5/9 Swap + start"
START=$(date '+%Y-%m-%d %H:%M:%S'); NR_BEFORE=$(prop NRestarts); NR_BEFORE="${NR_BEFORE:-0}"
$SUDO systemctl stop "$SVC"; $SUDO mv "$APP_DIR" "$BAK"; $SUDO mv "$NEW" "$APP_DIR"; $SUDO systemctl start "$SVC"
rollback(){ echo "ROLLING BACK to the previous version..."; $SUDO systemctl stop "$SVC" || true; $SUDO mv "$APP_DIR" "$APP_DIR.failed-$TS"; $SUDO mv "$BAK" "$APP_DIR"; $SUDO systemctl start "$SVC"
  echo "Rolled back. Failed build kept at $APP_DIR.failed-$TS. DB backup: ${DUMP:-none}"; echo "(v1.1.3 may have added DB columns/tables; the old version tolerates this. To undo fully: pg_restore --clean from the backup.)"; exit 1; }

say "6/9 Health check (25s)"; sleep 25
ACTIVE=$(systemctl is-active "$SVC" || true); NR=$(prop NRestarts); NR="${NR:-0}"
HTTP=$(curl -s -o /dev/null -m 10 -w '%{http_code}' "http://127.0.0.1:$PORT/" || echo 000)
echo "systemd: $ACTIVE | restarts since swap: $((NR-NR_BEFORE)) | http://127.0.0.1:$PORT/ -> $HTTP"
[ "$ACTIVE" = active ] || rollback
[ $((NR-NR_BEFORE)) -le 1 ] || { echo "service is crash-looping"; rollback; }
[ "$HTTP" -ge 200 ] && [ "$HTTP" -lt 500 ] || { echo "web endpoint not healthy"; rollback; }

say "7/9 Startup log (errors/schema lines)"
$SUDO journalctl -u "$SVC" --since "$START" --no-pager 2>/dev/null | mask | grep -iE 'error|synchron|typeorm|listening|running|started' | tail -15 || true

say "8/9 nginx check (read-only)"
if command -v nginx >/dev/null; then
  CONF=$($SUDO nginx -T 2>/dev/null || true)
  EXC=$(grep -n -B14 -A14 "proxy_pass[^;]*:$PORT" <<<"$CONF" | head -70 || true)
  if [ -z "$EXC" ]; then echo "No proxy_pass to :$PORT found (maybe an upstream block). Check manually: sudo nginx -T | grep -n proxy_"
  else
    PROBLEMS=0
    grep -q 'proxy_http_version[[:space:]]*1\.1' <<<"$EXC" || { echo "  ! proxy_http_version 1.1 missing"; PROBLEMS=1; }
    grep -qE 'proxy_buffering[[:space:]]+off' <<<"$EXC" || { echo "  ! proxy_buffering off missing (streams get buffered/stall)"; PROBLEMS=1; }
    RT=$(grep -oE 'proxy_read_timeout[[:space:]]+[0-9]+[a-z]*' <<<"$EXC" | awk '{print $2}' | head -1)
    if [ -z "$RT" ]; then echo "  ! proxy_read_timeout not set => nginx default 60s kills idle MCP/SSE streams"; PROBLEMS=1
    elif [ "$(to_seconds "$RT")" -lt 3600 ]; then echo "  ! proxy_read_timeout is $RT (< 1h): idle streams will drop"; PROBLEMS=1; fi
    if [ "$PROBLEMS" = 1 ]; then cat <<'NG'

  Suggested (add inside the location block that proxies to Nexus, then: sudo nginx -t && sudo systemctl reload nginx):
      proxy_http_version 1.1;
      proxy_buffering off;
      proxy_cache off;
      proxy_read_timeout 24h;
      proxy_send_timeout 24h;
NG
    else echo "  nginx looks fine for long-lived MCP streams."; fi
  fi
else echo "nginx not on this host's PATH; skipped."; fi

say "9/9 Done"
echo "SUCCESS. Rollback copy: $BAK | DB backup: ${DUMP:-none}"
echo "Manual rollback: sudo systemctl stop $SVC; sudo mv $APP_DIR $APP_DIR.bad; sudo mv $BAK $APP_DIR; sudo systemctl start $SVC"
