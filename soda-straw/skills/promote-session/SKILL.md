---
name: promote-session
description: >
  Productionize the current Claude Code session: create a Soda Straw Agent
  (workspace / access definition) from the straws used in this session, then
  deploy it as an autonomous runtime on Anthropic Managed Agents wired back
  to Soda Straw via MCP. The deployed agent gets scoped MCP access to
  exactly the straws used - no manual key minting, no manual MCP config.
  Use when the user says "promote this session", "save this as an agent",
  "ship this", "deploy this", "productionize", "run this on a schedule", or
  similar. This is the default path for taking interactive Claude Code work
  to production. Falls back to workspace-only when no `managed_claude_agent`
  straw is configured (and tells the user how to add one).
compatibility: Requires connection to the Soda Straw MCP endpoint at /mcp.
allowed-tools: agents_create agents_list straws_list straws_tools straws_call
metadata:
  author: soda-straw
  version: "2.0"
  domain: build-plane
---

# Promote Session

Take the Soda Straw work done in the current Claude Code session and ship
it: create a persistent **Agent** (workspace) and a **deployed runtime**
on Anthropic Managed Agents, all in one go.

## Soda Straw's two-layer model

Two things, easy to conflate:

- **Soda Straw Agent** — the *workspace* / access definition. Lists the
  straws (and per-straw permission) a runtime is allowed to use. It
  doesn't run anything by itself. Permission resolution is live, so
  editing the Agent's straws propagates to deployed runtimes without a
  redeploy.
- **Deployed agent** — the *runtime* hosted on Anthropic's managed
  infra. Has a model, a system prompt, an event loop, and session
  history. Talks to Soda Straw over MCP, scoped (via a minted API key)
  to the Soda Straw Agent it was bound to.

This skill creates both, in that order. If the user only wants the
workspace (no `managed_claude_agent` straw configured, or they
explicitly say "just the workspace"), it gracefully falls back to
creating the Agent only.

The user has been using their **personal API key** to talk to the Soda
Straw MCP. Every straw they touched during this session is a candidate
for the new Agent's assignments. Their explicit confirmation is required
before anything is created.

## Strategy

### Step 1: Inventory the session

Look back through the current conversation transcript for every tool
call whose name matches `mcp__<server>__straws_call` (the server name
is whatever the user registered with `claude mcp add`; commonly
`soda-straw`). Each such call has:

- `straw` — the straw name or UUID the tool was invoked on
- `tool` — the underlying tool name on that straw

Build a map:

```
{
  "<straw-identifier>": {
    "tools_used": ["tool_a", "tool_b", ...],
  },
  ...
}
```

Ignore transcript entries that are errors, denied calls, or management
calls like `straws_list`, `straws_tools`, `straws_create` — only actual
straw tool invocations count as "used in this session".

If the inventory is empty, tell the user "I don't see any Soda Straw
tool calls in this session — there's nothing to promote yet." and stop.

### Step 2: Classify each straw's required permission

For each distinct straw in the inventory, call `straws_tools(straw=...)`
to fetch the tool manifest. Each tool in the manifest has an
`access_mode`: `read`, `write`, or `destructive`. Look up the mode for
every tool the session used on that straw and compute the **max** mode
seen:

| Max mode seen | Permission to grant |
|---------------|---------------------|
| only `read`   | `read`              |
| any `write`   | `read_write`        |
| any `destructive` | `full`          |

If a tool name isn't in the manifest (renamed, removed, or cached under
a prefix), treat it as `write` and flag it in the summary so the user
knows what fell through.

### Step 3: Pick a deploy target (or fall back to workspace-only)

Call `straws_list` and look for straws with `type == "managed_claude_agent"`.

- **None found**: graceful degrade. Tell the user:
  ```
  No `managed_claude_agent` straw is configured, so I can only save the
  workspace right now. To deploy a runtime later, add one (Anthropic API
  key + a public gateway URL — for local dev that's an ngrok tunnel):

    straws_create(body={
      "type": "managed_claude_agent",
      "name": "anthropic-agents",
      "anthropic_api_key": "sk-ant-...",
      "gateway_url": "https://<your-public-url>"
    })

  Then re-run me. For now, want me to just save the workspace?
  ```
  If the user says yes, jump to step 5 (workspace only). Otherwise stop.
- **One found**: that's the target.
- **Multiple found**: ask the user which one (e.g. `anthropic-dev` vs
  `anthropic-prod`). Cache the choice as `<deploy_straw>`.

### Step 4: Synthesise the deployed-agent config

For the deploy path only (skip if workspace-only):

- **Name**: kebab-case, derived from the work (e.g. `invoice-sync`).
  Reuse the workspace name unless the user wants them to differ.
- **Model**: default `claude-opus-4-7` unless the user says otherwise.
- **System prompt**: a one-paragraph synthesis of what the session
  accomplished, framed as a job description for the runtime. Pull
  directly from explicit user instructions in the session when
  present; otherwise infer from the tool-call pattern. Examples:
  - "You are an invoice-sync agent. Each run, fetch new invoices from
    QuickBooks, dedupe against existing entries in Notion, and write
    the new ones to the `Invoices` database. Surface anomalies (missing
    line items, mismatched totals) as comments instead of failing."
  - "You are a weekly-report agent. Pull last week's closed deals from
    Salesforce, summarise wins/losses, and post the digest to
    #revenue-weekly via the Slack straw."

### Step 5: Confirm with the user (one consolidated pass)

Show the Agent (workspace) and runtime config in a single confirmation:

```
I'll promote this session.

Soda Straw Agent (workspace, new):
  Name:        acme-ops
  Description: "Promoted from Claude Code session on 2026-04-27"
  Straws:      notion (read), salesforce (read_write), pagerduty (full)

Anthropic Managed Agent (runtime, new):
  Straw:       anthropic-prod
  Name:        acme-ops
  Model:       claude-opus-4-7
  System:      "You are acme-ops. ..."

Proceed? (or tweak any field)
```

For the workspace-only fallback, drop the runtime block. Let the user
tweak the name, description, system prompt, model, or any per-straw
permission before confirming. If they ask to drop a straw entirely,
remove it.

### Step 6: Create the Agent (workspace)

```
agents_create(
  name=<confirmed-name>,
  description="Promoted from Claude Code session on <date>",
  straws=[ ... per step 2 ... ],
  trust_level="interactive",
)
```

The call is atomic — if any straw fails authorisation the whole thing
rolls back and no partial Agent is created.

Save the returned `id` as `<soda_straw_agent_id>`. If the user opted
for workspace-only, jump to step 9.

### Step 7: Ensure an Anthropic environment exists

Deployed agents need an environment (container template) for sessions.

1. List existing environments on the deploy straw:
   ```
   straws_call(straw=<deploy_straw>, tool="environment_list")
   ```
2. If at least one exists, reuse the first.
3. Otherwise create a default cloud environment with unrestricted
   networking:
   ```
   straws_call(
     straw=<deploy_straw>,
     tool="environment_create",
     arguments={
       "name": "default",
       "config": {"type": "cloud", "networking": {"type": "unrestricted"}}
     }
   )
   ```
   Cache its `id` as `<environment_id>`.

### Step 8: Deploy the runtime

Call `agent_create` on the deploy straw, passing `soda_straw_agent`.
The straw adapter auto-mints a scoped API key, provisions an Anthropic
vault + `static_bearer` credential pointing at the Soda Straw gateway,
and injects `mcp_servers` + `mcp_toolset` into the agent body. The
user does not see or handle the key.

```
straws_call(
  straw=<deploy_straw>,
  tool="agent_create",
  arguments={
    "name": <confirmed-name>,
    "model": <confirmed-model>,
    "system": <confirmed-system-prompt>,
    "tools": [{"type": "agent_toolset_20260401"}],
    "soda_straw_agent": <soda_straw_agent_id>
  }
)
```

Save the returned `id` as `<remote_agent_id>`.

### Step 9: Report

Surface what was created and how to use it.

**Workspace-only** (deploy-skipped):

```
Saved Soda Straw Agent (workspace): <soda_straw_agent_id>
  - http://localhost:5799/agents/<soda_straw_agent_id>

This is just an access definition. To deploy a runtime later, add a
`managed_claude_agent` straw and re-run me.
```

**Full deploy**:

```
Deployed:
  Soda Straw Agent (workspace):  <soda_straw_agent_id>
    http://localhost:5799/agents/<soda_straw_agent_id>
  Anthropic Managed Agent:       <remote_agent_id>
  Environment:                   <environment_id>

To run a session:

  straws_call(
    straw=<deploy_straw>,
    tool="session_create",
    arguments={
      "agent": "<remote_agent_id>",
      "environment_id": "<environment_id>",
      "title": "first run"
    }
  )

  straws_call(
    straw=<deploy_straw>,
    tool="session_send_event",
    arguments={
      "session_id": "<session-id>",
      "events": [{"type": "user.message", "content": [{"type": "text", "text": "..."}]}]
    }
  )

  straws_call(
    straw=<deploy_straw>,
    tool="session_events_list",
    arguments={"session_id": "<session-id>"}
  )
```

Offer to kick off the first session now ("Want me to invoke it once
with `<sensible first message>` to confirm the wiring?"). The user can
decline and run it later. Don't mention the personal API key — that
stays personal.

## Authorisation and rollback notes

- The caller must own each straw being assigned to the workspace, or
  hold an `IdentityStraw` grant at the right rank. If `agents_create`
  returns `permission_denied`, the user is using a straw granted by
  someone else but trying to re-grant at a higher level than they
  themselves hold. Suggest a lower permission.
- The caller must have `read_write` (or higher) on the
  `managed_claude_agent` straw — `agent_create` is a write tool.
- If `agent_create` fails after the workspace was created, the
  workspace stays. That's fine; re-run me and reference the existing
  Agent by name to skip the promote step (just say "deploy
  <agent-name>").
- If the auto-wire fails partway (vault created but credential failed,
  etc.), the adapter rolls back the Anthropic-side resources and
  revokes the minted key. Surface the error from `agent_create`
  verbatim and stop.

## When NOT to use this skill

- The user is editing an already-deployed agent (changing system prompt
  or model) — that's an `agent_update` call against the
  `managed_claude_agent` straw, not a fresh promote.
- The user just wants to *see* what happened in this session — show
  the inventory and stop.
- No Soda Straw tool calls happened *and* no existing Agent was
  referenced — there's nothing to promote.
- The user is inside an already-deployed agent's run (not Claude Code).
  Agents don't spawn other Agents this way.

## Local dev gotcha (ngrok / tunnels)

The deployed agent's vault credential pins the `mcp_server_url` at
create time and **cannot be edited**. If your ngrok URL rotates, the
existing deployed agent will fail MCP calls. To recover: delete (or
archive) the deployed agent, update `gateway_url` on the
`managed_claude_agent` straw, and re-run me.

## Naming conventions

- Agent name: `kebab-case`. If the user didn't suggest one, propose
  something based on their current work (e.g. `invoice-sync`,
  `weekly-report`).
- Description: one line, ending with when it was promoted. Keep it
  factual; don't oversell.
