# NemoClaw Server Setup

Step-by-step guide for deploying an NVIDIA NemoClaw gateway on a VPS (or DGX / GPU host) and connecting it to ibl.ai as a chat runner.

Reference: [NemoClaw Quickstart (NVIDIA Docs)](https://docs.nvidia.com/nemoclaw/latest/get-started/quickstart.html).

---

## How NemoClaw differs from OpenClaw

NemoClaw is NVIDIA's turnkey distribution of OpenClaw. A vanilla OpenClaw install puts the gateway directly on the host; NemoClaw wraps it in a hardened **OpenShell sandbox** (container) with an NVIDIA inference plugin pre-installed.

Practical consequences for the setup:

- The gateway runs **inside** the sandbox, not directly on the host. An `openshell` port-forward exposes it to the host's network namespace.
- You operate three CLIs: `nemoclaw` (orchestrator), `openshell` (sandbox + forwards), `openclaw` (inside the sandbox -- reached via `openshell exec`).
- By default the onboarding wizard binds the host-side forward to `127.0.0.1:18789`, which is fine for Caddy on the same host -- but the Control UI origin allowlist is baked at onboard time, so the hostname you plan to serve from must be known before `nemoclaw onboard` runs.
- Hardware requirements are higher than OpenClaw: **8 GB RAM minimum, 16 GB recommended; 20 GB disk minimum, 40 GB recommended; 4+ vCPU.**

If you already know OpenClaw, read this guide in conjunction with [OpenClaw Server Setup](server-setup.md) -- firewall, Caddy reverse-proxy, device-identity, and ibl.ai platform integration work identically.

---

## Architecture

```
Student (browser) → ibl.ai Platform (Django Channels / ASGI)
                         │
                         ▼
                    ClawLLMRunner
                         │
                         ▼
                    OpenClawClient (WSS + Ed25519 device identity signing)
                         │
                         ▼
                    Caddy (on host, TLS via Let's Encrypt)
                         │ reverse proxy to 127.0.0.1:18789
                         ▼
                    openshell forward (host ↔ sandbox)
                         │
                         ▼
                    OpenClaw Gateway (inside OpenShell sandbox)
                         │
                         ▼
                    NVIDIA NemoClaw plugin
                         │
                         ▼
                    LLM Provider (NVIDIA NIM, Anthropic, OpenAI, etc.)
```

**Why Caddy on the host (not Docker):** same reason as OpenClaw -- Caddy must connect from `127.0.0.1` so loopback auto-approval for device identity works. The openshell forward already crosses the sandbox boundary; adding another container around Caddy breaks the loopback guarantee.

**Why device identity signing:** identical to OpenClaw -- without Ed25519 signing on the WebSocket handshake the gateway grants zero scopes and config push fails with `missing scope: operator.read`. See [OpenClaw Part 5.2](server-setup.md#52----generate-and-store-device-keypair).

---

## Prerequisites

1. **A VPS or GPU host** -- at least 4 vCPU / 8 GB RAM / 20 GB disk; 16 GB RAM + 40 GB disk recommended. A GPU is not required for NemoClaw itself (only for local inference via NVIDIA NIM); any Linux host with Docker will do.
2. **A domain or subdomain** pointing to the server's actual IP. In the examples below we use `domain.example.com`.
3. **Anthropic API key** (or another LLM provider key -- NVIDIA NIM API key, OpenAI, etc.).
4. **Ports 80 and 443 open** on the cloud firewall **before** installing Caddy. See [OpenClaw Part 3](server-setup.md#part-3-firewall) for the rate-limit / ACME pitfalls.
5. **Docker** (or a compatible runtime -- Colima / Docker Desktop on macOS, WSL2 on Windows). On Ubuntu:

   ```bash
   apt-get update && apt-get install -y docker.io
   systemctl enable --now docker
   ```

6. **Node.js 22.16+** and **npm 10+**. The NemoClaw installer will install Node.js automatically if missing, but you can pre-install:

   ```bash
   curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
   apt-get install -y nodejs
   node --version  # must be v22.16 or later
   ```

### Critical: set `CHAT_UI_URL` before onboarding

NemoClaw bakes its Control UI **origin allowlist** into the sandbox image when `nemoclaw onboard` runs. The default allowlist is `http://127.0.0.1:18789` only. A browser that opens the dashboard as `https://domain.example.com` will be rejected unless that origin is in the allowlist.

Fixing this after the fact requires either recreating the sandbox or running `openclaw config set gateway.controlUi.allowedOrigins ...` inside it (see [Part 4](#part-4-hostname-access-configuration)). Save yourself the recreate -- export `CHAT_UI_URL` before running the installer:

```bash
export CHAT_UI_URL="https://domain.example.com"
```

---

## Part 1: Install NemoClaw

### 1.1 -- SSH in and set `CHAT_UI_URL`

```bash
ssh root@<server-ip>

# Set BEFORE onboarding so the allowlist is baked correctly
export CHAT_UI_URL="https://domain.example.com"
echo "export CHAT_UI_URL=$CHAT_UI_URL" >> ~/.bashrc
```

### 1.2 -- Run the NemoClaw installer

```bash
curl -fsSL https://www.nvidia.com/nemoclaw.sh | bash
```

This installs Node.js (if missing), the `nemoclaw` CLI, the `openshell` CLI, and the sandbox image, then launches the guided onboarding wizard. After it completes, reload the shell:

```bash
source ~/.bashrc
nemoclaw --version
openshell --version
```

### 1.3 -- Complete onboarding

If the installer already ran the wizard, skip this. Otherwise:

```bash
nemoclaw onboard
```

The wizard prompts for:

- **Sandbox name** -- used as `<sandbox-name>` in later commands. Pick something stable, e.g. `simon`.
- **Inference provider** -- select Anthropic, NVIDIA NIM, or another provider.
- **API key** for that provider.
- **Security policy** -- accept the default `standard` unless you have a specific reason otherwise.

On completion it prints the sandbox name, primary model, and gateway port (default `18789`). Record these -- you need the sandbox name for every `openshell` command below.

### 1.4 -- Generate a gateway token

The token that the ibl.ai platform will use to authenticate comes from the sandbox's OpenClaw config. Drop into the sandbox and read it:

```bash
nemoclaw <sandbox-name> connect
# Inside the sandbox:
openclaw config get gateway.auth.token
exit
```

If the wizard didn't generate one, re-run onboarding -- `nemoclaw <sandbox-name> rebuild --yes` picks fresh auth settings.

**Save this token** -- you need it when connecting to the ibl.ai platform and when opening the Control UI in a browser.

### 1.5 -- Verify the sandbox is running

```bash
nemoclaw <sandbox-name> status
openshell forward list
curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:18789/
# Expected: 200
```

If the forward list does not show `18789 → sandbox:18789`, start it manually:

```bash
openshell forward start --background 127.0.0.1:18789 <sandbox-name>
```

### 1.6 -- Persistence across reboots

The NemoClaw installer wires up a systemd service for the sandbox, but the openshell port forward is **not** automatically restored if the sandbox is recreated. Add a systemd unit that re-creates the forward on boot:

```bash
cat > /etc/systemd/system/nemoclaw-forward.service << 'EOF'
[Unit]
Description=NemoClaw openshell port forward
After=docker.service network-online.target
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
User=root
ExecStart=/usr/local/bin/openshell forward start --background 127.0.0.1:18789 <sandbox-name>
ExecStop=/usr/local/bin/openshell forward stop 18789 <sandbox-name>

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now nemoclaw-forward.service
```

Replace `<sandbox-name>` with your actual sandbox name. Verify with `systemctl status nemoclaw-forward`.

---

## Part 2: Install Caddy (Reverse Proxy + TLS)

Caddy runs directly on the host (not in a container) and proxies to the openshell forward at `127.0.0.1:18789`.

### 2.1 -- Install Caddy

```bash
apt install -y debian-keyring debian-archive-keyring apt-transport-https curl
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
  | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
  | tee /etc/apt/sources.list.d/caddy-stable.list
apt update && apt install caddy
```

### 2.2 -- Configure Caddyfile

```bash
cat > /etc/caddy/Caddyfile << 'EOF'
domain.example.com {
    handle /api/status {
        rewrite * /
        reverse_proxy localhost:18789
    }
    reverse_proxy localhost:18789
}
EOF

systemctl restart caddy
systemctl status caddy
```

Replace `domain.example.com` with your actual hostname.

The `/api/status` rewrite shim maps the ibl.ai platform's health-check path to `/` (the OpenClaw Control UI page), which returns 200 when the gateway is up. NemoClaw does not expose a `/api/status` endpoint -- this shim maintains compatibility with the platform's connectivity checks.

After restart, Caddy will automatically obtain a Let's Encrypt TLS certificate. If it fails:

```bash
journalctl -u caddy --no-pager -n 50
```

See [OpenClaw Part 2](server-setup.md#part-2-install-caddy-reverse-proxy--tls) for the common ACME pitfalls (DNS mismatch, rate limits, firewall).

---

## Part 3: Firewall

Identical to OpenClaw -- see [OpenClaw Part 3](server-setup.md#part-3-firewall). Summary:

| Direction | Protocol | Port | Source                   | Purpose        |
| --------- | -------- | ---- | ------------------------ | -------------- |
| Inbound   | TCP      | 22   | Management IPs           | SSH            |
| Inbound   | TCP      | 80   | `0.0.0.0/0`              | ACME challenge |
| Inbound   | TCP      | 443  | `0.0.0.0/0` or allowlist | HTTPS          |

Port `18789` should **not** be exposed on the cloud firewall -- all external traffic goes through Caddy on 443.

---

## Part 4: Hostname Access Configuration

By default the NemoClaw gateway only accepts browser origins of `http://127.0.0.1:18789`. Opening the Control UI at `https://domain.example.com` produces:

> `origin not allowed (open the Control UI from the gateway host or allow it in gateway.controlUi.allowedOrigins)`

The fix is to set `CHAT_UI_URL` **before** running `nemoclaw onboard` -- the installer bakes that origin into the sandbox's `gateway.controlUi.allowedOrigins` at image-build time. Setting `CHAT_UI_URL` after onboarding has no effect on the live sandbox.

### Setting `CHAT_UI_URL` before onboarding

Export the variable, then run the installer or onboard command. On a fresh install this should already be done -- see [Step 1.1](#11----ssh-in-and-set-chat_ui_url).

```bash
export CHAT_UI_URL="https://domain.example.com"
echo "export CHAT_UI_URL=$CHAT_UI_URL" >> ~/.bashrc   # survive new SSH sessions

# Fresh install:
curl -fsSL https://www.nvidia.com/nemoclaw.sh | bash

# Or, if nemoclaw is already installed but no sandbox has been onboarded yet:
nemoclaw onboard
```

Verify after onboarding:

```bash
nemoclaw <sandbox-name> connect
openclaw config get gateway.controlUi.allowedOrigins
# Should include https://domain.example.com
exit
```

### If you've already onboarded without `CHAT_UI_URL`

Rebuild the sandbox with the variable set. `nemoclaw <sandbox-name> rebuild` preserves state but re-runs the parts of onboarding that bake into the image:

```bash
export CHAT_UI_URL="https://domain.example.com"
echo "export CHAT_UI_URL=$CHAT_UI_URL" >> ~/.bashrc
nemoclaw <sandbox-name> rebuild --yes
```

After the rebuild completes, verify the allowlist as above.

### Entering the sandbox for diagnostics

To inspect OpenClaw config or run `openclaw` commands against the running sandbox, drop into the sandbox shell:

```bash
nemoclaw <sandbox-name> connect
# You are now inside the sandbox. `openclaw`, `openclaw config get`, etc. are on PATH.
```

There is **no** `openshell exec <sandbox> -- <cmd>` form in NemoClaw -- use `nemoclaw <sandbox-name> connect` and run commands interactively. `/sandbox/.openclaw/openclaw.json` is root-owned and read-only by design, so do not try to edit it directly; always flow config through `CHAT_UI_URL` and `nemoclaw onboard` / `rebuild`.

---

## Part 5: Validate

### 5.1 -- Health check

```bash
# From the host (hits the openshell forward → sandbox gateway)
curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:18789/
# Expected: 200

# Through Caddy + TLS
curl -s -o /dev/null -w "%{http_code}" https://domain.example.com/api/status
# Expected: 200
```

### 5.2 -- Control UI

Open `https://domain.example.com/?token=<gateway-token>` in a browser. First access through Caddy will show "pairing required" (same as OpenClaw -- reverse-proxied connections are not auto-approved). Approve from inside the sandbox:

```bash
nemoclaw <sandbox-name> connect
# Inside the sandbox:
openclaw devices list
openclaw devices approve <requestId>
```

### 5.3 -- Chat test

In the Control UI, send a test message. You should get a streaming response from the configured model.

**Full stack confirmed:** Browser → Caddy (TLS) → openshell forward → OpenClaw gateway (inside sandbox) → NemoClaw plugin → inference provider.

---

## Part 6: Connect to ibl.ai

The platform-side integration is identical for NemoClaw and OpenClaw -- the gateway protocol is the same. Follow:

- [OpenClaw Part 5.1 -- Register claw instance](server-setup.md#51----register-claw-instance)
- [OpenClaw Part 5.2 -- Generate and store device keypair](server-setup.md#52----generate-and-store-device-keypair)
- [OpenClaw Part 5.3 -- Push config](server-setup.md#53----push-config)
- [OpenClaw Part 5.4 -- Test chat through the platform](server-setup.md#54----test-chat-through-the-platform)

One gotcha: when the ibl.ai backend pushes config via the gateway, the changes are applied to the OpenClaw instance **inside the sandbox**. To inspect the effective config, drop in with `nemoclaw <sandbox-name> connect` and run `openclaw config get` -- the `~/.openclaw/openclaw.json` on the host is not the live config.

---

## Monitoring and Diagnostics

### Live log tailing

```bash
# Sandbox / gateway logs (WebSocket connects, chat requests, provider errors)
nemoclaw <sandbox-name> logs --follow

# Caddy logs (incoming HTTPS requests, TLS issues)
journalctl -u caddy -f

# openshell forward status
openshell forward list
```

### Quick health checks

```bash
# Gateway alive (via forward)?
curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:18789/
# Expected: 200

# Gateway status / connected devices (run inside the sandbox)
nemoclaw <sandbox-name> connect
# then inside: `openclaw health --json` and `openclaw devices list`

# Caddy + TLS working?
curl -s -o /dev/null -w "%{http_code}" https://domain.example.com/api/status
# Expected: 200

# Disk/memory
df -h / && free -h
```

### Enter the sandbox TUI

```bash
openshell term <sandbox-name>
# or
openclaw tui          # from within the sandbox
```

---

## Keeping NemoClaw Updated

```bash
nemoclaw --version
nemoclaw update
nemoclaw <sandbox-name> restart
```

Avoid `npm update -g openclaw` directly -- NemoClaw manages the OpenClaw version inside the sandbox and a mismatched manual upgrade can desync the plugin.

**Caution:** sandbox recreation **wipes paired devices** and **resets the openshell forward**. After a major NemoClaw upgrade, re-run the systemd forward service and re-approve the ibl.ai platform's device identity. See [OpenClaw -- Device Re-Pairing](server-setup.md#device-re-pairing-after-gateway-restarts--updates) for the procedure.

---

## Snags Reference

| #   | Issue                                                                                                            | Root cause                                                                                                                                      | Fix                                                                                                                                                                |
| --- | ---------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| 1   | `origin not allowed (open the Control UI from the gateway host or allow it in gateway.controlUi.allowedOrigins)` | `CHAT_UI_URL` was not exported before `nemoclaw onboard`, so the sandbox was baked with the default allowlist `["http://127.0.0.1:18789"]` only | Export `CHAT_UI_URL` and rebuild: `nemoclaw <sandbox> rebuild --yes`. See [Part 4](#part-4-hostname-access-configuration)                                          |
| 2   | `curl http://127.0.0.1:18789/` returns connection refused                                                        | openshell forward not running (common after sandbox recreate)                                                                                   | `openshell forward start --background 127.0.0.1:18789 <sandbox-name>`                                                                                              |
| 3   | Forward is lost after reboot                                                                                     | systemd unit not installed for the forward                                                                                                      | Install `nemoclaw-forward.service`. See [Step 1.6](#16----persistence-across-reboots)                                                                              |
| 4   | Host-side `~/.openclaw/openclaw.json` edits have no effect                                                       | That file is on the host; the live config lives inside the sandbox. The sandbox config is also read-only                                        | Use `nemoclaw <sandbox> connect` and `openclaw config get` to inspect. Change origins by re-exporting `CHAT_UI_URL` and running `nemoclaw <sandbox> rebuild --yes` |
| 5   | `missing scope: operator.read` on platform config push                                                           | Same as OpenClaw -- device identity signing not wired up                                                                                        | Provision the Ed25519 keypair. See [OpenClaw Part 5.2](server-setup.md#52----generate-and-store-device-keypair)                                                    |
| 6   | `NOT_PAIRED` after `nemoclaw update`                                                                             | Sandbox recreated, paired devices wiped                                                                                                         | Re-pair. See [OpenClaw -- Device Re-Pairing](server-setup.md#device-re-pairing-after-gateway-restarts--updates)                                                    |
| 7   | Let's Encrypt ACME fails on Caddy startup                                                                        | DNS / firewall not ready                                                                                                                        | See [OpenClaw Part 3](server-setup.md#part-3-firewall)                                                                                                             |

---

Next: **[Connect to the ibl.ai Platform →](platform-integration.md)**
