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
                    ClawLLMRunner
                         │
                    OpenClawClient (WSS + Ed25519 device identity signing)
                         │
                    Caddy (on host, TLS via Let's Encrypt)
                         │ reverse proxy to 127.0.0.1:18789
                         ▼
                    openshell forward (host ↔ sandbox)
                         │
                    OpenClaw Gateway (inside OpenShell sandbox)
                         │
                    NVIDIA NemoClaw plugin
                         │
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

The token that the ibl.ai platform will use to authenticate comes from the sandbox's OpenClaw config. Read it out:

```bash
openshell exec <sandbox-name> -- openclaw config get gateway.auth.token
```

If the wizard didn't generate one (some installers skip this), set one explicitly:

```bash
export OPENCLAW_GATEWAY_TOKEN=$(openssl rand -hex 32)
openshell exec <sandbox-name> -- openclaw config set gateway.auth.token "$OPENCLAW_GATEWAY_TOKEN"
openshell exec <sandbox-name> -- openclaw config set gateway.auth.mode token
echo "export OPENCLAW_GATEWAY_TOKEN=$OPENCLAW_GATEWAY_TOKEN" >> ~/.bashrc
```

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

By default the NemoClaw gateway only accepts browser origins of `http://127.0.0.1:18789`. To serve the Control UI as `https://domain.example.com` you need to add that origin to the allowlist. There are three approaches -- pick based on your situation.

### Option A: set `CHAT_UI_URL` before onboarding (preferred, clean setup)

If you have not yet run `nemoclaw onboard`, set the environment variable first (see [Prerequisites](#critical-set-chat_ui_url-before-onboarding)):

```bash
export CHAT_UI_URL="https://domain.example.com"
nemoclaw onboard
```

The sandbox image is built with `https://domain.example.com` in the allowlist and no further action is needed.

### Option B: patch `gateway.controlUi.allowedOrigins` on an existing sandbox

If you've already onboarded with the default allowlist, add the hostname without recreating the sandbox:

```bash
openshell exec <sandbox-name> -- openclaw config set \
  gateway.controlUi.allowedOrigins \
  '["https://domain.example.com","http://127.0.0.1:18789"]'

# Restart the gateway inside the sandbox so the new config takes effect
openshell exec <sandbox-name> -- systemctl --user restart openclaw-gateway

# Verify
openshell exec <sandbox-name> -- openclaw config get gateway.controlUi.allowedOrigins
```

Keep `http://127.0.0.1:18789` in the list so that on-host diagnostic commands (`curl http://127.0.0.1:18789/`) still work.

### Option C: direct LAN access without Caddy (not recommended for production)

If you want to reach the gateway at `http://domain.example.com:18789` directly -- without Caddy / without TLS -- two things need to change:

1. **Rebind the openshell forward to `0.0.0.0`** so it accepts connections from any interface, not just loopback:

   ```bash
   openshell forward stop 18789 <sandbox-name>
   openshell forward start --background 0.0.0.0:18789 <sandbox-name>
   ```

2. **Set the gateway bind mode to `lan`** (inside the sandbox). NemoClaw / OpenClaw accept named modes only -- `loopback`, `lan`, `tailnet`, `auto`, `custom` -- not raw IPs like `0.0.0.0`:

   ```bash
   openshell exec <sandbox-name> -- openclaw config set gateway.bind lan
   openshell exec <sandbox-name> -- systemctl --user restart openclaw-gateway
   ```

3. **Add the LAN origin to the allowlist:**

   ```bash
   openshell exec <sandbox-name> -- openclaw config set \
     gateway.controlUi.allowedOrigins \
     '["http://domain.example.com:18789","http://127.0.0.1:18789"]'
   ```

4. **Open port 18789 on the cloud firewall + UFW** (restricted to trusted source IPs):

   ```bash
   ufw allow from <trusted-ip> to any port 18789 proto tcp
   ```

Prefer Option A or B. Exposing the gateway on a plaintext port over the internet bypasses Caddy's TLS and is not the supported deployment.

### Why named bind modes, not `0.0.0.0`

OpenClaw validates the bind value against a fixed set of modes. Setting `OPENCLAW_GATEWAY_BIND=0.0.0.0` produces `Invalid --bind (use "loopback", "lan", "tailnet", "auto", or "custom")` and the gateway refuses to start. The modes are:

| Mode       | Behavior                                                           |
| ---------- | ------------------------------------------------------------------ |
| `loopback` | Listen on `127.0.0.1` only -- use this when Caddy proxies in front |
| `lan`      | Listen on private network interfaces -- for direct LAN access      |
| `tailnet`  | Listen on the Tailscale interface only                             |
| `auto`     | Pick based on detected network context                             |
| `custom`   | Listen on an explicit interface set via `gateway.bindAddresses`    |

For the Caddy-fronted deployment this guide describes, leave it on `loopback` (the default).

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

Open `https://domain.example.com/?token=<gateway-token>` in a browser. First access through Caddy will show "pairing required" (same as OpenClaw -- reverse-proxied connections are not auto-approved). Approve on the server:

```bash
openshell exec <sandbox-name> -- openclaw devices list
openshell exec <sandbox-name> -- openclaw devices approve <requestId>
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

One gotcha: when the ibl.ai backend pushes config via the gateway, the changes are applied to the OpenClaw instance **inside the sandbox**. To inspect the effective config, use `openshell exec <sandbox-name> -- openclaw config get` -- the `~/.openclaw/openclaw.json` on the host is not the live config.

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

# Gateway status inside sandbox
openshell exec <sandbox-name> -- openclaw health --json

# Connected devices
openshell exec <sandbox-name> -- openclaw devices list

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

| #   | Issue                                                                    | Root cause                                                                                        | Fix                                                                                                                                                                |
| --- | ------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| 1   | Browser origin blocked when opening `https://domain.example.com/`        | `CHAT_UI_URL` not set before `nemoclaw onboard`; allowlist contains only `http://127.0.0.1:18789` | Option A (re-onboard with `CHAT_UI_URL`) or Option B (`openclaw config set gateway.controlUi.allowedOrigins`). See [Part 4](#part-4-hostname-access-configuration) |
| 2   | `curl http://127.0.0.1:18789/` returns connection refused                | openshell forward not running (common after sandbox recreate)                                     | `openshell forward start --background 127.0.0.1:18789 <sandbox-name>`                                                                                              |
| 3   | Forward is lost after reboot                                             | systemd unit not installed for the forward                                                        | Install `nemoclaw-forward.service`. See [Step 1.6](#16----persistence-across-reboots)                                                                              |
| 4   | `Invalid --bind (use "loopback", "lan", "tailnet", "auto", or "custom")` | Set `gateway.bind` to a raw IP (`0.0.0.0`)                                                        | Use a named mode -- `loopback` for Caddy-fronted, `lan` for direct LAN                                                                                             |
| 5   | `~/.openclaw/openclaw.json` edits have no effect                         | That file is on the host; the live config lives inside the sandbox                                | Use `openshell exec <sandbox-name> -- openclaw config set/get`                                                                                                     |
| 6   | `missing scope: operator.read` on platform config push                   | Same as OpenClaw -- device identity signing not wired up                                          | Provision the Ed25519 keypair. See [OpenClaw Part 5.2](server-setup.md#52----generate-and-store-device-keypair)                                                    |
| 7   | `NOT_PAIRED` after `nemoclaw update`                                     | Sandbox recreated, paired devices wiped                                                           | Re-pair. See [OpenClaw -- Device Re-Pairing](server-setup.md#device-re-pairing-after-gateway-restarts--updates)                                                    |
| 8   | Let's Encrypt ACME fails on Caddy startup                                | DNS / firewall not ready                                                                          | See [OpenClaw Part 3](server-setup.md#part-3-firewall)                                                                                                             |

---

Next: **[Connect to the ibl.ai Platform →](platform-integration.md)**
