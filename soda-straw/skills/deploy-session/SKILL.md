---
name: deploy-session
description: >
  Productionize the current Claude Code session by deploying it to Anthropic
  Managed Agents, wired back to Soda Straw via MCP. Creates (or reuses) a
  Soda Straw Agent (workspace / access definition) and stands up a deployed
  runtime that uses it. The deployed agent gets scoped MCP access to exactly
  the straws used in the session - no manual key minting, no manual MCP
  config. Use when the user says "ship this", "deploy this", "productionize",
  "run this in prod", "save this and run it on a schedule", or similar.
  This is the default productionization path for Soda Straw work done in
  Claude Code.
compatibility: >
  Requires connection to the Soda Straw MCP endpoint at /mcp, plus at least
  one `managed_claude_agent` straw configured in Soda Straw (holds the
  Anthropic API key + the gateway URL the deployed agent will call back on).
allowed-tools: agents_create agents_list straws_list straws_tools straws_call
metadata:
  author: soda-straw
  version: "1.0"
  domain: build-plane
---

# Deploy Session

Take the Soda Straw work done in the current Claude Code session and
deploy it as an autonomous **Anthropic Managed Agent** wired back to
Soda Straw. This is the canonical "productionize" path: develop
interactively in Claude Code, then ship.

## Soda Straw's two-layer model

Two distinct things, easy to conflate:

- **Soda Straw Agent** — the *workspace* / access definition. Lists the
  straws (and permission per straw) a runtime is allowed to use.
  Doesn't run anything. Permission resolution is live, so editing
  the Agent's straws propagates to deployed runtimes without redeploy.
- **Deployed agent** — the *runtime* hosted on Anthropic's managed
  infra. Has a model, a system prompt, an event loop, and a session
  history. Talks to Soda Straw over MCP, scoped (via a minted API key)
  to the Soda Straw Agent it's bound to.

This skill creates / reuses the workspace **and** stands up the runtime,
in that order.

## Prerequisites

The user needs at least one straw of type `managed_claude_agent` already
configured. It holds:

- The Anthropic API key the deployment is billed against.
- A `gateway_url` reachable from Anthropic's infra (in local dev, an
  ngrok / cloudflared tunnel pointing at `localhost:8700`; in prod,
  Soda Straw's public URL).

If `straws_list(filter_type="managed_claude_agent")` returns nothing,
stop and tell the user:

```
I need a `managed_claude_agent` straw before I can deploy. Create one
with:

  straws_create(body={
    "type": "managed_claude_agent",
    "name": "anthropic-agents",
    "anthropic_api_key": "sk-ant-...",
    "gateway_url": "https://<your-public-url>"   # ngrok URL in dev
  })

Then re-run me.
```

## Strategy

### Step 1: Get / create the Soda Straw Agent (workspace)

Two paths, depending on the user's intent:

**a) The user already has a Soda Straw Agent they want to deploy.**
They referenced it by name or UUID, or said "deploy <name>".
Verify it exists with `agents_list` (or by trying `agents_get`), confirm
the straw set with the user, then skip to step 2.

**b) Promote-then-deploy from this session (the default).**
Run the inventory + classify logic from the `promote-session` skill:

1. Scan the transcript for `mcp__<server>__straws_call` invocations.
2. Build the `{straw -> tools_used}` map.
3. For each distinct straw, fetch `straws_tools(straw=...)`,
   classify each used tool's `access_mode`, take the max.
4. Map max mode → permission: `read` → `read`, `write` → `read_write`,
   `destructive` → `full`.

If the inventory is empty, tell the user "I don't see any Soda Straw
tool calls to deploy from yet." and stop.

Show the proposed Agent (workspace) **and** runtime config in one
confirmation pass — see step 3.

### Step 2: Pick the deploy target

If multiple `managed_claude_agent` straws exist (e.g. `anthropic-dev` and
`anthropic-prod`), ask the user which one to use. Default to the first
if there's only one.

### Step 3: Synthesise runtime config and confirm

Propose a deployed-agent config:

- **Name**: kebab-case, derived from the work (e.g. `invoice-sync`).
- **Model**: default `claude-opus-4-7` unless the user says otherwise.
- **System prompt**: a one-paragraph synthesis of what the session
  accomplished, framed as a job description for the runtime. Examples:
  - "You are an invoice-sync agent. Each run, fetch new invoices from
    QuickBooks, dedupe against existing entries in Notion, and write
    the new ones to the `Invoices` database. Surface anomalies (missing
    line items, mismatched totals) as comments instead of failing."
  - "You are a weekly-report agent. Pull last week's closed deals from
    Salesforce, summarise wins/losses, and post the digest to
    #revenue-weekly via the Slack straw."
- Pull the system prompt directly from explicit user instructions in
  the session when present; otherwise infer from the tool-call pattern.

Show one consolidated table and ask for confirmation:

```
I'll deploy this session.

Soda Straw Agent (workspace, new):
  Name:        acme-ops
  Straws:      notion (read), salesforce (read_write), pagerduty (full)

Anthropic Managed Agent (runtime, new):
  Straw:       anthropic-prod
  Name:        acme-ops
  Model:       claude-opus-4-7
  System:      "You are acme-ops. ..."

Proceed? (or tweak any field)
```

If the user wants to tweak the system prompt, name, model, or any
straw permission, accept the change before proceeding.

### Step 4: Create the Soda Straw Agent (workspace)

Skip if the user pointed at an existing Agent in step 1a.

```
agents_create(
  name=<confirmed-name>,
  description="Deployed from Claude Code session on <date>",
  straws=[ ... per step 1b ... ],
  trust_level="interactive",
)
```

Save the returned `id` as `<soda_straw_agent_id>`.

### Step 5: Ensure an Anthropic environment exists

Deployed agents need an environment (container template) for sessions.

1. List existing environments:
   ```
   straws_call(
     straw="<managed-agent-straw-name>",
     tool="environment_list",
   )
   ```
2. If at least one exists, pick the first and reuse its `id`.
3. Otherwise create a default cloud environment with unrestricted networking:
   ```
   straws_call(
     straw="<managed-agent-straw-name>",
     tool="environment_create",
     arguments={
       "name": "default",
       "config": {"type": "cloud", "networking": {"type": "unrestricted"}}
     }
   )
   ```
   Cache its `id` as `<environment_id>`.

### Step 6: Deploy the runtime

Call `agent_create` on the managed-agent straw, passing
`soda_straw_agent`. The straw adapter auto-mints a scoped API key,
provisions an Anthropic vault + `static_bearer` credential pointing at
the Soda Straw gateway, and injects `mcp_servers` + `mcp_toolset` into
the agent body. The user does not see or handle the key.

```
straws_call(
  straw="<managed-agent-straw-name>",
  tool="agent_create",
  arguments={
    "name": "<confirmed-name>",
    "model": "<confirmed-model>",
    "system": "<confirmed-system-prompt>",
    "tools": [{"type": "agent_toolset_20260401"}],
    "soda_straw_agent": "<soda_straw_agent_id>"
  }
)
```

Save the returned `id` as `<remote_agent_id>`. Note its `version` (1
for a fresh create).

### Step 7: Report

Surface concretely what was created and how to invoke it:

```
Deployed:
  Soda Straw Agent (workspace):  <soda_straw_agent_id>  - http://localhost:5799/agents/<soda_straw_agent_id>
  Anthropic Managed Agent:       <remote_agent_id> (v1)
  Environment:                   <environment_id>

To run a session against the deployed agent:

  straws_call(
    straw="<managed-agent-straw-name>",
    tool="session_create",
    arguments={
      "agent": "<remote_agent_id>",
      "environment_id": "<environment_id>",
      "title": "first run"
    }
  )

  # then drop a user.message:
  straws_call(
    straw="<managed-agent-straw-name>",
    tool="session_send_event",
    arguments={
      "session_id": "<session-id-from-above>",
      "events": [{"type": "user.message", "content": [{"type": "text", "text": "..."}]}]
    }
  )

  # and read what the agent did:
  straws_call(
    straw="<managed-agent-straw-name>",
    tool="session_events_list",
    arguments={"session_id": "<session-id>"}
  )
```

Offer to kick off the first session right now if it makes sense ("Want
me to run it once with `<sensible first message>` to confirm
everything's wired up?"). The user can decline and run later.

## Authorisation and rollback notes

- The caller must own each straw being assigned to the workspace, or
  hold an `IdentityStraw` grant at the right rank. Same rules as
  `promote-session`.
- The caller must have `read_write` (or higher) on the
  `managed_claude_agent` straw — `agent_create` is a write tool.
- If `agent_create` fails after the workspace was created, the
  workspace stays. That's fine; re-run the skill and pass the existing
  Agent in step 1a to deploy without re-promoting.
- If the auto-wire fails partway (vault created but credential failed,
  etc.), the adapter rolls back the Anthropic-side resources and
  revokes the minted key. You'll see a clear error from `agent_create`
  - surface it verbatim and stop.

## When NOT to use this skill

- The user wants a workspace but **not** a runtime — use
  `promote-session` directly.
- The user is editing an already-deployed agent (changing system prompt
  or model). That's an `agent_update` call against the
  `managed_claude_agent` straw, not a fresh deploy.
- No `managed_claude_agent` straw is configured — guide the user to
  create one first (see "Prerequisites" above) and stop.
- The session has zero Soda Straw tool calls and the user didn't
  reference an existing Agent — there's nothing to deploy.

## Local dev gotcha

For ngrok / tunnel setups: the deployed agent's vault credential pins
the `mcp_server_url` at create time and **cannot be edited**. If your
ngrok URL changes, the existing deployed agent will fail MCP calls. To
recover: delete (or archive) the deployed agent, update the
`gateway_url` on the `managed_claude_agent` straw, and re-run
`deploy-session`.
