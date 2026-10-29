#!/usr/bin/env bash
# Prepare this Mac so the OpenChamber desktop app can reach the VPS over SSH
# without any prompt. Safe to re-run.

set -euo pipefail

ALIAS=""
HOST=""
REMOTE_USER="agent"
KEY="$HOME/.ssh/id_ed25519"
PORT="3000"

usage() {
  cat <<'EOF'
Usage: bash mac-connect.sh --host HOST --alias NAME [options]

  --host HOST    VPS address (required)
  --alias NAME   SSH host name the app will use (required)
  --user NAME    user on the VPS (default: agent)
  --key PATH     private key (default: ~/.ssh/id_ed25519)
  --port PORT    OpenChamber port on the VPS (default: 3000)
EOF
}

log()  { printf '\033[0;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarn:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --host)  HOST="${2:?--host needs a value}"; shift 2 ;;
    --alias) ALIAS="${2:?--alias needs a value}"; shift 2 ;;
    --user)  REMOTE_USER="${2:?--user needs a value}"; shift 2 ;;
    --key)   KEY="${2:?--key needs a path}"; shift 2 ;;
    --port)  PORT="${2:?--port needs a value}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown option: $1" ;;
  esac
done

[ "$(uname -s)" = Darwin ] || die "this script is for macOS"
[ -n "$HOST" ] || { usage >&2; die "--host is required"; }
[ -n "$ALIAS" ] || { usage >&2; die "--alias is required"; }
case "$ALIAS" in *[!A-Za-z0-9._-]*) die "--alias may only use letters, digits, '.', '_' and '-'" ;; esac
case "$PORT" in ''|*[!0-9]*) die "--port must be a number" ;; esac
KEY="${KEY/#\~/$HOME}"
[ -f "$KEY" ] || die "no private key at $KEY"
[ -f "$KEY.pub" ] || die "no public key at $KEY.pub (recreate it: ssh-keygen -y -f $KEY > $KEY.pub)"

SSH_DIR="$HOME/.ssh"
CONFIG="$SSH_DIR/config"
HOST_FILE="$SSH_DIR/config.d/openchamber-$ALIAS"
# A pattern of our own at the top of ~/.ssh/config: these host blocks then win
# over "Host *" defaults, and nothing else you keep in config.d gets pulled in.
INCLUDE_LINE='Include config.d/openchamber-*'

mkdir -p "$SSH_DIR/config.d"
chmod 700 "$SSH_DIR" "$SSH_DIR/config.d"
touch "$CONFIG"
chmod 600 "$CONFIG"

if ! grep -qxF "$INCLUDE_LINE" "$CONFIG"; then
  log "Adding '$INCLUDE_LINE' to the top of $CONFIG"
  tmp="$(mktemp)"
  { printf '%s\n\n' "$INCLUDE_LINE"; cat "$CONFIG"; } >"$tmp"
  cat "$tmp" >"$CONFIG"
  rm -f "$tmp"
fi

alias_re="$(printf '%s' "$ALIAS" | sed 's/\./\\./g')"
if grep -qiE "^[[:space:]]*Host[[:space:]]+(.*[[:space:]])?$alias_re([[:space:]]|\$)" "$CONFIG"; then
  warn "$CONFIG also has a 'Host $ALIAS' block; the one in $HOST_FILE wins, but you may want to delete the old one"
fi

log "Writing $HOST_FILE"
cat >"$HOST_FILE" <<EOF
Host $ALIAS
  HostName $HOST
  User $REMOTE_USER
  IdentityFile "$KEY"
  IdentitiesOnly yes
  AddKeysToAgent yes
  IgnoreUnknown UseKeychain
  UseKeychain yes
EOF
chmod 600 "$HOST_FILE"

log "Saving the key's passphrase in the macOS Keychain (type it if asked)"
/usr/bin/ssh-add --apple-use-keychain "$KEY"

# The app runs whichever ssh comes first on your login shell's PATH, and only
# Apple's /usr/bin/ssh can read the passphrase back from the Keychain.
LOGIN_PATH="$("${SHELL:-/bin/zsh}" -ilc 'printf "\n%s\n" "$PATH"' </dev/null 2>/dev/null | tail -n 1 || true)"
APP_SSH="$(PATH="${LOGIN_PATH:-$PATH}" /usr/bin/which ssh 2>/dev/null || true)"
APP_SSH="${APP_SSH:-/usr/bin/ssh}"
if [ "$APP_SSH" != /usr/bin/ssh ]; then
  warn "The desktop app will run $APP_SSH, which can't read the Keychain, so it can't unlock your key after a restart. Put /usr/bin first in PATH (for Homebrew's openssh: brew unlink openssh)."
fi

log "Testing the connection the way the desktop app does (no prompts)"
set +e
"$APP_SSH" -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new "$ALIAS" \
  "curl -fs --max-time 5 -o /dev/null http://127.0.0.1:$PORT/health"
rc=$?
set -e

case "$rc" in
  0) log "SSH works and OpenChamber answers on the VPS" ;;
  255)
    warn "SSH login failed."
    echo "If it said 'Permission denied (publickey)', authorize this key on the VPS:"
    echo "  sudo bash vps-setup.sh --ssh-key \"$(cat "$KEY.pub")\""
    echo "For details: $APP_SSH -v -o BatchMode=yes $ALIAS true"
    exit 1 ;;
  *)
    warn "SSH works, but OpenChamber isn't answering on port $PORT of the VPS (exit $rc)."
    echo "Check it on the VPS, logged in as $REMOTE_USER: systemctl --user status openchamber"
    exit 1 ;;
esac

cat <<EOF

In the OpenChamber desktop app, open Settings → Remote Instances and add an instance:
  SSH command:  ssh $ALIAS   (or pick "$ALIAS" under Saved SSH hosts)
  Nickname:     any name, e.g. agent-box
  Mode:         Already running
  Port on the remote machine: $PORT          (under Advanced settings)
  UI password:  the one you chose or the VPS script printed   (under Advanced settings)
Then press Connect.
EOF
