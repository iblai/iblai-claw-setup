#!/usr/bin/env bash
#
# install.sh -- one-command server setup for a claw gateway + ibl.ai.
#
# Installs and wires up, on a fresh Debian/Ubuntu host:
#   * OpenClaw (host systemd service) OR NemoClaw (Docker/OpenShell sandbox)
#   * Caddy reverse proxy with automatic Let's Encrypt TLS
#   * the host firewall (UFW)
#   * the optional iblai-openclaw-extensions plugin
#   * an Ed25519 device-identity keypair for the ibl.ai platform
#
# and prints the gateway token + keypair. If you pass IBLAI_API_KEY it also seeds
# the ibl.ai platform (claw instance + mentor + wiring, incl. the device key) via
# scripts/seed_claw_mentor.py; otherwise it prints the API call for you to run.
#
# Usage -- HARNESS_TYPE is the only variable you ever set; everything else is asked
# interactively (and cached in ~/.cache/iblai-claw-setup for next time):
#   curl -fsSL https://raw.githubusercontent.com/iblai/claw-setup/main/install.sh | bash
#     # OpenClaw (default)
#   curl -fsSL https://raw.githubusercontent.com/iblai/claw-setup/main/install.sh | HARNESS_TYPE=nemoclaw bash
#     # NemoClaw
#
# You will be prompted for:
#   - the domain served over HTTPS (its DNS A record must already point at this host)
#   - OpenClaw: the LLM provider + API key + model  (NemoClaw asks these in its own wizard)
#   - NemoClaw: the sandbox name
#   - whether to install the iblai-openclaw-extensions plugin
#   - optionally, whether to register + seed this instance on the ibl.ai platform
#
# The UFW firewall (22/80/443, plus the openshell rule on NemoClaw) is set up
# automatically -- pass SETUP_FIREWALL=no to skip it.
#
# Platform seeding (optional; runs only when IBLAI_API_KEY is set):
#   IBLAI_API_KEY       ibl.ai platform API key -- presence enables seeding
#   IBLAI_HOST          env var only (not prompted); default: https://base.manager.iblai.app
#   IBLAI_ORG           tenant/org slug, default: main
#   IBLAI_USER_ID       mentor owner, default: admin
#   IBLAI_CLAW_TYPE     platform claw_type, default: openclaw
#   AGENT_NAME       default: Claw Agent  (also AGENT_DESCRIPTION, AGENT_ID, AGENT_CONFIG)
#
# Re-running is safe: it never regenerates an existing gateway token or device
# key (doing so would break platform pairing) and skips already-installed steps.
#
# All prompts (and the NemoClaw onboarding wizard) read from /dev/tty, so the
# curl | bash form is fully interactive. See docs/server-setup.md and docs/nemoclaw-setup.md.
set -euo pipefail

# ---- configuration -----------------------------------------------------------
# Each value comes from the environment (pre-set to skip its prompt), an
# interactive prompt, or a default -- collect_config() below resolves them.
HARNESS_TYPE="${HARNESS_TYPE:-}"
DOMAIN="${DOMAIN:-}"
LLM_PROVIDER="${LLM_PROVIDER:-}"
LLM_API_KEY="${LLM_API_KEY:-}"
LLM_KEY_ENV="${LLM_KEY_ENV:-}"
MODEL="${MODEL:-}"
SANDBOX_NAME="${SANDBOX_NAME:-}"
INSTALL_PLUGIN="${INSTALL_PLUGIN:-}"
SETUP_FIREWALL="${SETUP_FIREWALL:-}"

# Platform seeding (optional -- runs when IBLAI_API_KEY ends up set).
IBLAI_API_KEY="${IBLAI_API_KEY:-}"
IBLAI_HOST="${IBLAI_HOST:-}"
IBLAI_ORG="${IBLAI_ORG:-}"
IBLAI_USER_ID="${IBLAI_USER_ID:-}"
IBLAI_CLAW_TYPE="${IBLAI_CLAW_TYPE:-}"
AGENT_NAME="${AGENT_NAME:-}"
AGENT_DESCRIPTION="${AGENT_DESCRIPTION:-}"
AGENT_ID="${AGENT_ID:-}"
AGENT_CONFIG="${AGENT_CONFIG:-}"
SEED_URL="${SEED_URL:-https://raw.githubusercontent.com/iblai/claw-setup/main/scripts/seed_claw_mentor.py}"

GATEWAY_PORT=18789
OPENCLAW_HOME="${HOME}/.openclaw"
DEVICE_KEY_PEM="${OPENCLAW_HOME}/platform_device_identity.pem"
PLUGIN_REPO="https://github.com/iblai/iblai-openclaw-extensions-plugin.git"
PLUGIN_DIR="/opt/iblai-openclaw-extensions"

# Cache previously entered (non-secret) answers and reuse them as prompt defaults.
CACHE_FILE="${XDG_CACHE_HOME:-$HOME/.cache}/iblai-claw-setup"
CACHE_KEYS=(HARNESS_TYPE DOMAIN LLM_PROVIDER MODEL SANDBOX_NAME INSTALL_PLUGIN SETUP_FIREWALL IBLAI_HOST IBLAI_ORG IBLAI_USER_ID IBLAI_CLAW_TYPE AGENT_NAME AGENT_ID)
declare -A CACHED=()
if [ -f "$CACHE_FILE" ]; then
  while IFS='=' read -r _k _v; do [ -n "$_k" ] && CACHED["$_k"]="$_v"; done < "$CACHE_FILE"
fi
save_cache() {
  mkdir -p "$(dirname "$CACHE_FILE")"
  local k
  for k in "${CACHE_KEYS[@]}"; do printf '%s=%s\n' "$k" "${!k}"; done > "$CACHE_FILE"
}

log()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n'  "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n'  "$*" >&2; exit 1; }

usage() { awk 'NR==1{next} /^#/{sub(/^#[[:space:]]?/,""); print; next} {exit}' "$0" 2>/dev/null || true; }

# True when the controlling terminal is readable (works even under curl|bash).
have_tty() { (exec </dev/tty) 2>/dev/null; }

# Run an interactive command attached to the real terminal even under curl|bash.
tty_run() {
  if have_tty; then "$@" </dev/tty >/dev/tty 2>&1; else "$@"; fi
}

# prompt VAR "message" [default] [secret] -- keep an env-provided value, else ask
# on the terminal (blank input takes the default). A terminal is required (main
# checks have_tty up front and errors out otherwise).
prompt() {
  local var="$1" msg="$2" def="${3-}" secret="${4-}" ans
  [ -n "${!var-}" ] && return 0
  [ -n "${CACHED[$var]:-}" ] && def="${CACHED[$var]}"
  if [ -n "$secret" ]; then
    printf '%s: ' "$msg" >/dev/tty
    read -rs ans </dev/tty; printf '\n' >/dev/tty
  elif [ -n "$def" ]; then
    printf '%s [%s]: ' "$msg" "$def" >/dev/tty; read -r ans </dev/tty
  else
    printf '%s: ' "$msg" >/dev/tty; read -r ans </dev/tty
  fi
  printf -v "$var" '%s' "${ans:-$def}"
  save_cache
}

# confirm "message" [yes|no] -- returns 0 for yes (blank input takes the default).
confirm() {
  local msg="$1" def="${2:-no}" ans hint="[y/N]"
  [ "$def" = yes ] && hint="[Y/n]"
  printf '%s %s ' "$msg" "$hint" >/dev/tty; read -r ans </dev/tty
  case "${ans:-$def}" in [yY]*) return 0 ;; *) return 1 ;; esac
}

# Append an export to ~/.bashrc once (survives new SSH sessions).
persist_env() {
  local key="$1" val="$2"
  grep -q "^export ${key}=" "${HOME}/.bashrc" 2>/dev/null \
    || printf 'export %s=%s\n' "$key" "$val" >> "${HOME}/.bashrc"
}

# Escape a PEM file into a JSON string body (no surrounding quotes).
json_escape_file() {
  awk 'BEGIN{ORS=""} {gsub(/\\/,"\\\\"); gsub(/"/,"\\\""); print $0 "\\n"}' "$1"
}

# Pixel-art splash: "ibl.ai Claw Setup".
banner() {
  printf '\n\033[1;32m'
  cat <<'ART'
+-----------------------+
|   ibl.ai Claw Setup   |
+-----------------------+
ART
  printf '\033[0m\n'
}

# Gather every user-facing setting: env value > interactive prompt > default.
collect_config() {
  banner

  prompt HARNESS_TYPE "Harness type: openclaw or nemoclaw" openclaw
  case "$HARNESS_TYPE" in openclaw|nemoclaw) ;; *) die "HARNESS_TYPE must be 'openclaw' or 'nemoclaw'";; esac

  prompt DOMAIN "Domain served over HTTPS (its DNS A record must already point here)"

  # OpenClaw onboarding runs non-interactively, so collect the LLM provider + key here.
  # (NemoClaw asks its sandbox name later, in nemoclaw_install, after its own wizard.)
  if [ "$HARNESS_TYPE" = openclaw ]; then
    prompt LLM_PROVIDER "LLM provider (anthropic, openai, openrouter, google, groq, mistral, deepseek, xai)" anthropic
    local key_env model_default
    case "$LLM_PROVIDER" in
      anthropic)  key_env=ANTHROPIC_API_KEY;  model_default=anthropic/claude-sonnet-5 ;;
      openai)     key_env=OPENAI_API_KEY;     model_default=openai/gpt-5.5 ;;
      openrouter) key_env=OPENROUTER_API_KEY; model_default=openrouter/anthropic/claude-sonnet-5 ;;
      google)     key_env=GEMINI_API_KEY;     model_default=google/gemini-2.5-pro ;;
      groq)       key_env=GROQ_API_KEY;       model_default=groq/llama-3.3-70b-versatile ;;
      mistral)    key_env=MISTRAL_API_KEY;    model_default=mistral/mistral-large-latest ;;
      deepseek)   key_env=DEEPSEEK_API_KEY;   model_default=deepseek/deepseek-v4-pro ;;
      xai)        key_env=XAI_API_KEY;        model_default=xai/grok-4 ;;
      *) die "unsupported LLM_PROVIDER '$LLM_PROVIDER' (anthropic|openai|openrouter|google|groq|mistral|deepseek|xai)" ;;
    esac
    LLM_KEY_ENV="$key_env"
    prompt MODEL "Model id" "$model_default"
    prompt LLM_API_KEY "${LLM_PROVIDER} API key"
  fi

  prompt INSTALL_PLUGIN "Install the iblai-openclaw-extensions plugin? yes/no" yes

  # Optional: register + seed the ibl.ai platform in the same run. The platform
  # host is intentionally not prompted -- override it with IBLAI_HOST if needed.
  if [ -z "$IBLAI_API_KEY" ] && confirm "Register this instance on the ibl.ai platform now?" no; then
    IBLAI_SEED=yes
  fi
  if [ -n "$IBLAI_API_KEY" ] || [ "${IBLAI_SEED:-no}" = yes ]; then
    prompt IBLAI_API_KEY "ibl.ai platform API key"          # echoed on purpose (not hidden)
    prompt IBLAI_ORG "ibl.ai platform key" main
    prompt AGENT_NAME "Agent display name (the mentor shown on the platform)" "Claw Agent"
  fi

  # Defaults for anything not prompted or left blank. SANDBOX_NAME is intentionally
  # left unset here -- nemoclaw_install prompts for it after NemoClaw's own wizard.
  INSTALL_PLUGIN="${INSTALL_PLUGIN:-yes}"
  SETUP_FIREWALL="${SETUP_FIREWALL:-yes}"
  IBLAI_HOST="${IBLAI_HOST:-https://base.manager.iblai.app}"
  IBLAI_ORG="${IBLAI_ORG:-main}"
  IBLAI_USER_ID="${IBLAI_USER_ID:-admin}"
  IBLAI_CLAW_TYPE="${IBLAI_CLAW_TYPE:-openclaw}"
  AGENT_NAME="${AGENT_NAME:-Claw Agent}"
  AGENT_ID="${AGENT_ID:-main}"

  save_cache
}

# ---- checks, then gather config ----------------------------------------------
case "${1:-}" in -h|--help) usage; exit 0 ;; esac
have_tty || die "no terminal available -- this installer is interactive; run it from a shell (e.g. over SSH)"
[ "$(id -u)" -eq 0 ] || die "run as root (the setup guides assume root@server)"
command -v apt-get >/dev/null 2>&1 || die "this installer targets Debian/Ubuntu (apt not found)"

collect_config

[ -n "$DOMAIN" ] || { usage; die "DOMAIN is required"; }
if [ "$HARNESS_TYPE" = openclaw ] && [ -z "$LLM_API_KEY" ]; then
  die "an LLM API key is required for openclaw (set LLM_API_KEY or enter it at the prompt)"
fi

# ---- shared: system prep (runs first) ----------------------------------------
system_prep() {
  log "Disabling unattended-upgrades + apt timers (avoids apt lock contention)"
  systemctl stop unattended-upgrades apt-daily.service apt-daily-upgrade.service >/dev/null 2>&1 || true
  systemctl disable --now unattended-upgrades apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1 || true
  log "Installing base packages (Go)"
  apt-get update
  apt-get install -y golang-go
}

# ---- shared: Node.js 22 ------------------------------------------------------
install_node() {
  local major
  major="$(node --version 2>/dev/null | sed 's/^v//; s/\..*//')" || true
  if [ "${major:-0}" -ge 22 ] 2>/dev/null; then
    log "Node.js $(node --version) already installed"
    return
  fi
  log "Installing Node.js 22"
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
  apt-get install -y nodejs
}

# ---- shared: Ed25519 device identity (for the platform side) -----------------
gen_device_key() {
  mkdir -p "$OPENCLAW_HOME"
  if [ ! -f "$DEVICE_KEY_PEM" ]; then
    log "Generating Ed25519 device-identity keypair for the platform"
    openssl genpkey -algorithm ed25519 -out "$DEVICE_KEY_PEM"  # PKCS8 -> BEGIN PRIVATE KEY
    chmod 600 "$DEVICE_KEY_PEM"
  else
    log "Reusing existing device-identity keypair ($DEVICE_KEY_PEM)"
  fi
}

# ---- shared: Caddy + TLS -----------------------------------------------------
install_caddy() {
  if ! command -v caddy >/dev/null 2>&1; then
    log "Installing Caddy"
    apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
      | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
      | tee /etc/apt/sources.list.d/caddy-stable.list
    apt-get update && apt-get install -y caddy
  else
    log "Caddy already installed"
  fi

  # Caddyfile is fully derived from DOMAIN -- write it every run (back up any existing).
  log "Writing /etc/caddy/Caddyfile for ${DOMAIN}"
  [ -f /etc/caddy/Caddyfile ] && cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.bak
  cat > /etc/caddy/Caddyfile <<CADDY
${DOMAIN} {
    handle /api/status {
        rewrite * /
        reverse_proxy localhost:${GATEWAY_PORT}
    }
    reverse_proxy localhost:${GATEWAY_PORT}
}
CADDY
  systemctl restart caddy
}

# ---- shared: host firewall ---------------------------------------------------
setup_firewall() {
  # Always configure the firewall unless explicitly disabled with SETUP_FIREWALL=no.
  if [ "$SETUP_FIREWALL" = no ]; then log "Skipping UFW (SETUP_FIREWALL=no)"; return 0; fi
  command -v ufw >/dev/null 2>&1 || {
      log "Skipping UFW (not installed)"
      return 0
  }
  log "Configuring UFW (22, 80, 443)"
  ufw default allow outgoing
  ufw allow 22/tcp
  ufw allow 80/tcp
  ufw allow 443/tcp
  if [ "$HARNESS_TYPE" = nemoclaw ]; then
    # NemoClaw openshell gateway: sandbox bridge subnet -> host bridge gateway on 8080/tcp.
    # 172.18.0.0/16 is the default openshell Docker bridge; adjust if yours differs.
    log "Allowing NemoClaw openshell gateway (172.18.0.0/16 -> 172.18.0.1:8080/tcp)"
    ufw allow from 172.18.0.0/16 to 172.18.0.1 port 8080 proto tcp
  fi
  ufw --force enable
}

# ---- OpenClaw ----------------------------------------------------------------
openclaw_install() {
  install_node
  if ! command -v openclaw >/dev/null 2>&1; then
    log "Installing OpenClaw"
    npm install -g openclaw@latest
  else
    log "OpenClaw $(openclaw --version 2>/dev/null) already installed"
  fi

  # Gateway token: reuse the persisted one if present, else mint a fresh one.
  # Written literally into openclaw.json (chmod 600) so nothing needs the env var
  # to resolve it -- avoids the "Missing env var OPENCLAW_GATEWAY_TOKEN" warning
  # that a "${OPENCLAW_GATEWAY_TOKEN}" reference emits on every config load. The
  # value is also kept in gateway.systemd.env so re-runs can reuse it.
  local env_file="${OPENCLAW_HOME}/gateway.systemd.env"
  mkdir -p "${OPENCLAW_HOME}/workspace"
  if [ -f "$env_file" ]; then
    OPENCLAW_GATEWAY_TOKEN="$(sed -n 's/^OPENCLAW_GATEWAY_TOKEN=//p' "$env_file" | head -1)"
  fi
  if [ -z "${OPENCLAW_GATEWAY_TOKEN:-}" ]; then
    log "Generating gateway token"
    OPENCLAW_GATEWAY_TOKEN="$(openssl rand -hex 32)"
  else
    log "Reusing existing gateway token"
  fi
  persist_env OPENCLAW_GATEWAY_TOKEN "$OPENCLAW_GATEWAY_TOKEN"
  persist_env "$LLM_KEY_ENV" "$LLM_API_KEY"

  # Onboarding is non-interactive, so write the full config (provider + model +
  # gateway) up front. The provider API key is read from $LLM_KEY_ENV at runtime.
  if [ ! -f "${OPENCLAW_HOME}/openclaw.json" ]; then
    log "Writing ${OPENCLAW_HOME}/openclaw.json (provider=${LLM_PROVIDER}, model=${MODEL})"
    cat > "${OPENCLAW_HOME}/openclaw.json" <<CONF
{
  "auth": { "profiles": { "${LLM_PROVIDER}:default": { "provider": "${LLM_PROVIDER}", "mode": "api_key" } } },
  "agents": {
    "defaults": {
      "model": { "primary": "${MODEL}" },
      "workspace": "${OPENCLAW_HOME}/workspace"
    }
  },
  "commands": { "native": "auto", "nativeSkills": "auto", "restart": true, "ownerDisplay": "raw" },
  "session": { "dmScope": "per-channel-peer" },
  "gateway": {
    "port": ${GATEWAY_PORT},
    "mode": "local",
    "bind": "loopback",
    "controlUi": { "allowedOrigins": [ "https://${DOMAIN}" ] },
    "auth": { "mode": "token", "token": "${OPENCLAW_GATEWAY_TOKEN}" },
    "tailscale": { "mode": "off", "resetOnExit": false }
  }
}
CONF
    chmod 600 "${OPENCLAW_HOME}/openclaw.json"
  else
    log "openclaw.json already exists -- leaving it untouched"
  fi

  # Onboard + install the systemd user service (survives SSH logout via linger).
  # --non-interactive --accept-risk keeps onboarding from opening the chat TUI.
  # Only run it when the unit is missing so re-runs stay quiet. Export the gateway
  # token and provider key so non-interactive onboarding can use them.
  loginctl enable-linger root
  local unit="${HOME}/.config/systemd/user/openclaw-gateway.service"
  if [ ! -f "$unit" ]; then
    log "Onboarding OpenClaw + installing the gateway daemon (non-interactive)"
    env "OPENCLAW_GATEWAY_TOKEN=$OPENCLAW_GATEWAY_TOKEN" "$LLM_KEY_ENV=$LLM_API_KEY" \
      openclaw onboard --install-daemon --non-interactive --accept-risk
  else
    log "OpenClaw gateway daemon already installed -- skipping onboarding"
  fi

  # A user service does not inherit our shell env, so supply the gateway token and
  # the provider API key via an EnvironmentFile (chmod 600, kept out of the config).
  mkdir -p "${unit}.d"
  cat > "${unit}.d/10-env-file.conf" <<DROPIN
[Service]
EnvironmentFile=-${env_file}
DROPIN
  {
    printf 'OPENCLAW_GATEWAY_TOKEN=%s\n' "$OPENCLAW_GATEWAY_TOKEN"
    printf '%s=%s\n' "$LLM_KEY_ENV" "$LLM_API_KEY"
  } > "$env_file"
  chmod 600 "$env_file"

  systemctl --user daemon-reload
  systemctl --user restart openclaw-gateway

  openclaw_healthcheck
}

openclaw_plugin() {
  [ "$INSTALL_PLUGIN" = yes ] || { log "Skipping plugin (INSTALL_PLUGIN=$INSTALL_PLUGIN)"; return; }
  if openclaw plugins list 2>/dev/null | grep -q 'iblai-openclaw-extensions'; then
    log "iblai-openclaw-extensions plugin already installed"
    return
  fi
  build_plugin
  log "Installing + enabling iblai-openclaw-extensions"
  openclaw plugins install "$PLUGIN_DIR"
  openclaw plugins enable iblai-openclaw-extensions
  systemctl --user restart openclaw-gateway
}


openclaw_healthcheck() {
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${GATEWAY_PORT}/" || true)"
  [ "$code" = 200 ] && log "Gateway healthy (127.0.0.1:${GATEWAY_PORT} -> 200)" \
    || warn "Gateway health check returned '${code}' (expected 200). Check: journalctl --user -u openclaw-gateway -n 50"
}

# ---- NemoClaw ----------------------------------------------------------------
nemoclaw_install() {
  if ! command -v docker >/dev/null 2>&1; then
    log "Installing Docker"
    apt-get update && apt-get install -y docker.io
    systemctl enable --now docker
  fi
  install_node

  # Origin allowlist is baked at onboard time -> must be set BEFORE the wizard runs.
  export CHAT_UI_URL="https://${DOMAIN}"
  persist_env CHAT_UI_URL "https://${DOMAIN}"

  # NemoClaw's installer runs the onboarding wizard itself, so we must NOT onboard a
  # second time -- that created a duplicate sandbox. Install it if missing:
  if ! command -v nemoclaw >/dev/null 2>&1; then
    log "Installing NemoClaw and running its onboarding wizard"
    log "Remember the sandbox NAME you choose -- you'll confirm it right after."
    tty_run bash -c "$(curl -fsSL https://www.nvidia.com/nemoclaw.sh)"
  else
    log "NemoClaw $(nemoclaw --version 2>/dev/null) already installed"
  fi

  # Use the sandbox from that wizard. Ask for its name (cached for next time), and only
  # onboard when it doesn't already exist -- so a normal run has exactly ONE onboarding.
  prompt SANDBOX_NAME "NemoClaw sandbox name (from the wizard, or a name to create)" my-assistant
  [ -n "$SANDBOX_NAME" ] || die "a NemoClaw sandbox name is required"
  if ! nemoclaw "$SANDBOX_NAME" status >/dev/null 2>&1; then
    log "Sandbox '${SANDBOX_NAME}' not found -- onboarding it now"
    tty_run nemoclaw onboard
  fi

  # Read the gateway token straight off the host.
  OPENCLAW_GATEWAY_TOKEN="$(nemoclaw "$SANDBOX_NAME" gateway-token --quiet 2>/dev/null || true)"
  [ -n "$OPENCLAW_GATEWAY_TOKEN" ] \
    || die "could not read the gateway token for sandbox '${SANDBOX_NAME}'. If you named it differently in the wizard, re-run with SANDBOX_NAME=<that-name>."

  # Persist the host<->sandbox forward across reboots via systemd. Onboarding may
  # already have forwarded the port, so ExecStartPre stops any existing forward first
  # (the leading '-' ignores "nothing to stop") -- otherwise ExecStart fails with
  # "port already forwarded". RemainAfterExit keeps the oneshot "active".
  log "Installing nemoclaw-forward.service"
  cat > /etc/systemd/system/nemoclaw-forward.service <<UNIT
[Unit]
Description=NemoClaw openshell port forward
After=docker.service network-online.target
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
User=root
ExecStartPre=-/usr/local/bin/openshell forward stop ${GATEWAY_PORT} ${SANDBOX_NAME}
ExecStart=/usr/local/bin/openshell forward start --background 127.0.0.1:${GATEWAY_PORT} ${SANDBOX_NAME}
ExecStop=/usr/local/bin/openshell forward stop ${GATEWAY_PORT} ${SANDBOX_NAME}

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable --now nemoclaw-forward.service

  nemoclaw_healthcheck
}

nemoclaw_plugin() {
  [ "$INSTALL_PLUGIN" = yes ] || { log "Skipping plugin (INSTALL_PLUGIN=$INSTALL_PLUGIN)"; return; }
  if nemoclaw "$SANDBOX_NAME" exec --no-tty -- openclaw plugins list 2>/dev/null | grep -q 'iblai-openclaw-extensions'; then
    log "iblai-openclaw-extensions plugin already installed in sandbox"
    return
  fi
  build_plugin
  # Option A (runtime install, verified end to end). Copy the whole plugin -- not
  # just dist/ -- and drop node_modules first (self-referential symlink trips the
  # sandbox state-backup audit; the bundled dist/index.mjs is all that's needed).
  local ct
  ct="$(docker ps --format '{{.Names}}' | grep "openshell-${SANDBOX_NAME}" | head -1)"
  [ -n "$ct" ] || die "could not find the openshell-${SANDBOX_NAME} container"
  rm -rf "${PLUGIN_DIR}/node_modules"
  docker exec "$ct" rm -rf /tmp/iblai-openclaw-extensions
  docker cp "$PLUGIN_DIR" "$ct":/tmp/iblai-openclaw-extensions
  docker exec "$ct" chmod -R a+rX /tmp/iblai-openclaw-extensions
  log "Installing + enabling iblai-openclaw-extensions in the sandbox"
  nemoclaw "$SANDBOX_NAME" exec --no-tty -- openclaw plugins install /tmp/iblai-openclaw-extensions
  nemoclaw "$SANDBOX_NAME" exec --no-tty -- openclaw plugins enable iblai-openclaw-extensions
  nemoclaw "$SANDBOX_NAME" restart
}

nemoclaw_healthcheck() {
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${GATEWAY_PORT}/" || true)"
  if [ "$code" = 200 ]; then
    log "Gateway healthy (127.0.0.1:${GATEWAY_PORT} -> 200)"
  else
    warn "Gateway health check returned '${code}' (expected 200)."
    warn "The forward port may differ; check: nemoclaw ${SANDBOX_NAME} dashboard-url"
  fi
}

# ---- shared: build the plugin bundle from source -----------------------------
build_plugin() {
  log "Building iblai-openclaw-extensions from source"
  if [ ! -d "$PLUGIN_DIR/.git" ]; then
    rm -rf "$PLUGIN_DIR"
    git clone "$PLUGIN_REPO" "$PLUGIN_DIR"
  fi
  command -v pnpm >/dev/null 2>&1 || npm install -g pnpm
  ( cd "$PLUGIN_DIR" && pnpm install && pnpm build )
}

# ---- optional: seed the ibl.ai platform --------------------------------------
# Reuses scripts/seed_claw_mentor.py (the maintained platform-side flow) rather
# than reimplementing the API calls here. Runs the repo copy if present, else
# fetches it. Passes the gateway token + device key this run just produced.
seed_platform() {
  log "Seeding ibl.ai platform: instance + mentor for ${DOMAIN}"
  python3 -c 'import requests' >/dev/null 2>&1 || apt-get install -y python3-requests

  local seed=""
  for c in "./scripts/seed_claw_mentor.py" \
           "$(dirname "${BASH_SOURCE[0]:-$0}")/scripts/seed_claw_mentor.py"; do
    [ -f "$c" ] && { seed="$c"; break; }
  done
  if [ -z "$seed" ]; then
    seed="$(mktemp /tmp/seed_claw_mentor.XXXXXX.py)"
    curl -fsSL "$SEED_URL" -o "$seed"
  fi

  local args=(
    --api-key "$IBLAI_API_KEY"
    --host "$IBLAI_HOST"
    --tenant-key "$IBLAI_ORG"
    --user-id "$IBLAI_USER_ID"
    --agent-name "$AGENT_NAME"
    --claw-name "$DOMAIN"
    --claw-server-url "https://${DOMAIN}"
    --claw-gateway-token "$OPENCLAW_GATEWAY_TOKEN"
    --claw-type "$IBLAI_CLAW_TYPE"
    --agent-id "$AGENT_ID"
    --device-key-pem "$DEVICE_KEY_PEM"
  )
  [ -n "$AGENT_DESCRIPTION" ] && args+=(--agent-description "$AGENT_DESCRIPTION")
  [ -n "$AGENT_CONFIG" ] && args+=(--agent-config "$AGENT_CONFIG")

  python3 "$seed" "${args[@]}"
}

# ---- final summary -----------------------------------------------------------
print_summary() {
  local server_url="https://${DOMAIN}" pem_json

  cat <<SUMMARY

============================================================================
 Server setup complete: ${HARNESS_TYPE} @ ${server_url}
============================================================================

 Gateway token (write-only; store it in ibl.ai as gateway_token):
   ${OPENCLAW_GATEWAY_TOKEN}

 Device identity private key (PKCS8 PEM): ${DEVICE_KEY_PEM}
SUMMARY

  if [ "$SEED_RESULT" = ok ]; then
    echo
    echo " Platform: seeded on ${IBLAI_HOST} (org ${IBLAI_ORG}) -- claw instance + mentor '${AGENT_NAME}'."
  else
    [ "$SEED_RESULT" = failed ] && warn "Platform seeding FAILED (see output above); register manually:"
    pem_json="$(json_escape_file "$DEVICE_KEY_PEM")"
    cat <<REG

 Register this instance with ibl.ai -- fill in <ORG>, <API_TOKEN>, <PLATFORM_HOST>:

   curl -X POST https://<PLATFORM_HOST>/api/ai-mentor/orgs/<ORG>/claw/instances/ \\
     -H "Authorization: Token <API_TOKEN>" \\
     -H "Content-Type: application/json" \\
     -d '{
       "name": "${DOMAIN}",
       "claw_type": "${IBLAI_CLAW_TYPE}",
       "server_url": "${server_url}",
       "gateway_token": "${OPENCLAW_GATEWAY_TOKEN}",
       "connection_params": {"device_identity": {"private_key_pem": "${pem_json}"}}
     }'

 Or re-run with IBLAI_API_KEY set to seed automatically. Full flow:
   scripts/seed_claw_mentor.py  and  docs/platform-integration.md
REG
  fi

  echo
  echo " First platform config push mints a pending device pairing -- approve it once:"
  if [ "$HARNESS_TYPE" = openclaw ]; then
    cat <<'NEXT'
   openclaw devices list
   openclaw devices approve <requestId> --token "$OPENCLAW_GATEWAY_TOKEN"
NEXT
  else
    printf '   nemoclaw %s exec --no-tty -- openclaw devices list\n' "$SANDBOX_NAME"
    printf '   nemoclaw %s exec --no-tty -- openclaw devices approve <requestId>\n' "$SANDBOX_NAME"
  fi
  echo "============================================================================"
}

# ---- main --------------------------------------------------------------------
system_prep
log "Setting up ${HARNESS_TYPE} for ${DOMAIN}"
gen_device_key
if [ "$HARNESS_TYPE" = openclaw ]; then
  setup_firewall
  openclaw_install
  install_caddy
  openclaw_plugin
else
  setup_firewall
  nemoclaw_install
  install_caddy
  nemoclaw_plugin
fi

SEED_RESULT=skipped
if [ -n "$IBLAI_API_KEY" ]; then
  if seed_platform; then SEED_RESULT=ok; else SEED_RESULT=failed; fi
fi

print_summary
