<div align="center">

<a href="https://ibl.ai"><img src="https://ibl.ai/images/iblai-logo.png" alt="ibl.ai" width="300"></a>

# Claw Setup

Connect self-hosted claw servers (OpenClaw, NVIDIA NemoClaw) to the [ibl.ai](https://ibl.ai) platform. Run your own AI agent infrastructure and manage it through ibl.ai's APIs and applications.

[![OpenClaw](https://img.shields.io/badge/OpenClaw-supported-4A90D9?logo=data:image/svg%2Bxml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAxMDAgMTAwIj48dGV4dCB5PSI3NSIgZm9udC1zaXplPSI4MCI+8J+mnjwvdGV4dD48L3N2Zz4=)](#)
[![NemoClaw](https://img.shields.io/badge/NemoClaw-supported-76B900?logo=nvidia&logoColor=white)](#)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

</div>

---

## Overview

This repository provides step-by-step guides for two things:

1. **[Server Setup](docs/server-setup.md)** -- Deploy an OpenClaw gateway on a VPS and expose it over HTTPS
2. **[Platform Integration](docs/platform-integration.md)** -- Connect your claw server to ibl.ai and manage it through the platform's APIs and applications

Once connected, your claw instance is accessible from all ibl.ai applications -- Mentor AI, Skills AI, and any custom integration using the platform API. You configure mentors, push agent identities, assign skills, and chat with users -- all managed centrally through ibl.ai while the compute runs on your own infrastructure.

## Features

- **Self-hosted AI agents** -- Run OpenClaw or NemoClaw on your own infrastructure while managing everything through ibl.ai
- **Automatic TLS** -- Caddy reverse proxy handles Let's Encrypt certificates with zero configuration
- **Centralized mentor management** -- Configure agent identities, personalities, and behavioral guidelines via the ibl.ai API
- **Skill system** -- Create reusable skills with scripts and resources, assign them to mentors, push to instances
- **Multi-model support** -- Use Anthropic, OpenRouter, or any OpenAI-compatible provider with automatic fallbacks
- **Multi-agent deployments** -- Run multiple agents on a single gateway (tutor, course creator, admissions, etc.)
- **Secure by default** -- Ed25519 device identity signing, loopback-only gateway binding, token-based auth
- **Platform integration** -- Connected instances are accessible from Mentor AI, Skills AI, and any custom integration via REST API
- **Monitoring** -- Health checks, connectivity tests, security audits, and version tracking through the API

## Architecture

```
User (browser / app)
    │
    ▼
ibl.ai Platform (Django Channels / ASGI)
    │
    ▼
Claw Integration Layer (WebSocket + device identity signing)
    │
    ▼
Caddy (on your server, TLS via Let's Encrypt)
    │  reverse proxy to localhost:18789
    ▼
OpenClaw Gateway (systemd service, loopback only)
    │
    ▼
LLM Provider (Anthropic, OpenRouter, etc.)
```

**Your server** runs OpenClaw and Caddy. **ibl.ai** handles user-facing chat, mentor configuration, agent identity, skill management, and model provider orchestration. The platform connects to your server over a secure WebSocket with Ed25519 device identity signing.

## Prerequisites

| Requirement | Details |
|---|---|
| **Server** | VPS or dedicated, minimum 2 vCPU / 4 GB RAM (e.g. Hetzner CX22, ~$4/mo) |
| **Domain** | A domain or subdomain with a DNS A record pointing to your server's IP |
| **LLM API key** | Anthropic API key (or another provider like OpenRouter) |
| **Firewall** | Ports 80 and 443 open inbound |
| **ibl.ai account** | Platform org key and API credentials |

## Quick Start

### 1. Set up the server

SSH into your VPS, install OpenClaw, configure Caddy for TLS, and start the gateway as a systemd service.

**[Full server setup guide →](docs/server-setup.md)**

### 2. Connect to ibl.ai

Register your instance via the API, test connectivity, bind mentors, configure agents, and push config.

**[Full platform integration guide →](docs/platform-integration.md)**

### 3. Chat

Open any ibl.ai application (Mentor AI, Skills AI, or your own integration) and send a message to a claw-backed mentor. Responses stream from your OpenClaw instance through the platform to the user.

## Guides

| Guide | Description |
|---|---|
| **[Server Setup](docs/server-setup.md)** | Install OpenClaw, configure Caddy, set up systemd, validate the deployment |
| **[Platform Integration](docs/platform-integration.md)** | Register instance, configure mentors and agents, manage skills, API reference |

## Troubleshooting

See the [troubleshooting section](docs/server-setup.md#troubleshooting) in the server setup guide and the [connectivity checks](docs/platform-integration.md#test-connectivity) in the platform integration guide.
