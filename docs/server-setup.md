# Server Setup

Deploy an OpenClaw gateway on a VPS and expose it over HTTPS with automatic TLS certificates.

---

## What You Need

1. A VPS or dedicated server (minimum: 2 vCPU, 4 GB RAM). Hetzner CX22 (~$4/mo) or equivalent.
2. A domain or subdomain pointing to your server's IP (e.g. `claw.yourcompany.com`)
3. An Anthropic API key (or other LLM provider key)
4. Ports 80 and 443 open on your firewall
5. Your ibl.ai platform org key and API credentials

> **Important:** DNS and firewall must be correctly configured _before_ installing Caddy. Let's Encrypt ACME challenges will fail if DNS doesn't resolve to your server's actual IP or if ports 80/443 are blocked. After 5 failed attempts, Let's Encrypt rate-limits the domain for 1 hour.
>
> Before proceeding, verify:
> - DNS A record points to your server's real IP: `dig claw.yourcompany.com +short`
> - Port 80 open inbound from `0.0.0.0/0` (for the `http-01` ACME challenge)
> - Port 443 open inbound (for HTTPS traffic)

---

## Part 1: Install OpenClaw

### 1.1 -- SSH into your server and install Node.js

```bash
ssh root@your-server-ip

# Install Node.js 22
curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
apt-get install -y nodejs
node --version  # should show v22.x.x
```

### 1.2 -- Install OpenClaw

```bash
npm install -g openclaw@latest
openclaw --version
```

### 1.3 -- Generate a gateway token

```bash
export OPENCLAW_GATEWAY_TOKEN=$(openssl rand -hex 32)
echo "$OPENCLAW_GATEWAY_TOKEN"
```

Save this token -- you'll need it when connecting to the ibl.ai platform.

Persist it so it survives reboots and future SSH sessions:

```bash
echo "export OPENCLAW_GATEWAY_TOKEN=$OPENCLAW_GATEWAY_TOKEN" >> ~/.bashrc
```

> **Why persist?** If the token is only exported in the current shell, commands like `openclaw devices list` will fail with `MissingEnvVarError` in new SSH sessions.

### 1.4 -- Configure OpenClaw

The recommended approach is to use the onboarding wizard, which walks you through configuration, API key setup, workspace creation, and service installation interactively:

```bash
openclaw onboard
```

During onboarding, use these settings:
- **LLM provider**: Select your provider (e.g. Anthropic) and enter your API key when prompted
- **Gateway port**: `18789`
- **Gateway binding**: `loopback` (the reverse proxy handles external access)
- **Authentication**: `token`, using the token from step 1.3
- **Service installation**: Select **yes** to install the gateway as a systemd service

After onboarding, add your domain to the Control UI allowlist:

```bash
openclaw config set gateway.controlUi.allowedOrigins '["https://YOUR-DOMAIN-HERE"]'
```

Replace `YOUR-DOMAIN-HERE` with your actual domain (e.g. `claw.yourcompany.com`). Then skip ahead to [Part 2: Set Up TLS with Caddy](#part-2-set-up-tls-with-caddy).

See the [onboard CLI docs](https://docs.openclaw.ai/cli/onboard) for the full list of options.

#### Alternative: Manual configuration

If you prefer to set things up manually, write the config file and set credentials directly.

**1.4a -- Write the config:**

```bash
mkdir -p ~/.openclaw

cat > ~/.openclaw/openclaw.json << 'OCEOF'
{
  "auth": {
    "profiles": {
      "anthropic:default": {
        "provider": "anthropic",
        "mode": "api_key"
      }
    }
  },
  "agents": {
    "defaults": {
      "model": {
        "primary": "anthropic/claude-sonnet-4-5-20250929",
        "fallbacks": ["anthropic/claude-haiku-4-5-20251001"]
      },
      "workspace": "/root/.openclaw/workspace"
    }
  },
  "session": {
    "dmScope": "per-channel-peer"
  },
  "gateway": {
    "port": 18789,
    "mode": "local",
    "bind": "loopback",
    "controlUi": {
      "allowedOrigins": ["https://YOUR-DOMAIN-HERE"]
    },
    "auth": {
      "mode": "token",
      "token": "${OPENCLAW_GATEWAY_TOKEN}"
    }
  }
}
OCEOF
```

Replace `YOUR-DOMAIN-HERE` with your actual domain (e.g. `claw.yourcompany.com`).

**Configuration notes:**

- `session.dmScope: "per-channel-peer"` is a security best practice for multi-user setups -- each DM conversation gets its own session scope.
- `gateway.bind: "loopback"` means the gateway only listens on `127.0.0.1`. All external traffic goes through Caddy.
- OpenClaw normalizes date-stamped model IDs to short aliases (e.g. `claude-sonnet-4-20250514` becomes `claude-sonnet-4-6`). Use the format your provider expects.

**Optional: model fallbacks** -- to prevent hard failures when the primary LLM provider has an outage, add fallback models:

```json
"model": {
    "primary": "anthropic/claude-sonnet-4-5-20250929",
    "fallbacks": ["anthropic/claude-haiku-4-5-20251001", "openai/gpt-5"]
}
```

This is especially recommended for multi-agent setups where the probability of hitting an API error scales with the number of agents.

**1.4b -- Set your Anthropic API key:**

```bash
export ANTHROPIC_API_KEY=<your-key>
echo "export ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY" >> ~/.bashrc
```

**1.4c -- Set up the workspace:**

```bash
mkdir -p /root/.openclaw/workspace
```

---

## Part 2: Set Up TLS with Caddy

OpenClaw listens on localhost only. You need a reverse proxy with TLS in front of it. Caddy handles TLS certificates automatically via Let's Encrypt.

**Why Caddy must run on the host (not in Docker):** Caddy must run directly on the host so that TCP connections to OpenClaw arrive from `127.0.0.1`. This preserves loopback auto-approval for device identity. If Caddy ran in a Docker container, it would connect via the Docker bridge network (172.x.x.x) and OpenClaw would treat it as a remote connection.

### 2.1 -- Install Caddy

```bash
apt install -y debian-keyring debian-archive-keyring apt-transport-https curl
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
  | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
  | tee /etc/apt/sources.list.d/caddy-stable.list
apt update
apt install caddy
```

### 2.2 -- Configure Caddy

```bash
cat > /etc/caddy/Caddyfile << 'EOF'
your-domain.example.com {
    handle /api/status {
        rewrite * /
        reverse_proxy localhost:18789
    }
    reverse_proxy localhost:18789
}
EOF
```

Replace `your-domain.example.com` with your actual domain.

> The `/api/status` rewrite maps the platform's health check path to `/` (the OpenClaw Control UI page), which returns 200 when the gateway is up. OpenClaw doesn't have a native `/api/status` endpoint -- this shim maintains compatibility with the ibl.ai platform's connectivity checks.

### 2.3 -- Start Caddy

```bash
systemctl restart caddy
systemctl enable caddy
```

After restart, Caddy will automatically obtain a Let's Encrypt TLS certificate. Check logs if it doesn't work:

```bash
journalctl -u caddy --no-pager -n 50
```

### 2.4 -- Verify TLS

```bash
curl -s -o /dev/null -w "%{http_code}" https://your-domain.example.com/api/status
# Should return 200
```

---

## Part 3: Run OpenClaw as a Service

If you used `openclaw onboard` and selected **yes** for service installation in step 1.4, the systemd service is already created. Skip to [3.2 -- Enable lingering](#32----enable-lingering).

### 3.1 -- Create a systemd service (manual path only)

```bash
mkdir -p ~/.config/systemd/user

cat > ~/.config/systemd/user/openclaw-gateway.service << EOF
[Unit]
Description=OpenClaw Gateway
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/openclaw gateway --port 18789
Restart=always
RestartSec=5
Environment=OPENCLAW_GATEWAY_TOKEN=$OPENCLAW_GATEWAY_TOKEN

[Install]
WantedBy=default.target
EOF

systemctl --user daemon-reload
systemctl --user enable openclaw-gateway
systemctl --user start openclaw-gateway
```

### 3.2 -- Enable lingering

```bash
loginctl enable-linger root
```

> **Why is this required?** OpenClaw runs as a user-level systemd service. Without lingering, systemd kills the service when the last SSH session closes. The gateway appears healthy while you're connected but silently dies after you disconnect. Verify with: `loginctl show-user root 2>/dev/null | grep Linger` -- should show `Linger=yes`.

### 3.3 -- Verify the gateway is running

```bash
systemctl --user status openclaw-gateway
openclaw health --json
# Should show: {"ok": true, ...}
```

---

## Part 4: Firewall Configuration

### Cloud firewall (Hetzner, AWS, etc.)

Set these rules in your cloud provider's firewall:

| Direction | Protocol | Port | Source | Purpose |
|---|---|---|---|---|
| Inbound | TCP | 22 | Your management IPs | SSH |
| Inbound | TCP | 80 | `0.0.0.0/0` | ACME challenge (Let's Encrypt) |
| Inbound | TCP | 443 | `0.0.0.0/0` or allowlist | HTTPS traffic |

**If restricting port 443 to specific IPs**, you must include:
- The ibl.ai platform server's outbound IP (find it with `curl -s ifconfig.me` from the platform server)
- Your own IP for Control UI browser access
- Any VPN egress IPs used by your team

### Host firewall (UFW)

```bash
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable
```

Both the cloud firewall (network level) and host firewall must allow traffic for it to reach Caddy.

---

## Validation

### Health check

```bash
curl -s -o /dev/null -w "%{http_code}" https://your-domain.example.com/api/status
# Expected: 200
```

### Control UI

Open in browser: `https://your-domain.example.com/?token=<gateway-token>`

The first browser access through the reverse proxy will show "pairing required" -- browser devices connecting through the proxy aren't auto-approved (only loopback connections are). Approve the browser device:

```bash
# On the server:
openclaw devices list
openclaw devices approve <requestId>
```

Each browser profile generates a unique device ID. This is a one-time step per browser. Do **not** use `dangerouslyDisableDeviceAuth`.

### Chat test

In the Control UI, send a test message. You should get a response from the configured LLM.

**Full stack confirmed:** Browser → Caddy (TLS) → OpenClaw Gateway → LLM Provider.

---

## Monitoring

### Live log tailing

```bash
# Gateway logs (WebSocket connects, chat requests, LLM API errors)
journalctl --user -u openclaw-gateway -f

# Caddy logs (incoming HTTPS requests, TLS issues)
journalctl -u caddy -f
```

### What to look for in gateway logs

| Log pattern | Meaning |
|---|---|
| `protocol 3` | WebSocket handshake succeeded |
| `chat.send` | Chat request sent to LLM provider |
| `error` / `ECONNREFUSED` | LLM API call failed (key issue, rate limit, outage) |
| `missing scope` | Device identity signing not working -- check keypair config |

### Quick health checks

```bash
# Gateway alive?
curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:18789/
# Expected: 200

# Structured health status
openclaw health --json

# Connected devices
openclaw devices list

# Caddy + TLS working?
curl -s -o /dev/null -w "%{http_code}" https://your-domain.example.com/api/status
# Expected: 200

# Anthropic key still valid?
curl -s -o /dev/null -w "%{http_code}" \
  -H "x-api-key: $ANTHROPIC_API_KEY" \
  -H "anthropic-version: 2023-06-01" \
  https://api.anthropic.com/v1/models
# Expected: 200

# Disk/memory
df -h / && free -h
```

---

## Keeping Updated

```bash
# Update OpenClaw
openclaw update

# Check version
openclaw --version

# Restart after update
systemctl --user restart openclaw-gateway
```

> **Caution:** OpenClaw updates may wipe the paired devices list, requiring re-pairing. Back up `~/.openclaw/` before major version upgrades. See [Device Re-Pairing](#device-re-pairing) below.

---

## Device Re-Pairing

OpenClaw gateway updates or restarts can wipe the paired devices list. When this happens, all mentors on that server fail with `PAIRING_REQUIRED` / `NOT_PAIRED` errors.

Users see: _"The mentor is starting up, please wait..."_ → _"The mentor is currently unavailable. Please try again later."_

This affects **all mentors** linked to the server -- device identity is per claw instance, not per mentor. One re-pairing fixes all mentors on that server.

### How to re-pair

1. **Trigger a connection attempt** -- send any message to any mentor linked to the affected server. This creates a pending pairing request on the gateway.

2. **SSH into the server** and approve:

```bash
# List devices -- look for the "Pending" section
openclaw devices list

# Approve the pending request (use the requestId, NOT the device ID)
openclaw devices approve <requestId>
```

3. **Retry the chat** -- the next message should connect successfully. All mentors on this server are now fixed.

---

## Multi-Agent Setup (Optional)

The default config creates a single agent. To run multiple agents on the same gateway (e.g. tutor, course-creator, admissions):

```bash
openclaw agents add tutor-agent
openclaw agents add course-creator-agent
```

Each agent gets its own workspace and agent directory. More agents means more concurrent LLM API calls -- consider adding model fallbacks (see [step 1.4](#14----configure-openclaw)) if running multiple agents.

---

## Troubleshooting

| Problem | Likely cause | Fix |
|---|---|---|
| Let's Encrypt ACME fails | DNS doesn't resolve to server IP, or ports 80/443 blocked | Fix DNS and firewall _before_ starting Caddy. If rate-limited, wait 1 hour. |
| Control UI "origin not allowed" | Domain not in `controlUi.allowedOrigins` | `openclaw config set gateway.controlUi.allowedOrigins '["https://your-domain"]'` then restart |
| Control UI "pairing required" | Browser device not auto-approved through reverse proxy | `openclaw devices approve <requestId>` (one-time per browser) |
| `ERR_CONNECTION_TIMED_OUT` in browser | Cloud firewall restricting port 443; your IP not allowlisted | Add your IP to the cloud firewall allowlist |
| `OPENCLAW_GATEWAY_TOKEN` not found | Token only exported in original shell | Add `export OPENCLAW_GATEWAY_TOKEN=...` to `~/.bashrc` |
| Gateway stops when SSH disconnects | `loginctl enable-linger root` not run | Run `loginctl enable-linger root` and restart the service |
| Config push "missing scope" | Device identity not configured | See [device identity setup](platform-integration.md#register-your-instance) |
| `NOT_PAIRED` after gateway update | Paired devices list wiped on update | See [Device Re-Pairing](#device-re-pairing) |
| No response in chat | Various | Check Control UI at `https://your-domain/?token=<token>` to verify response was generated. If it shows there but not in the platform, contact support. |

---

Next: **[Connect to the ibl.ai Platform →](platform-integration.md)**
