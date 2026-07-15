"""Create a mentor, a claw instance, and wire them together via a ClawMentorConfig.

This script focuses solely on creation — it does not update existing records.
Run it against a fresh tenant or use unique names to avoid conflicts.

Dummy values near the top of the file let you hard-code test parameters so
you can run the script without typing every flag each time. Override any of
them via the corresponding CLI argument.

Example (using defaults baked into DUMMY_* constants):

    python seed_claw_mentor.py

Example (explicit args, override all defaults):

    python seed_claw_mentor.py \\
        --api-key sk_live_abc123 \\
        --host https://base.manager.iblai.app \\
        --tenant-key acme \\
        --user-id admin \\
        --agent-name "Patient Navigator" \\
        --agent-description "Guides patients through care pathways." \\
        --claw-name "Healthcare Claw" \\
        --claw-server-url https://claw.acme.internal \\
        --claw-gateway-token secret-token \\
        --agent-id patient-navigator \\
        --agent-config '{"identity": "Name: Patient Navigator\\nRole: Guide"}'
"""

import argparse
import json
import sys
from urllib.parse import quote

import requests

# ── DUMMY VALUES ─────────────────────────────────────────────────────────────
# Edit these to run the script without passing every CLI flag each time.
# Any value passed via a CLI argument takes precedence.

DUMMY_API_KEY = "your-api-key-here"
DUMMY_HOST = "https://base.manager.iblai.app"
DUMMY_TENANT_KEY = "main"
DUMMY_USER_ID = "admin"

DUMMY_AGENT_NAME = "Test Mentor Agent"
DUMMY_AGENT_DESCRIPTION = "A test mentor created by seed_claw_mentor.py."

DUMMY_CLAW_NAME = "Test Claw Instance"
DUMMY_CLAW_SERVER_URL = "https://claw.example.com"
DUMMY_CLAW_GATEWAY_TOKEN = "dummy-gateway-token-change-me"
DUMMY_CLAW_TYPE = "openclaw"  # "openclaw" | "ironclaw" | "nemoclaw"

DUMMY_AGENT_ID = "main"  # empty → derived from mentor name slug
DUMMY_AGENT_CONFIG = {}  # dict of agent config fields, e.g. {"identity": "...", "soul": "..."}

# ─────────────────────────────────────────────────────────────────────────────

MENTOR_TEMPLATE = "ai-mentor"
MENTOR_VISIBILITY_PUBLIC = "viewable_by_anyone"


def slugify(text: str) -> str:
    return text.lower().replace(" ", "-")


# ── Claw instance ─────────────────────────────────────────────────────────────

def create_claw_instance(
    session: requests.Session,
    host: str,
    tenant_key: str,
    name: str,
    server_url: str,
    gateway_token: str,
    claw_type: str = "openclaw",
    connection_params: dict | None = None,
) -> dict:
    """POST /orgs/{org}/claw/instances/ — returns the created ClawInstance JSON."""
    print("Create Claw Instance")
    url = f"{host}/api/ai-mentor/orgs/{tenant_key}/claw/instances/"
    payload = {
        "name": name,
        "claw_type": claw_type,
        "server_url": server_url,
        "gateway_token": gateway_token,
    }
    if connection_params:
        # Ed25519 device identity, required for OpenClaw config push (missing → "missing scope").
        payload["connection_params"] = connection_params
    response = session.post(url, json=payload, timeout=60)
    response.raise_for_status()
    return response.json()


# ── Mentor ────────────────────────────────────────────────────────────────────

def create_mentor(
    session: requests.Session,
    host: str,
    tenant_key: str,
    user_id: str,
    name: str,
    description: str | None = None,
) -> dict:
    """POST mentor-with-settings — returns the created mentor JSON."""
    url = f"{host}/api/ai-mentor/orgs/{tenant_key}/users/{user_id}/mentor-with-settings/"
    payload = {
        "template_name": MENTOR_TEMPLATE,
        "new_mentor_name": name,
        "display_name": name,
        "mentor_visibility": MENTOR_VISIBILITY_PUBLIC,
    }
    if description:
        payload["description"] = description
    response = session.post(url, json=payload, timeout=60)
    response.raise_for_status()
    return response.json()


def update_mentor_settings(
    session: requests.Session,
    host: str,
    tenant_key: str,
    user_id: str,
    mentor_unique_id: str,
    description: str | None = None,
) -> None:
    """PUT mentor settings to enable anonymous access and claw."""
    url = (
        f"{host}/api/ai-mentor/orgs/{tenant_key}/users/{user_id}/"
        f"mentors/{mentor_unique_id}/settings/"
    )
    payload: dict = {"allow_anonymous": True, "enable_claw": True}
    if description:
        payload["mentor_description"] = description
    response = session.put(url, json=payload, timeout=60)
    response.raise_for_status()


# ── Claw mentor config ────────────────────────────────────────────────────────

def create_claw_mentor_config(
    session: requests.Session,
    host: str,
    tenant_key: str,
    mentor_unique_id: str,
    claw_instance_id: int,
    agent_id: str,
    agent_config: dict,
) -> dict:
    """POST /orgs/{org}/mentors/{uuid}/claw-config/ — returns the created config JSON."""
    url = (
        f"{host}/api/ai-mentor/orgs/{tenant_key}/mentors/"
        f"{mentor_unique_id}/claw-config/"
    )
    payload = {
        "server": claw_instance_id,
        "agent_id": agent_id,
        "agent_config": agent_config,
        "enabled": True,
    }
    response = session.post(url, json=payload, timeout=60)
    response.raise_for_status()
    return response.json()


def patch_agent_config(
    session: requests.Session,
    host: str,
    tenant_key: str,
    mentor_unique_id: str,
    agent_config: dict,
) -> dict:
    """PATCH the canonical AgentConfig model (identity/soul/…) for the mentor."""
    url = (
        f"{host}/api/ai-mentor/orgs/{tenant_key}/mentors/"
        f"{mentor_unique_id}/agent-config/"
    )
    response = session.patch(url, json=agent_config, timeout=60)
    response.raise_for_status()
    return response.json()


# ── Orchestration ─────────────────────────────────────────────────────────────

def run(
    session: requests.Session,
    host: str,
    tenant_key: str,
    user_id: str,
    mentor_name: str,
    mentor_description: str | None,
    claw_name: str,
    claw_server_url: str,
    claw_gateway_token: str,
    claw_type: str,
    agent_id: str,
    agent_config: dict,
    connection_params: dict | None = None,
) -> int:
    """Execute the full create sequence. Returns 0 on success, 1 on failure."""

    # 1. Create claw instance
    print(f"  → Creating claw instance '{claw_name}' …")
    try:
        claw_instance = create_claw_instance(
            session, host, tenant_key, claw_name, claw_server_url,
            claw_gateway_token, claw_type, connection_params,
        )
    except requests.HTTPError as exc:
        print(
            f"  ✗ claw instance create failed ({exc.response.status_code}): "
            f"{exc.response.text}",
            file=sys.stderr,
        )
        return 1
    except requests.RequestException as exc:
        print(f"  ✗ claw instance create failed: {exc}", file=sys.stderr)
        return 1

    claw_instance_id = claw_instance.get("id")
    print(f"  ✓ claw instance id={claw_instance_id} status={claw_instance.get('status')}")

    # 2. Create mentor
    print(f"  → Creating mentor '{mentor_name}' …")
    try:
        mentor = create_mentor(
            session, host, tenant_key, user_id, mentor_name, mentor_description,
        )
    except requests.HTTPError as exc:
        print(
            f"  ✗ mentor create failed ({exc.response.status_code}): "
            f"{exc.response.text}",
            file=sys.stderr,
        )
        return 1
    except requests.RequestException as exc:
        print(f"  ✗ mentor create failed: {exc}", file=sys.stderr)
        return 1

    mentor_unique_id = mentor.get("unique_id")
    if not mentor_unique_id:
        print(f"  ✗ mentor response missing unique_id: {mentor}", file=sys.stderr)
        return 1
    print(f"  ✓ mentor unique_id={mentor_unique_id}")

    # 3. Update mentor settings (allow_anonymous + enable_claw)
    print(f"  → Updating mentor settings …")
    try:
        update_mentor_settings(
            session, host, tenant_key, user_id, mentor_unique_id, mentor_description,
        )
    except requests.HTTPError as exc:
        print(
            f"  ✗ mentor settings PUT failed ({exc.response.status_code}): "
            f"{exc.response.text}",
            file=sys.stderr,
        )
        return 1
    except requests.RequestException as exc:
        print(f"  ✗ mentor settings PUT failed: {exc}", file=sys.stderr)
        return 1
    print("  ✓ mentor settings updated (allow_anonymous=True, enable_claw=True)")

    # 4. Create claw mentor config
    effective_agent_id = agent_id or slugify(mentor_name)
    print(f"  → Creating claw mentor config (agent_id={effective_agent_id!r}) …")
    try:
        claw_config = create_claw_mentor_config(
            session, host, tenant_key, mentor_unique_id, claw_instance_id,
            effective_agent_id, agent_config,
        )
    except requests.HTTPError as exc:
        print(
            f"  ✗ claw-config create failed ({exc.response.status_code}): "
            f"{exc.response.text}",
            file=sys.stderr,
        )
        return 1
    except requests.RequestException as exc:
        print(f"  ✗ claw-config create failed: {exc}", file=sys.stderr)
        return 1
    print(f"  ✓ claw-config id={claw_config.get('id')}")

    # 5. Patch canonical AgentConfig (only if agent_config was supplied)
    if agent_config:
        print("  → Patching canonical agent config …")
        try:
            patch_agent_config(session, host, tenant_key, mentor_unique_id, agent_config)
        except requests.HTTPError as exc:
            print(
                f"  ✗ agent-config PATCH failed ({exc.response.status_code}): "
                f"{exc.response.text}",
                file=sys.stderr,
            )
            return 1
        except requests.RequestException as exc:
            print(f"  ✗ agent-config PATCH failed: {exc}", file=sys.stderr)
            return 1
        print(f"  ✓ agent-config patched (keys={sorted(agent_config)})")

    print()
    print("Done.")
    print(f"  mentor_unique_id : {mentor_unique_id}")
    print(f"  claw_instance_id : {claw_instance_id}")
    print(f"  claw_config_id   : {claw_config.get('id')}")
    print(f"  agent_id         : {effective_agent_id}")
    return 0


# ── CLI ───────────────────────────────────────────────────────────────────────

def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)

    # Auth / connection
    parser.add_argument("--api-key", default=DUMMY_API_KEY, help="Tenant API key")
    parser.add_argument(
        "--host",
        default=DUMMY_HOST,
        help="DM server base URL (no trailing slash)",
    )
    parser.add_argument(
        "--tenant-key", default=DUMMY_TENANT_KEY, help="Tenant/org slug"
    )
    parser.add_argument(
        "--user-id", default=DUMMY_USER_ID, help="User id (mentor owner)"
    )

    # Agent
    parser.add_argument(
        "--agent-name",
        default=DUMMY_AGENT_NAME,
        help="Display name for the new agent",
    )
    parser.add_argument(
        "--agent-description",
        default=DUMMY_AGENT_DESCRIPTION or None,
        help="Short description for the agent (optional)",
    )

    # Claw instance
    parser.add_argument(
        "--claw-name",
        default=DUMMY_CLAW_NAME,
        help="Name for the new claw instance",
    )
    parser.add_argument(
        "--claw-server-url",
        default=DUMMY_CLAW_SERVER_URL,
        help="HTTPS URL of the claw server",
    )
    parser.add_argument(
        "--claw-gateway-token",
        default=DUMMY_CLAW_GATEWAY_TOKEN,
        help="Gateway token for the claw server",
    )
    parser.add_argument(
        "--claw-type",
        default=DUMMY_CLAW_TYPE,
        choices=["openclaw", "ironclaw", "nemoclaw"],
        help="Claw instance type (default: openclaw)",
    )
    parser.add_argument(
        "--device-key-pem",
        default=None,
        help=(
            "Path to an Ed25519 PKCS8 private-key PEM. Sent as "
            "connection_params.device_identity.private_key_pem "
            "(required for OpenClaw device identity / config push)."
        ),
    )

    # Agent config
    parser.add_argument(
        "--agent-id",
        default=DUMMY_AGENT_ID or "",
        help=(
            "agent_id written to the claw mentor config. "
            "Defaults to a slug derived from the mentor name."
        ),
    )
    parser.add_argument(
        "--agent-config",
        default=None,
        help=(
            "JSON string of agent config fields, e.g. "
            '\'{"identity": "Name: …", "soul": "…"}\'. '
            "Optional — omit to leave agent config empty."
        ),
    )

    return parser.parse_args()


def main() -> int:
    args = parse_args()

    host = args.host.rstrip("/")

    agent_config: dict = {}
    if args.agent_config:
        try:
            agent_config = json.loads(args.agent_config)
        except json.JSONDecodeError as exc:
            print(f"--agent-config is not valid JSON: {exc}", file=sys.stderr)
            return 2
        if not isinstance(agent_config, dict):
            print("--agent-config must be a JSON object", file=sys.stderr)
            return 2
    elif DUMMY_AGENT_CONFIG:
        agent_config = DUMMY_AGENT_CONFIG

    connection_params: dict = {}
    if args.device_key_pem:
        try:
            with open(args.device_key_pem, encoding="utf-8") as fh:
                pem = fh.read()
        except OSError as exc:
            print(f"--device-key-pem could not be read: {exc}", file=sys.stderr)
            return 2
        connection_params = {"device_identity": {"private_key_pem": pem}}

    session = requests.Session()
    session.headers.update(
        {
            "Authorization": f"Api-Token {args.api_key}",
            "Content-Type": "application/json",
            "Accept": "application/json",
        }
    )

    return run(
        session=session,
        host=host,
        tenant_key=args.tenant_key,
        user_id=args.user_id,
        mentor_name=args.agent_name,
        mentor_description=args.agent_description,
        claw_name=args.claw_name,
        claw_server_url=args.claw_server_url,
        claw_gateway_token=args.claw_gateway_token,
        claw_type=args.claw_type,
        agent_id=args.agent_id,
        agent_config=agent_config,
        connection_params=connection_params or None,
    )


if __name__ == "__main__":
    sys.exit(main())
