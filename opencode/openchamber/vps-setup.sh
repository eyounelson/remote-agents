#!/usr/bin/env bash
# Set up a headless OpenChamber server on a Debian/Ubuntu VPS, run by its own
# user with no sudo. Run as root. Safe to re-run: it updates Node.js, OpenCode
# and OpenChamber and restarts the service, which stops running agent sessions.

if [ -z "${BASH_VERSION:-}" ]; then
  echo "Run this with bash: sudo bash $0" >&2
  exit 1
fi

set -Eeuo pipefail

AGENT_USER="agent"
PORT="3000"
SSH_KEYS=""
API_ONLY=1
ENABLE_FIREWALL=0
NODE_MAJOR=24

usage() {
  cat <<'EOF'
Usage: sudo bash vps-setup.sh [options]

  --ssh-key KEY        public key that may log in as the agent user (repeatable)
  --ssh-key-file FILE  same, read from a file
  --user NAME          agent user (default: agent)
  --port PORT          OpenChamber port, on 127.0.0.1 only (default: 3000)
  --web-ui             also serve the browser UI (default: API only, for the apps)
  --enable-firewall    turn on ufw with only SSH open (closes every other port)
  -h, --help           show this help

The script asks for a UI password. Leave it empty to keep the current one,
or on the first run to generate one.
EOF
}

log()  { printf '\033[0;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarn:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[0;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
trap 'warn "stopped at line $LINENO: $BASH_COMMAND"' ERR

while [ $# -gt 0 ]; do
  case "$1" in
    --ssh-key)         SSH_KEYS+="${2:?--ssh-key needs a value}"$'\n'; shift 2 ;;
    --ssh-key-file)    [ -r "${2:?--ssh-key-file needs a path}" ] || die "can't read $2"
                       SSH_KEYS+="$(cat "$2")"$'\n'; shift 2 ;;
    --user)            AGENT_USER="${2:?--user needs a value}"; shift 2 ;;
    --port)            PORT="${2:?--port needs a value}"; shift 2 ;;
    --web-ui)          API_ONLY=0; shift ;;
    --enable-firewall) ENABLE_FIREWALL=1; shift ;;
    -h|--help)         usage; exit 0 ;;
    *)                 usage >&2; die "unknown option: $1" ;;
  esac
done

# --- Checks ------------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || die "run as root: sudo bash $0"
[ -f /etc/debian_version ] || die "only Debian and Ubuntu are supported"
command -v systemctl >/dev/null || die "systemd is required"
if ! [[ "$AGENT_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || [ "$AGENT_USER" = root ]; then
  die "invalid --user: $AGENT_USER"
fi
case "$PORT" in ''|*[!0-9]*) die "--port must be a number" ;; esac
if [ "$PORT" -lt 1024 ] || [ "$PORT" -gt 65535 ]; then
  die "--port must be between 1024 and 65535"
fi

mem_kb="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)"
swap_kb="$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo)"
if [ "$mem_kb" -lt 1900000 ] && [ "$swap_kb" -eq 0 ]; then
  warn "under 2 GB of RAM and no swap: npm installs and agent builds may run out of memory"
fi

# --- UI password -------------------------------------------------------------
EXISTING_HOME="$(getent passwd "$AGENT_USER" | cut -d: -f6 || true)"
if [ -n "$EXISTING_HOME" ] && [ -f "$EXISTING_HOME/.config/openchamber/startup.env" ]; then
  password_hint="empty = keep the current one"
else
  password_hint="empty = generate one"
fi
UI_PASSWORD=""
if { : </dev/tty; } 2>/dev/null; then
  while :; do
    read -rsp "UI password for OpenChamber ($password_hint): " UI_PASSWORD </dev/tty
    echo >&2
    [ -n "$UI_PASSWORD" ] || break
    read -rsp "Repeat it: " password_repeat </dev/tty
    echo >&2
    [ "$UI_PASSWORD" != "$password_repeat" ] || break
    warn "the passwords don't match, try again"
  done
fi

# --- System packages ---------------------------------------------------------
log "Installing system packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq ca-certificates curl unzip git build-essential python3 >/dev/null

# --- Agent user --------------------------------------------------------------
if id "$AGENT_USER" >/dev/null 2>&1; then
  uid_min="$(awk '$1 == "UID_MIN" {print $2}' /etc/login.defs 2>/dev/null || true)"
  if [ "$(id -u "$AGENT_USER")" -lt "${uid_min:-1000}" ]; then
    die "$AGENT_USER is a system account (uid $(id -u "$AGENT_USER")); pick another name with --user"
  fi
  log "User $AGENT_USER already exists"
else
  log "Creating user $AGENT_USER (no password, no sudo)"
  useradd --create-home --shell /bin/bash --comment "OpenChamber agent" "$AGENT_USER"
fi
AGENT_HOME="$(getent passwd "$AGENT_USER" | cut -d: -f6)"
AGENT_UID="$(id -u "$AGENT_USER")"
RUNTIME_DIR="/run/user/$AGENT_UID"
FNM_DIR="$AGENT_HOME/.local/share/fnm"
chmod 750 "$AGENT_HOME"
# "!" marks a locked account, which sshd turns away when UsePAM is off; "*" just means no password.
case "$(getent shadow "$AGENT_USER" | cut -d: -f2)" in
  '!'|'!!'|'!*') usermod -p '*' "$AGENT_USER" ;;
esac
for group in sudo wheel admin docker lxd; do
  case " $(id -nG "$AGENT_USER") " in
    *" $group "*) warn "$AGENT_USER is in the $group group, which gives it root-level access; remove it: gpasswd -d $AGENT_USER $group" ;;
  esac
done
cd "$AGENT_HOME"

# Everything inside the agent's home runs as the agent: root following a
# symlink the agent planted there could hand it root's files.
as_agent() {
  local bus=()
  if [ -S "$RUNTIME_DIR/bus" ]; then bus=("DBUS_SESSION_BUS_ADDRESS=unix:path=$RUNTIME_DIR/bus"); fi
  runuser -u "$AGENT_USER" -- env -i \
    HOME="$AGENT_HOME" USER="$AGENT_USER" LOGNAME="$AGENT_USER" SHELL=/bin/bash LANG=C.UTF-8 \
    FNM_DIR="$FNM_DIR" PATH="$FNM_DIR/aliases/default/bin:$FNM_DIR:/usr/local/bin:/usr/bin:/bin" \
    XDG_RUNTIME_DIR="$RUNTIME_DIR" "${bus[@]}" "$@"
}

# --- SSH access --------------------------------------------------------------
AUTH_KEYS="$AGENT_HOME/.ssh/authorized_keys"
as_agent mkdir -p "$AGENT_HOME/.ssh"
as_agent chmod 700 "$AGENT_HOME/.ssh"
as_agent touch "$AUTH_KEYS"
as_agent chmod 600 "$AUTH_KEYS"
mapfile -t key_lines <<<"$SSH_KEYS"
for key in "${key_lines[@]}"; do
  key="${key%$'\r'}"
  case "$key" in
    ''|'#'*) continue ;;
    ssh-*|ecdsa-*|sk-*) ;;
    *) die "not an SSH public key: ${key:0:40}..." ;;
  esac
  if as_agent grep -qxF -- "$key" "$AUTH_KEYS"; then
    log "SSH key already authorized: ${key:0:30}..."
  else
    as_agent sh -c 'printf "%s\n" "$1" >>"$2"' _ "$key" "$AUTH_KEYS"
    log "Authorized SSH key: ${key:0:30}..."
  fi
done
if ! as_agent grep -q . "$AUTH_KEYS"; then
  warn "no SSH key is authorized for $AGENT_USER; re-run with --ssh-key or the desktop app can't log in"
fi

# --- sshd settings that would keep the agent out -----------------------------
SSHD_CONFIG="$(sshd -T 2>/dev/null || true)"
sshd_option() { awk -v key="$1" '$1 == key { $1 = ""; sub(/^ /, ""); print }' <<<"$SSHD_CONFIG"; }
if [ -n "$SSHD_CONFIG" ]; then
  allow_users="$(sshd_option allowusers)"
  if [ -n "$allow_users" ] && ! grep -qE "^${AGENT_USER}(@.*)?\$" <<<"$allow_users"; then
    warn "sshd's AllowUsers doesn't include $AGENT_USER; add it in /etc/ssh/sshd_config, then: systemctl reload ssh"
  fi
  allow_groups="$(sshd_option allowgroups)"
  if [ -n "$allow_groups" ]; then
    in_allowed_group=0
    for group in $(id -nG "$AGENT_USER"); do
      if grep -qxF "$group" <<<"$allow_groups"; then in_allowed_group=1; fi
    done
    if [ "$in_allowed_group" -eq 0 ]; then
      warn "sshd's AllowGroups includes none of $AGENT_USER's groups; add one: usermod -aG <group> $AGENT_USER"
    fi
  fi
  case " $(sshd_option authorizedkeysfile | tr '\n' ' ') " in
    *".ssh/authorized_keys "*) ;;
    *) warn "sshd doesn't read ~/.ssh/authorized_keys (AuthorizedKeysFile: $(sshd_option authorizedkeysfile)); put the key where it looks" ;;
  esac
  if [ "$(sshd_option pubkeyauthentication)" = no ]; then
    warn "sshd has PubkeyAuthentication off, so key logins (and the desktop app) won't work"
  fi
fi

# --- What the agent user can read --------------------------------------------
for dir in /root /home/*; do
  if [ ! -d "$dir" ] || [ "$dir" = "$AGENT_HOME" ]; then continue; fi
  case "$(stat -c %a "$dir")" in
    *[1-7]) warn "$dir can be read by other users, including $AGENT_USER: chmod 750 $dir" ;;
  esac
done
exposed_env_files="$(find /var/www /srv /opt -maxdepth 5 -type f -name '.env*' -perm -o=r 2>/dev/null | head -n 10 || true)"
if [ -n "$exposed_env_files" ]; then
  warn "these files can be read by every user, including $AGENT_USER (fix with chmod o-r):"
  sed 's/^/    /' <<<"$exposed_env_files" >&2
fi

# --- Background services without a login ------------------------------------
log "Letting $AGENT_USER's services run without a login"
loginctl enable-linger "$AGENT_USER"
systemctl start "user@$AGENT_UID.service"
for _ in $(seq 1 30); do
  if [ -S "$RUNTIME_DIR/systemd/private" ]; then break; fi
  sleep 1
done
if [ ! -S "$RUNTIME_DIR/systemd/private" ]; then
  die "$AGENT_USER's systemd user manager didn't start; some container-based VPSes don't support user services"
fi

# --- Node.js through fnm -----------------------------------------------------
# fnm keeps Node.js inside the agent's home, so the server's own Node is left
# alone, and the agent can add other versions for projects that need them.
log "Installing fnm and Node.js $NODE_MAJOR for $AGENT_USER"
if ! fnm_output="$(as_agent bash -c 'set -o pipefail; curl -fsSL https://fnm.vercel.app/install | bash -s -- --install-dir "$1" --skip-shell' _ "$FNM_DIR" 2>&1)"; then
  printf '%s\n' "$fnm_output" >&2
  die "installing fnm failed"
fi
as_agent fnm install "$NODE_MAJOR" --progress never
as_agent fnm default "$NODE_MAJOR"
node_version="$(as_agent node -v)"
log "Node.js $node_version is now $AGENT_USER's default"

# First line of the file, so non-interactive shells (SSH commands, the desktop
# app's checks) get fnm's default Node.js too.
PATH_LINE='export PATH="$HOME/.local/share/fnm/aliases/default/bin:$HOME/.local/share/fnm:$PATH" # added by openchamber-vps-setup'
for rc in .bashrc .profile; do
  as_agent sh -c '
    touch "$1"
    tmp="$(mktemp)"
    { printf "%s\n" "$2"; grep -vF "added by openchamber-vps-setup" "$1"; } >"$tmp"
    cat "$tmp" >"$1"
    rm -f "$tmp"
  ' _ "$AGENT_HOME/$rc" "$PATH_LINE"
done

# --- OpenCode and OpenChamber ------------------------------------------------
if [ -f "$AGENT_HOME/.config/systemd/user/openchamber.service" ]; then
  log "Stopping OpenChamber for the update"
  as_agent systemctl --user stop openchamber.service || true
fi
log "Installing OpenCode and OpenChamber for $AGENT_USER"
as_agent npm install --global --no-fund --no-audit --loglevel=error @opencode/cli@latest @openchamber/web@latest
if ! as_agent sh -c 'command -v opencode && command -v openchamber' >/dev/null; then
  die "opencode or openchamber isn't on $AGENT_USER's PATH after the install"
fi
if [ -e "$AGENT_HOME/.opencode/bin/opencode" ]; then
  warn "an older OpenCode from its install script sits in $AGENT_HOME/.opencode/bin and comes first in interactive shells; delete it and its PATH line in ~/.bashrc"
fi

port_pid="$(ss -Hltnp "sport = :$PORT" 2>/dev/null | grep -o 'pid=[0-9]*' | head -n 1 | cut -d= -f2 || true)"
if [ -n "$port_pid" ]; then
  die "port $PORT is taken by '$(ps -o args= -p "$port_pid" | cut -c1-80)' (user $(ps -o user:32= -p "$port_pid" | tr -d ' ')); stop it or pick another port with --port"
fi

# --- Service -----------------------------------------------------------------
GENERATED_PASSWORD=0
STARTUP_ENV="$AGENT_HOME/.config/openchamber/startup.env"
if [ -z "$UI_PASSWORD" ] && [ -f "$STARTUP_ENV" ]; then
  # Read as the agent: root must never source a file the agent can write.
  UI_PASSWORD="$(as_agent bash -c 'set -a; . "$1" >/dev/null 2>&1; printf "%s" "${OPENCHAMBER_UI_PASSWORD:-}"' _ "$STARTUP_ENV" || true)"
  if [ -n "$UI_PASSWORD" ]; then log "Keeping the current UI password"; fi
fi
if [ -z "$UI_PASSWORD" ]; then
  UI_PASSWORD="$(head -c 18 /dev/urandom | base64 | tr -d '/+=')"
  GENERATED_PASSWORD=1
fi

log "Starting OpenChamber as a service on 127.0.0.1:$PORT"
enable_args=(--port "$PORT")
if [ "$API_ONLY" -eq 1 ]; then enable_args+=(--api-only); fi
as_agent env OPENCHAMBER_UI_PASSWORD="$UI_PASSWORD" openchamber startup enable "${enable_args[@]}" >/dev/null
# "enable --now" leaves a running service alone; restart so the new version and settings apply.
as_agent systemctl --user restart openchamber.service

healthy=0
for _ in $(seq 1 60); do
  if curl -fs --max-time 2 -o /dev/null "http://127.0.0.1:$PORT/health"; then healthy=1; break; fi
  sleep 1
done
if [ "$healthy" -eq 0 ]; then
  die "OpenChamber isn't answering on 127.0.0.1:$PORT. Logs: journalctl _UID=$AGENT_UID _SYSTEMD_USER_UNIT=openchamber.service -n 80 --no-pager"
fi

# --- Firewall (opt-in) -------------------------------------------------------
if [ "$ENABLE_FIREWALL" -eq 1 ]; then
  ssh_ports="$(sshd_option port)"
  ssh_ports="${ssh_ports:-22}"
  log "Firewall: allowing SSH on port $(tr '\n' ' ' <<<"$ssh_ports")and blocking all other incoming traffic"
  apt-get install -y -qq ufw >/dev/null
  for p in $ssh_ports; do ufw allow "$p/tcp" >/dev/null; done
  ufw --force enable >/dev/null
fi

# --- Summary -----------------------------------------------------------------
HOST_IP="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
echo
log "Done"
echo "  User:    $AGENT_USER (no password, no sudo, home $AGENT_HOME)"
echo "  Node.js: $node_version through fnm"
echo "  Server:  127.0.0.1:$PORT, reachable only through SSH or the Private Relay"
if [ "$GENERATED_PASSWORD" -eq 1 ]; then
  echo "  UI password: $UI_PASSWORD   <- generated; save it now"
fi
echo
echo "Next, on your Mac:"
echo "  bash mac-connect.sh --host ${HOST_IP:-<vps-ip>} --alias <name> --key ~/.ssh/<your-key> --port $PORT"
echo "To pair a phone through the Private Relay:"
echo "  ssh -t $AGENT_USER@${HOST_IP:-<vps-ip>} '~/.local/share/fnm/aliases/default/bin/openchamber connect-url --port $PORT --relay --qr'"
