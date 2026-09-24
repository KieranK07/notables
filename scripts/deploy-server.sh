#!/usr/bin/env bash
#
# Deploy server/ from the Mac to the Windows PC and restart the note server.
#
#   ./scripts/deploy-server.sh              deploy + restart
#   ./scripts/deploy-server.sh --install    deploy + (re)install the scheduled task
#                                           and firewall rule, then restart
#   ./scripts/deploy-server.sh --no-restart just copy the files
#
# The PC's shell is cmd.exe: separate commands with & not ;.  Source files are
# always authored here and scp'd over - never edited through cmd quoting.
set -euo pipefail

HOST="${NOTABLES_PC:-pc}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$REPO/server"
# The PC's tailnet address lives in the gitignored notables.local at the repo root
# (NOTABLES_PC_HOST=<ip or MagicDNS name>), so it never lands in git.
[ -f "$REPO/notables.local" ] && . "$REPO/notables.local"
HEALTH_URL="http://${NOTABLES_PC_HOST:-$HOST}:8787/api/health"

INSTALL=0; RESTART=1
for a in "$@"; do
  case "$a" in
    --install)    INSTALL=1 ;;
    --no-restart) RESTART=0 ;;
    -h|--help)    sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done

[ -d "$SRC" ] || { echo "no server/ directory at $SRC" >&2; exit 1; }

# Install root on the PC: NOTABLES_PC_HOME from notables.local, else the PC's own
# %USERPROFILE%. The server resolves its vault the same way (server/lib/config.js).
PC_HOME="${NOTABLES_PC_HOME:-$(ssh "$HOST" 'echo %USERPROFILE%' | tr -d '\r')}"
case "$PC_HOME" in ''|*%*) echo "could not read %USERPROFILE% from $HOST; set NOTABLES_PC_HOME" >&2; exit 1 ;; esac
PC_HOME_FWD="${PC_HOME//\\//}"
REMOTE_DIR="$PC_HOME\Notables\server"
REMOTE_DIR_FWD="$PC_HOME_FWD/Notables/server"

echo "==> syntax-checking"
for f in "$SRC"/note-server.js "$SRC"/lib/*.js; do node --check "$f"; done

# Stage a copy so Windows batch/vbs files get CRLF endings without touching the repo.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$SRC/." "$STAGE/"
rm -rf "$STAGE/node_modules" "$STAGE/.DS_Store"
find "$STAGE" -name '.DS_Store' -delete
while IFS= read -r f; do
  perl -i -pe 's/\r?\n/\r\n/' "$f"
done < <(find "$STAGE" -type f \( -name '*.cmd' -o -name '*.bat' -o -name '*.vbs' \))

echo "==> stopping the running server (if any)"
ssh "$HOST" "powershell -NoProfile -ExecutionPolicy Bypass -Command \"\$p = Get-CimInstance Win32_Process -Filter 'Name=''node.exe''' | Where-Object { \$_.CommandLine -like '*note-server.js*' }; if (\$p) { \$p | ForEach-Object { Write-Host ('  stopped pid ' + \$_.ProcessId); Stop-Process -Id \$_.ProcessId -Force } } else { Write-Host '  not running' }\"" || true

echo "==> copying $SRC -> $HOST:$REMOTE_DIR"
ssh "$HOST" "if not exist \"$REMOTE_DIR\" mkdir \"$REMOTE_DIR\" & if not exist \"$REMOTE_DIR\\lib\" mkdir \"$REMOTE_DIR\\lib\" & if not exist \"$REMOTE_DIR\\python\" mkdir \"$REMOTE_DIR\\python\""
scp -q "$STAGE"/*.js "$STAGE"/*.cmd "$STAGE"/*.vbs "$HOST:$REMOTE_DIR_FWD/"
if [ -f "$STAGE/README.md" ]; then scp -q "$STAGE/README.md" "$HOST:$REMOTE_DIR_FWD/"; fi
scp -q "$STAGE"/lib/*.js "$HOST:$REMOTE_DIR_FWD/lib/"
scp -q "$STAGE"/python/*.py "$HOST:$REMOTE_DIR_FWD/python/"

# The MCP server rides along so a Claude instance ON the PC gets the same tools as one
# on the Mac. It is a client of the HTTP API like any other, so it is not part of the
# server proper - it just has to exist on both machines.
if [ -d "$REPO/mcp" ]; then
  echo "==> copying mcp/ -> $HOST:$PC_HOME\\Notables\\mcp"
  ssh "$HOST" "if not exist \"$PC_HOME\\Notables\\mcp\" mkdir \"$PC_HOME\\Notables\\mcp\""
  scp -q "$REPO"/mcp/* "$HOST:$PC_HOME_FWD/Notables/mcp/"
fi

if [ "$INSTALL" = 1 ]; then
  echo "==> installing the scheduled task + firewall rule"
  scp -q "$REPO/scripts/install-service.ps1" "$HOST:$PC_HOME_FWD/notables-install-service.ps1"
  ssh "$HOST" "powershell -NoProfile -ExecutionPolicy Bypass -File \"$PC_HOME\\notables-install-service.ps1\""
fi

if [ "$RESTART" = 1 ]; then
  echo "==> starting"
  ssh "$HOST" "wscript.exe //B //Nologo \"$REMOTE_DIR\\start-hidden.vbs\"" || true
  # 30s, not 10: a freshly-woken PC takes noticeably longer to get through
  # start-hidden.vbs + node boot, and a false "deploy failed" here sends you
  # debugging a server that is about to come up fine.
  for i in $(seq 1 30); do
    sleep 1
    if out=$(curl -fsS --max-time 4 "$HEALTH_URL" 2>/dev/null); then
      echo "==> healthy after ${i}s: $out"
      exit 0
    fi
  done
  echo "!!! server did not answer $HEALTH_URL within 30s" >&2
  ssh "$HOST" 'powershell -NoProfile -Command "Get-Content $env:USERPROFILE\Notables\logs\stdout.log -Tail 20"' || true
  exit 1
fi
echo "==> done (not restarted)"
