# Platform Integration

Connect your claw server to ibl.ai and manage it through the platform's APIs and applications.

Once connected, your claw instance is accessible from all ibl.ai applications: Mentor AI, Skills AI, and any custom integration using the REST API. You register the server, bind mentors, configure agent identities and skills, and push configuration. It all runs through the same API that powers the ibl.ai platform UI.

---

## Integration Flow

```
1. Register instance        POST claw/instances/
2. Test connectivity        POST claw/instances/<id>/test-connectivity/
3. Add model providers      POST claw/model-providers/
4. Push providers           POST claw/instances/<id>/push-providers/
5. Bind mentor              POST mentors/<mentor>/claw-config/
6. Configure agent          PATCH mentors/<mentor>/agent-config/
7. Create skills            POST agent-skills/  +  POST agent-skill-resources/
8. Assign skills            POST mentors/<mentor>/skills/
9. Push config              POST mentors/<mentor>/claw-config/push-config/
```

All API calls use base path `/api/ai-mentor/orgs/<your-org>/` and require authentication. In the mentor-scoped paths, `<mentor>` is the mentor's UUID (a non-UUID value returns 404).

---

## Authentication and base URL

Every request carries a **Platform API Token** in an `Api-Token` header:

```
Authorization: Api-Token <YOUR_API_TOKEN>
```

> **The scheme is `Api-Token`, not `Token`.** A plain `Authorization: Token …` is
> rejected with `401 {"detail":"Invalid Token"}` even when the token is valid for the
> org — the failure looks like a bad credential, but it is the scheme.

### Against the hosted ibl.ai deployment

Two host forms work and return identical responses — **but they differ in path prefix**,
so pick one and stay consistent:

| Base URL | Full path | Notes |
|---|---|---|
| `https://platform.iblai.app` | `/api/ai-mentor/orgs/<org>/…` | No prefix. Used by the examples in this guide. |
| `https://api.iblai.app/dm` | `/dm/api/ai-mentor/orgs/<org>/…` | Requires `/dm`. This is the `IBLAI_HOST` default in [`install.sh`](../install.sh) and [`scripts/seed_claw_mentor.py`](../scripts/seed_claw_mentor.py). |

Mixing them fails: `platform.iblai.app/dm/api/…` and `api.iblai.app/api/…` both 404.
Calling `https://api.iblai.app` without `/dm` returns:

```json
{"error": "Invalid API path. Use /dm/, /asgi/, /lms/, or /studio/"}
```

A complete, working call — list the claw instances registered on your org:

```bash
export IBLAI_HOST=https://platform.iblai.app     # or https://api.iblai.app/dm
export IBLAI_ORG=<your-org>
export IBLAI_API_KEY=<your-platform-api-token>

curl -sS "$IBLAI_HOST/api/ai-mentor/orgs/$IBLAI_ORG/claw/instances/" \
  -H "Authorization: Api-Token $IBLAI_API_KEY"
# → []   (empty list until you register your first instance)
```

If you don't know your org's admin username — needed for the mentor endpoints — read it
straight from the API with the same two values:

```bash
curl -sS "$IBLAI_HOST/api/core/platform/users/?platform_key=$IBLAI_ORG&platform_org=$IBLAI_ORG&page=1&page_size=5" \
  -H "Authorization: Api-Token $IBLAI_API_KEY" \
  | python3 -c "import sys,json;[print(u['username'], u.get('is_admin')) for u in json.load(sys.stdin)['results']]"
# pick an is_admin=True username
```

Self-hosted platform deployments use their own host and may not carry the `/dm` prefix —
substitute your own base URL throughout the examples below.

---

## Part 1: Connect Your Server to ibl.ai

### Register your instance

```http
POST /api/ai-mentor/orgs/<your-org>/claw/instances/
Content-Type: application/json

{
  "name": "My OpenClaw Instance",
  "claw_type": "openclaw",
  "server_url": "https://your-domain.example.com",
  "gateway_token": "your-gateway-token-from-setup"
}
```

| Field | Type | Description |
|---|---|---|
| `name` | string | Display name for this instance |
| `claw_type` | string | Instance type. Use `"openclaw"` for a standard OpenClaw worker. NemoClaw workers also work with `"openclaw"`. A dedicated `"nemoclaw"` type is available on recent platform versions for NemoClaw-specific handling; use it where supported. |
| `server_url` | string | HTTPS URL of your claw server |
| `gateway_token` | string | Write-only. The token from [server setup step 1.3](server-setup.md#13-generate-a-gateway-token) |
| `auth_headers` | object | Write-only. Optional proxy auth headers (`{"string": "string"}` pairs) |
| `connection_params` | object | Write-only. Variant-specific auth (e.g. device identity key for OpenClaw, see below) |

**Device identity (required for OpenClaw):** The platform needs an Ed25519 keypair for device identity signing. Without it, config push will fail with "missing scope: operator.read". Generate a keypair and include it in `connection_params`:

```json
{
  "device_identity": {
    "private_key_pem": "-----BEGIN PRIVATE KEY-----\n<base64>\n-----END PRIVATE KEY-----\n"
  }
}
```

See [server setup step 5.2](server-setup.md#52-generate-and-store-device-keypair) for how to generate the keypair.

Save the `id` from the response. You'll need it for subsequent steps.

**Response (201 Created):**

```json
{
  "id": 1,
  "name": "My OpenClaw Instance",
  "claw_type": "openclaw",
  "provision_mode": "self_hosted",
  "server_url": "https://your-domain.example.com",
  "deployment_backend": null,
  "status": "active",
  "deploy_state": "ready",
  "platform_key": "your-org",
  "last_health_check": null,
  "last_health_status": null,
  "claw_version": null,
  "created_at": "2026-03-18T10:00:00Z",
  "updated_at": "2026-03-18T10:00:00Z"
}
```

Write-only fields (`gateway_token`, `auth_headers`, `connection_params`) are never returned in responses.

### Test connectivity

```http
POST /api/ai-mentor/orgs/<your-org>/claw/instances/<id>/test-connectivity/
```

**Response (200 OK):**

```json
{
  "checks": [
    {"name": "tls_reachable", "passed": true, "detail": "200 OK"},
    {"name": "health_check", "passed": true, "detail": "healthy"}
  ],
  "all_passed": true
}
```

If `tls_reachable` fails: check your domain DNS and Caddy config.
If `health_check` fails: check that the OpenClaw gateway is running (`systemctl --user status openclaw-gateway`).

### Other instance operations

| Endpoint | Method | Description |
|---|---|---|
| `claw/instances/` | GET | List all instances. Filters: `status`, `search`. |
| `claw/instances/<id>/` | GET | Retrieve instance details |
| `claw/instances/<id>/` | PATCH | Update instance (writable: `name`, `claw_type`, `server_url`, `gateway_token`, `auth_headers`, `connection_params`, `deployment_backend`) |
| `claw/instances/<id>/` | DELETE | Delete instance |
| `claw/instances/<id>/health-check/` | POST | Run health check. Updates `last_health_check` and `last_health_status`. |
| `claw/instances/<id>/push-providers/` | POST | Push all enabled model providers to the instance |
| `claw/instances/<id>/security-audit/` | POST | Run security audit (OpenClaw only) |
| `claw/instances/<id>/refresh-version/` | POST | Detect claw version from instance handshake |

**Instance status values:** `active`, `inactive`, `error`
**Deploy state values:** `pending`, `deploying`, `ready`, `teardown`, `failed`

---

## Part 2: Configure and Call from ibl.ai

Once your server is registered, you manage everything through the ibl.ai API. This means all ibl.ai applications can use your claw instance: Mentor AI chat, Skills AI, and custom integrations. Configuration, agent identities, skills, and model providers are all pushed from the platform to your server.

### Set up a model provider (optional)

If you want to use a different LLM provider (e.g. OpenRouter) instead of the default Anthropic:

```http
POST /api/ai-mentor/orgs/<your-org>/claw/model-providers/
Content-Type: application/json

{
  "server": 1,
  "name": "openrouter",
  "base_url": "https://openrouter.ai/api/v1",
  "api_type": "openai-completions",
  "credential_name": "openrouter",
  "credential_key": "key",
  "model_catalog": [
    {"id": "anthropic/claude-sonnet-4-6", "name": "Claude Sonnet"},
    {"id": "meta-llama/llama-3.2-3b-instruct:free", "name": "Llama 3.2 (free)"}
  ],
  "enabled": true,
  "models_mode": "merge"
}
```

| Field | Type | Description |
|---|---|---|
| `server` | integer | Claw instance ID |
| `name` | string | Provider name |
| `base_url` | string | Provider API base URL |
| `api_type` | string | `"openai-completions"` or provider-specific type |
| `credential_name` | string | References an LLMCredential by name on the platform |
| `credential_key` | string | JSON key within the credential value that contains the API key |
| `model_catalog` | array | List of `{"id": "model-id", "name": "display name"}` entries |
| `models_mode` | string | `"merge"` (adds to built-in models) or `"replace"` (uses only configured providers) |

Then push providers to the instance:

```http
POST /api/ai-mentor/orgs/<your-org>/claw/instances/<id>/push-providers/
```

**Response (202 Accepted):**

```json
{"queued": true, "message": "Provider push queued."}
```

The `credential_resolved` field in provider responses indicates whether an LLMCredential with the given `credential_name` exists on the platform.

### Bind a mentor to the instance

```http
POST /api/ai-mentor/orgs/<your-org>/mentors/<mentor>/claw-config/
Content-Type: application/json

{
  "server": 1,
  "enabled": true
}
```

This automatically creates an `AgentConfig` for the mentor if one doesn't exist.

> [!NOTE]
> **The push creates the worker agent for you.** Pushing a mentor's config provisions the target agent
> automatically (ensure-on-push), so binding to a non-default agent name needs no host-side step. To
> pre-create a standalone agent by hand: `openclaw agents add <name>` (OpenClaw, over SSH) or
> `nemoclaw <sandbox> exec --no-tty -- openclaw agents add <name>` (NemoClaw).

**Response (201 Created):**

```json
{
  "id": 1,
  "mentor": "6f29a5eb-c657-4a76-8a19-4ea58175d008",
  "server": 1,
  "server_name": "My OpenClaw Instance",
  "agent_config": {},
  "enabled": true,
  "auto_push": false,
  "last_config_push": null,
  "last_config_push_status": null,
  "last_push_warnings": []
}
```

| Endpoint | Method | Description |
|---|---|---|
| `mentors/<mentor>/claw-config/` | GET | Retrieve binding (single binding per mentor) |
| `mentors/<mentor>/claw-config/` | PATCH | Update binding |
| `mentors/<mentor>/claw-config/` | DELETE | Delete binding |
| `mentors/<mentor>/claw-config/push-config/` | POST | Push configuration to the instance |

### Configure the agent

Agent configuration defines the workspace files and settings that get pushed to the claw instance. Each text field maps to a markdown file in the agent's workspace:

> [!IMPORTANT]
> A claw-backed mentor does not inherit the mentor's platform `system_prompt`. The claw agent is driven entirely by the agent-config fields below (`identity`, `soul`, and the rest), and that config starts empty when you bind the mentor. Enter the persona and behavior here, or the agent runs with no instructions.

```http
PATCH /api/ai-mentor/orgs/<your-org>/mentors/<mentor>/agent-config/
Content-Type: application/json

{
  "identity": "Name: Study Buddy\nVibe: Friendly and patient",
  "soul": "Always encourage the student. Be concise.",
  "model": "anthropic/claude-sonnet-4-6"
}
```

| Field | Type | Pushed as | Description |
|---|---|---|---|
| `identity` | text | IDENTITY.md | Agent persona: name, visual description, vibe |
| `soul` | text | SOUL.md | Behavioral guidelines: personality, values, boundaries |
| `user_context` | text | USER.md | User-specific environment details |
| `tools` | text | TOOLS.md | Environment-specific reference notes for tool usage |
| `agents` | text | AGENTS.md | Multi-agent routing configuration |
| `bootstrap` | text | BOOTSTRAP.md | One-time first-run instructions (consumed after use) |
| `heartbeat` | text | HEARTBEAT.md | Periodic awareness checklist content |
| `memory` | text | MEMORY.md | Seed memory: long-term curated facts |
| `model` | string | config.patch | LLM model identifier |
| `config` | JSON | config.patch | Instance settings (heartbeat schedule, session isolation, skill toggles) |

All text fields are optional and default to empty string. The `config` field defaults to `{}`.

> [!WARNING]
> **Unrecognized keys are silently ignored.** A `PATCH` carrying `user` instead of
> `user_context` still returns `200 OK`, but the value is dropped — USER.md is pushed
> empty. Re-`GET` the agent-config after writing and confirm each field is non-empty
> before pushing; the response body is the only confirmation you get.
>
> This matters with `auto_push` enabled: a field left empty here is pushed as empty and
> **blanks the corresponding file on the instance**. Populate the agent-config fully
> before the first push, or back the workspace files up on the server first.

**Blocked config paths** (rejected on write): `gateway.auth`, `gateway.controlUi.dangerouslyDisableDeviceAuth`, `tools.exec.host`, `sandbox.mode`, `hooks.allowUnsafeExternalContent`.

### Push configuration to the instance

```http
POST /api/ai-mentor/orgs/<your-org>/mentors/<mentor>/claw-config/push-config/
```

**Response (202 Accepted):**

```json
{"queued": true, "message": "Config push queued."}
```

A successful push sets workspace files (IDENTITY.md, SOUL.md, etc.) and applies config patches on the instance. The gateway restarts itself after a config patch.

### Device pairing

The first time the platform pushes config, the instance may require device pairing approval. If the push fails with a pairing error:

1. SSH into your server
2. Run: `openclaw devices list`
3. Find the pending request and approve it: `openclaw devices approve <requestId> --token "$OPENCLAW_GATEWAY_TOKEN"`

For a NemoClaw worker, approve from inside the sandbox instead with `nemoclaw <sandbox> exec --no-tty -- openclaw devices approve <requestId>`.

This only needs to be done once per platform connection. See [Device Re-Pairing](server-setup.md#device-re-pairing-after-gateway-restarts--updates) if pairing is lost after updates.

---

## Skills Management

Skills are reusable capabilities that can be assigned to mentors. When config is pushed, enabled skill assignments are sent to the instance.

> [!NOTE]
> Skills push without any extra setup on the worker. Installing the optional `iblai-openclaw-extensions` plugin adds per-agent isolation and clean removal of unassigned skills. Without it, skills install worker-wide and unassigned skills are disabled rather than deleted. See [OpenClaw plugin setup](server-setup.md#optional-iblai-extensions-plugin-per-agent-skills) or [NemoClaw plugin setup](nemoclaw-setup.md#optional-iblai-extensions-plugin-per-agent-skills).

### Create a skill

```http
POST /api/ai-mentor/orgs/<your-org>/agent-skills/
Content-Type: application/json

{
  "name": "Web Research",
  "slug": "web-research",
  "description": "Research topics using web search",
  "version": "1.0.0",
  "instruction": "## Instructions\n1. Search for the topic\n2. Summarize key findings\n3. Cite sources",
  "metadata": {
    "openclaw": {
      "requires": {"bins": ["curl"]}
    }
  },
  "enabled": true
}
```

| Field | Type | Description |
|---|---|---|
| `name` | string | Display name |
| `slug` | string | Unique identifier per platform |
| `instruction` | text | The SKILL.md body (agent runbook) |
| `metadata` | JSON | SKILL.md frontmatter (requirements, env vars, etc.) |

### Add resources to a skill

Skills can have attached files: scripts, references, or binary assets.

**For scripts and references (text content):**

```http
POST /api/ai-mentor/orgs/<your-org>/agent-skill-resources/
Content-Type: application/json

{
  "skill": 1,
  "file_type": "script",
  "filename": "fetch_data.py",
  "content": "import requests\n\ndef fetch(url):\n    return requests.get(url).text"
}
```

**For assets (binary files):** Use multipart form with a `file` field instead of `content`.

| File type | Content | Description |
|---|---|---|
| `script` | text (`content` field) | Executable scripts |
| `reference` | text (`content` field) | Reference documents |
| `asset` | binary (`file` field) | Binary assets |

### Assign skills to mentors

```http
POST /api/ai-mentor/orgs/<your-org>/mentors/<mentor>/skills/
Content-Type: application/json

{
  "skill": "<skill-unique-id>",
  "enabled": true
}
```

The mentor comes from the path, so it is not in the body. The `skill` value is the skill's UUID (the `unique_id` from the create-skill response), not its numeric id. A mentor can only be assigned to the same skill once. Enabled assignments are pushed as `skills.entries` when you push config.

| Endpoint | Method | Description |
|---|---|---|
| `agent-skills/` | GET | List skills. Filters: `enabled`, `search`. |
| `agent-skills/<id>/` | GET/PATCH/DELETE | Manage a skill |
| `agent-skill-resources/` | GET | List resources. Filters: `file_type`, `skill`. |
| `agent-skill-resources/<id>/` | GET/PATCH/DELETE | Manage a resource |
| `mentors/<mentor>/skills/` | GET | List the mentor's assignments |
| `mentors/<mentor>/skills/<id>/` | GET/PATCH/DELETE | Manage an assignment |

---

## Complete Example

Here's a full walkthrough: register a server, bind a mentor, configure it, and push.

### 1. Register the instance

```bash
curl -X POST https://platform.iblai.app/api/ai-mentor/orgs/my-org/claw/instances/ \
  -H "Content-Type: application/json" \
  -H "Authorization: Api-Token YOUR_API_TOKEN" \
  -d '{
    "name": "Production OpenClaw",
    "claw_type": "openclaw",
    "server_url": "https://claw.mycompany.com",
    "gateway_token": "abc123..."
  }'
# Save the returned "id" (e.g. 1)
```

### 2. Test connectivity

```bash
curl -X POST https://platform.iblai.app/api/ai-mentor/orgs/my-org/claw/instances/1/test-connectivity/ \
  -H "Authorization: Api-Token YOUR_API_TOKEN"
# Both checks should pass
```

### 3. Bind a mentor

```bash
curl -X POST https://platform.iblai.app/api/ai-mentor/orgs/my-org/mentors/<mentor>/claw-config/ \
  -H "Content-Type: application/json" \
  -H "Authorization: Api-Token YOUR_API_TOKEN" \
  -d '{
    "server": 1,
    "enabled": true
  }'
# Save the returned "id" (e.g. 1)
```

### 4. Configure the agent

```bash
curl -X PATCH https://platform.iblai.app/api/ai-mentor/orgs/my-org/mentors/<mentor>/agent-config/ \
  -H "Content-Type: application/json" \
  -H "Authorization: Api-Token YOUR_API_TOKEN" \
  -d '{
    "identity": "Name: Study Buddy\nVibe: Friendly and patient tutor",
    "soul": "Always encourage the student. Never give answers directly. Be concise.",
    "model": "anthropic/claude-sonnet-4-6",
    "config": {
      "heartbeat": {"every": "30m"},
      "session": {"dmScope": "per-channel-peer"}
    }
  }'
```

### 5. Push config

```bash
curl -X POST https://platform.iblai.app/api/ai-mentor/orgs/my-org/mentors/<mentor>/claw-config/push-config/ \
  -H "Authorization: Api-Token YOUR_API_TOKEN"
# Response: {"queued": true, "message": "Config push queued."}
```

### 6. Approve device pairing (first time only)

```bash
# SSH into your claw server
ssh root@claw.mycompany.com
openclaw devices list
openclaw devices approve <requestId> --token "$OPENCLAW_GATEWAY_TOKEN"
```

### 7. Chat

Open the mentor in any ibl.ai application and send a message. Responses stream from your OpenClaw instance through the platform to the user.

---

## API Reference Summary

All endpoints are tenant-scoped under `/api/ai-mentor/orgs/<org>/`. Responses are JSON. List endpoints support `limit` and `offset` pagination.

### Claw Instances

| Method | Endpoint | Description |
|---|---|---|
| POST | `claw/instances/` | Create instance |
| GET | `claw/instances/` | List instances |
| GET | `claw/instances/<id>/` | Retrieve instance |
| PATCH | `claw/instances/<id>/` | Update instance |
| DELETE | `claw/instances/<id>/` | Delete instance |
| POST | `claw/instances/<id>/test-connectivity/` | Test connectivity |
| POST | `claw/instances/<id>/health-check/` | Run health check |
| POST | `claw/instances/<id>/push-providers/` | Push model providers |
| POST | `claw/instances/<id>/security-audit/` | Security audit (OpenClaw only) |
| POST | `claw/instances/<id>/refresh-version/` | Detect claw version |

### Mentor Configs

| Method | Endpoint | Description |
|---|---|---|
| POST | `mentors/<mentor>/claw-config/` | Create binding |
| GET | `mentors/<mentor>/claw-config/` | Retrieve binding (`404 {"detail":"Claw config not found"}` = not bound yet) |
| PATCH | `mentors/<mentor>/claw-config/` | Update binding |
| DELETE | `mentors/<mentor>/claw-config/` | Delete binding |
| POST | `mentors/<mentor>/claw-config/push-config/` | Push configuration |

The binding is addressed by the mentor's UUID in the path, so there is no
collection-level list or numeric-id form.

### Agent Configs

| Method | Endpoint | Description |
|---|---|---|
| GET | `mentors/<mentor>/agent-config/` | Retrieve config |
| PATCH | `mentors/<mentor>/agent-config/` | Update config |

### Agent Skills

| Method | Endpoint | Description |
|---|---|---|
| POST | `agent-skills/` | Create skill |
| GET | `agent-skills/` | List skills |
| GET | `agent-skills/<id>/` | Retrieve skill |
| PATCH | `agent-skills/<id>/` | Update skill |
| DELETE | `agent-skills/<id>/` | Delete skill |

### Skill Resources

| Method | Endpoint | Description |
|---|---|---|
| POST | `agent-skill-resources/` | Create resource |
| GET | `agent-skill-resources/` | List resources |
| GET | `agent-skill-resources/<id>/` | Retrieve resource |
| PATCH | `agent-skill-resources/<id>/` | Update resource |
| DELETE | `agent-skill-resources/<id>/` | Delete resource |

### Mentor Skill Assignments

| Method | Endpoint | Description |
|---|---|---|
| POST | `mentors/<mentor>/skills/` | Create assignment |
| GET | `mentors/<mentor>/skills/` | List assignments |
| GET | `mentors/<mentor>/skills/<id>/` | Retrieve assignment |
| PATCH | `mentors/<mentor>/skills/<id>/` | Update assignment |
| DELETE | `mentors/<mentor>/skills/<id>/` | Delete assignment |

### Model Providers

| Method | Endpoint | Description |
|---|---|---|
| POST | `claw/model-providers/` | Create provider |
| GET | `claw/model-providers/` | List providers |
| GET | `claw/model-providers/<id>/` | Retrieve provider |
| PATCH | `claw/model-providers/<id>/` | Update provider |
| DELETE | `claw/model-providers/<id>/` | Delete provider |
