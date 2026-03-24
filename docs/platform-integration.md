# Platform Integration

Connect your claw server to ibl.ai and manage it through the platform's APIs and applications.

Once connected, your claw instance is accessible from all ibl.ai applications -- Mentor AI, Skills AI, and any custom integration using the REST API. You register the server, bind mentors, configure agent identities and skills, and push configuration -- all through the same API that powers the ibl.ai platform UI.

---

## Integration Flow

```
1. Register instance        POST claw/instances/
2. Test connectivity        POST claw/instances/<id>/test-connectivity/
3. Add model providers      POST claw/model-providers/
4. Push providers           POST claw/instances/<id>/push-providers/
5. Bind mentor              POST claw/mentor-configs/
6. Configure agent          PATCH agent-configs/<id>/
7. Create skills            POST agent-skills/  +  POST agent-skill-resources/
8. Assign skills            POST mentor-skill-assignments/
9. Push config              POST claw/mentor-configs/<id>/push-config/
```

All API calls use base path `/api/ai-mentor/orgs/<your-org>/` and require authentication.

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
| `claw_type` | string | `"openclaw"` or `"ironclaw"` |
| `server_url` | string | HTTPS URL of your claw server |
| `gateway_token` | string | Write-only. The token from [server setup step 1.3](server-setup.md#13----generate-a-gateway-token) |
| `auth_headers` | object | Write-only. Optional proxy auth headers (`{"string": "string"}` pairs) |
| `connection_params` | object | Write-only. Variant-specific auth (e.g. device identity key for OpenClaw) |

Save the `id` from the response -- you'll need it for subsequent steps.

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

Once your server is registered, you manage everything through the ibl.ai API. This means all ibl.ai applications -- Mentor AI chat, Skills AI, custom integrations -- can use your claw instance. Configuration, agent identities, skills, and model providers are all pushed from the platform to your server.

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
    {"id": "anthropic/claude-sonnet-4-5-20250929", "name": "Claude Sonnet"},
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
POST /api/ai-mentor/orgs/<your-org>/claw/mentor-configs/
Content-Type: application/json

{
  "mentor": "<mentor-unique-id>",
  "server": 1,
  "enabled": true
}
```

This automatically creates an `AgentConfig` for the mentor if one doesn't exist.

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
| `claw/mentor-configs/` | GET | List bindings. Filter: `enabled`. |
| `claw/mentor-configs/<id>/` | GET | Retrieve binding |
| `claw/mentor-configs/<id>/` | PATCH | Update binding |
| `claw/mentor-configs/<id>/` | DELETE | Delete binding |
| `claw/mentor-configs/<id>/push-config/` | POST | Push configuration to the instance |

### Configure the agent

Agent configuration defines the workspace files and settings that get pushed to the claw instance. Each text field maps to a markdown file in the agent's workspace:

```http
PATCH /api/ai-mentor/orgs/<your-org>/agent-configs/<id>/
Content-Type: application/json

{
  "identity": "Name: Study Buddy\nVibe: Friendly and patient",
  "soul": "Always encourage the student. Be concise.",
  "model": "anthropic/claude-sonnet-4-5-20250929"
}
```

| Field | Type | Pushed as | Description |
|---|---|---|---|
| `identity` | text | IDENTITY.md | Agent persona -- name, visual description, vibe |
| `soul` | text | SOUL.md | Behavioral guidelines -- personality, values, boundaries |
| `user_context` | text | USER.md | User-specific environment details |
| `tools` | text | TOOLS.md | Environment-specific reference notes for tool usage |
| `agents` | text | AGENTS.md | Multi-agent routing configuration |
| `bootstrap` | text | BOOTSTRAP.md | One-time first-run instructions (consumed after use) |
| `heartbeat` | text | HEARTBEAT.md | Periodic awareness checklist content |
| `memory` | text | MEMORY.md | Seed memory -- long-term curated facts |
| `model` | string | config.patch | LLM model identifier |
| `config` | JSON | config.patch | Instance settings (heartbeat schedule, session isolation, skill toggles) |

All text fields are optional and default to empty string. The `config` field defaults to `{}`.

**Blocked config paths** (rejected on write): `gateway.auth`, `gateway.controlUi.dangerouslyDisableDeviceAuth`, `tools.exec.host`, `sandbox.mode`, `hooks.allowUnsafeExternalContent`.

### Push configuration to the instance

```http
POST /api/ai-mentor/orgs/<your-org>/claw/mentor-configs/<id>/push-config/
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
3. Find the pending request and approve it: `openclaw devices approve <requestId>`

This only needs to be done once per platform connection. See [Device Re-Pairing](server-setup.md#device-re-pairing) if pairing is lost after updates.

---

## Skills Management

Skills are reusable capabilities that can be assigned to mentors. When config is pushed, enabled skill assignments are sent to the instance.

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

Skills can have attached files -- scripts, references, or binary assets:

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
POST /api/ai-mentor/orgs/<your-org>/mentor-skill-assignments/
Content-Type: application/json

{
  "mentor": "<mentor-unique-id>",
  "skill": 1,
  "enabled": true
}
```

A mentor can only be assigned to the same skill once. Enabled assignments are pushed as `skills.entries` when you push config.

| Endpoint | Method | Description |
|---|---|---|
| `agent-skills/` | GET | List skills. Filters: `enabled`, `search`. |
| `agent-skills/<id>/` | GET/PATCH/DELETE | Manage a skill |
| `agent-skill-resources/` | GET | List resources. Filters: `file_type`, `skill`. |
| `agent-skill-resources/<id>/` | GET/PATCH/DELETE | Manage a resource |
| `mentor-skill-assignments/` | GET | List assignments. Filters: `enabled`, `skill`, `mentor`. |
| `mentor-skill-assignments/<id>/` | GET/PATCH/DELETE | Manage an assignment |

---

## Complete Example

Here's a full walkthrough: register a server, bind a mentor, configure it, and push.

### 1. Register the instance

```bash
curl -X POST https://platform.ibl.ai/api/ai-mentor/orgs/my-org/claw/instances/ \
  -H "Content-Type: application/json" \
  -H "Authorization: Token YOUR_API_TOKEN" \
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
curl -X POST https://platform.ibl.ai/api/ai-mentor/orgs/my-org/claw/instances/1/test-connectivity/ \
  -H "Authorization: Token YOUR_API_TOKEN"
# Both checks should pass
```

### 3. Bind a mentor

```bash
curl -X POST https://platform.ibl.ai/api/ai-mentor/orgs/my-org/claw/mentor-configs/ \
  -H "Content-Type: application/json" \
  -H "Authorization: Token YOUR_API_TOKEN" \
  -d '{
    "mentor": "6f29a5eb-c657-4a76-8a19-4ea58175d008",
    "server": 1,
    "enabled": true
  }'
# Save the returned "id" (e.g. 1)
```

### 4. Configure the agent

```bash
curl -X PATCH https://platform.ibl.ai/api/ai-mentor/orgs/my-org/agent-configs/1/ \
  -H "Content-Type: application/json" \
  -H "Authorization: Token YOUR_API_TOKEN" \
  -d '{
    "identity": "Name: Study Buddy\nVibe: Friendly and patient tutor",
    "soul": "Always encourage the student. Never give answers directly. Be concise.",
    "model": "anthropic/claude-sonnet-4-5-20250929",
    "config": {
      "heartbeat": {"every": "30m"},
      "session": {"dmScope": "per-channel-peer"}
    }
  }'
```

### 5. Push config

```bash
curl -X POST https://platform.ibl.ai/api/ai-mentor/orgs/my-org/claw/mentor-configs/1/push-config/ \
  -H "Authorization: Token YOUR_API_TOKEN"
# Response: {"queued": true, "message": "Config push queued."}
```

### 6. Approve device pairing (first time only)

```bash
# SSH into your claw server
ssh root@claw.mycompany.com
openclaw devices list
openclaw devices approve <requestId>
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
| POST | `claw/mentor-configs/` | Create binding |
| GET | `claw/mentor-configs/` | List bindings |
| GET | `claw/mentor-configs/<id>/` | Retrieve binding |
| PATCH | `claw/mentor-configs/<id>/` | Update binding |
| DELETE | `claw/mentor-configs/<id>/` | Delete binding |
| POST | `claw/mentor-configs/<id>/push-config/` | Push configuration |

### Agent Configs

| Method | Endpoint | Description |
|---|---|---|
| POST | `agent-configs/` | Create config |
| GET | `agent-configs/` | List configs |
| GET | `agent-configs/<id>/` | Retrieve config |
| PATCH | `agent-configs/<id>/` | Update config |
| DELETE | `agent-configs/<id>/` | Delete config |

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
| POST | `mentor-skill-assignments/` | Create assignment |
| GET | `mentor-skill-assignments/` | List assignments |
| GET | `mentor-skill-assignments/<id>/` | Retrieve assignment |
| PATCH | `mentor-skill-assignments/<id>/` | Update assignment |
| DELETE | `mentor-skill-assignments/<id>/` | Delete assignment |

### Model Providers

| Method | Endpoint | Description |
|---|---|---|
| POST | `claw/model-providers/` | Create provider |
| GET | `claw/model-providers/` | List providers |
| GET | `claw/model-providers/<id>/` | Retrieve provider |
| PATCH | `claw/model-providers/<id>/` | Update provider |
| DELETE | `claw/model-providers/<id>/` | Delete provider |
