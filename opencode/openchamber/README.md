# OpenChamber remote setup

Run OpenChamber on a VPS and control it from the OpenChamber desktop app on your Mac.

- `vps-setup.sh` runs on the VPS. It creates an `agent` user with no password and no sudo, installs Node.js (with fnm), OpenCode and OpenChamber for that user, and runs OpenChamber as a background service on `127.0.0.1:3000`.
- `mac-connect.sh` runs on your Mac. It sets up SSH so the desktop app can reach the VPS without prompts.

Your projects, sessions and agents live on the VPS. They keep running when your Mac sleeps.

## Requirements

- A Debian or Ubuntu VPS with systemd, and an account there with root or sudo
- A Mac with the OpenChamber desktop app
- An SSH key on the Mac, e.g. `~/.ssh/id_ed25519`

## Setup

**1. Copy the VPS script to the server and run it with your public key.** From `opencode/openchamber` on your Mac:

```bash
scp vps-setup.sh <admin>@<vps-ip>:
ssh -t <admin>@<vps-ip> "sudo bash vps-setup.sh --ssh-key '$(cat ~/.ssh/id_ed25519.pub)'"
```

It asks for a UI password. Leave it empty to have one generated, and save the one it prints.

**2. Connect your Mac.**

```bash
bash mac-connect.sh --host <vps-ip> --alias <name> --key ~/.ssh/id_ed25519
```

`<name>` is what you'll pick in the app, e.g. `agent-box`. The script stores your key's passphrase in the Keychain and tests the connection.

**3. Add the VPS in the app.** Open Settings → Remote Instances and add an instance:

| Field | Value |
|---|---|
| SSH command | `ssh <name>`, or pick it under Saved SSH hosts |
| Mode | Already running |
| Port on the remote machine | `3000` (under Advanced settings) |
| UI password | the password from step 1 (under Advanced settings) |

Press Connect. To add a project, clone your repo on the VPS and pick its folder in the app.

## Updating

Run step 1 again. It updates Node.js, OpenCode and OpenChamber and keeps your UI password if you leave the prompt empty. Running agent sessions stop while the service restarts.

## Options

VPS script (`--help` lists them):

- `--user NAME`: agent user, default `agent`
- `--port PORT`: default `3000`
- `--ssh-key-file FILE`: read keys from a file instead
- `--web-ui`: also serve the browser UI
- `--enable-firewall`: turn on ufw with only SSH open. This closes every other port, including your own apps'

Mac script: `--user`, `--key` and `--port` match the VPS side.

## Phone

Pair the mobile app through OpenChamber's Private Relay, with no open ports:

```bash
ssh -t agent@<vps-ip> '~/.local/share/fnm/aliases/default/bin/openchamber connect-url --port 3000 --relay --qr'
```

## If something fails

- **SSH login fails:** run step 1 again with the right `--ssh-key`. For details: `ssh -v -o BatchMode=yes <name> true`.
- **OpenChamber doesn't answer:** on the VPS as `agent`, run `systemctl --user status openchamber`.
- **The app asks for an SSH passphrase and fails:** run the Mac script again. The app's passphrase prompt doesn't work on macOS, so the passphrase has to be in the Keychain.
- **Lost the UI password:** it's in `~agent/.config/openchamber/startup.env` on the VPS, or run step 1 again and type a new one.

## Security notes

- The agent can't use sudo and only listens on `127.0.0.1`. The app reaches it through SSH.
- The VPS script warns about anything the agent could read that it shouldn't, such as other home folders or `.env` files.
- Add GitHub access for the agent separately. A fine-grained or classic token for a bot account works.
