---
name: promote-session
description: >
  Promote the current Claude Code session into a persistent Soda Straw Agent
  (a workspace / access definition: the set of straws + permissions a runtime
  can use, not a runtime in itself). Scans the transcript for tool calls to
  the Soda Straw MCP server, derives which straws were used and at what
  access level, and creates an Agent with exactly those straw assignments in
  one atomic call. Use when the user says "promote this session to an agent",
  "save this as an agent", or "create a workspace from what we just did".
  If the user wants the session to actually *run* autonomously (cron, on
  message, background), use the `deploy-session` skill instead - it wraps
  this one and then deploys the workspace to Anthropic Managed Agents.
compatibility: Requires connection to the Soda Straw MCP endpoint at /mcp.
allowed-tools: agents_create agents_list straws_list straws_tools
metadata:
  author: soda-straw
  version: "1.1"
  domain: build-plane
---

# Promote Session

Take the Soda Straw work done in the current Claude Code session and
register a persistent **Agent** (workspace / access definition) with
the same straw set.

## Soda Straw's two-layer model

It's important to keep these straight:

- **Soda Straw Agent** — a *workspace* or *access definition*. Records
  which straws the agent can use, at what permission level, plus
  optional skills and channels. **It does not run anything by itself.**
  Permissions resolve live through `AgentStraw`, so changes to the
  Agent's straw set propagate to any runtime pointed at it without
  redeploying.
- **Deployed agent** — the *runtime* (model + system prompt + loop +
  schedule). In Soda Straw, the canonical deploy target is Anthropic
  Managed Agents, reached via a `managed_claude_agent` straw. The
  deployed agent calls back into Soda Straw over MCP, scoped to the
  Agent (workspace) it was bound to.

This skill creates the workspace. Use the `deploy-session` skill if you
want to also stand up a runtime that uses it - that's the default
productionization path.

The user has been using their **personal API key** to talk to the Soda
Straw MCP. Every straw they touched during this session is a candidate
for the new Agent's assignments. Their explicit confirmation is required
before calling `agents_create`.

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

Ignore transcript entries that are errors, denied calls, or
management calls like `straws_list`, `straws_tools`, `straws_create` —
only the actual straw tool invocations count as "used in this session".

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

If a tool name isn't in the manifest (renamed, removed, or cached
under a prefix), treat it as `write` and flag it in the summary so the
user knows what fell through.

### Step 3: Confirm with the user

Show a compact table and a proposed Agent name/description:

```
I'll create the Soda Straw Agent (workspace) `acme-ops` from this session:

  Straw              Tools used            Permission
  -------            ----------            ----------
  notion             search, get_page      read
  salesforce         query, update_lead    read_write
  pagerduty          trigger_incident      full

  Description: "Promoted from Claude Code session on 2026-04-22"

This creates a workspace, not a running agent. Shall I proceed?
(or suggest a different name / tweak a permission)
```

Let the user tweak the name, description, or any per-straw permission
before confirming. If they ask to drop a straw entirely, remove it from
the payload.

### Step 4: Create the Agent (workspace)

Call `agents_create` in one shot:

```
agents_create(
  name="<confirmed-name>",
  description="<confirmed-description>",
  straws=[
    {"straw": "notion",      "permission": "read"},
    {"straw": "salesforce",  "permission": "read_write"},
    {"straw": "pagerduty",   "permission": "full"},
  ],
  trust_level="interactive",
)
```

The call is atomic — if any straw fails authorisation the whole thing
rolls back and no partial Agent is created.

### Step 5: Report and offer next step

Surface the returned `id` and a link (if the user is on localhost:
`http://localhost:5799/agents/<id>`). Briefly recap what straw access
the new Agent (workspace) has. Don't mention the API key — that stays
personal.

Then nudge toward productionization:

```
The Agent (workspace) is saved. It doesn't run anything yet — it's
just an access definition. To deploy it as a runtime that executes
autonomously, run the `deploy-session` skill (it'll take this Agent
and stand up an Anthropic Managed Agent wired back to Soda Straw).
```

## Authorisation notes

- The caller (you, acting as the user) must own each straw **or** already
  have `IdentityStraw` access at a rank ≥ the permission being granted.
  If `agents_create` returns `permission_denied`, it means the user was
  using a straw granted by someone else but trying to re-grant at a
  higher level than they themselves hold. Suggest a lower permission.
- If the user is attempting to assign a straw they have no access to
  (e.g. an admin-only demo), the call will fail. Tell them to request
  access first via the regular access-request flow, then re-run the
  skill.

## When NOT to use this skill

- The user wants the session to actually *run* (schedule, message
  trigger, background) — use `deploy-session` instead. That skill
  creates the Agent (workspace) AND the deployed runtime.
- The user just wants to *see* what happened in this session — no Agent
  needed. Show the inventory and stop.
- No Soda Straw tool calls happened — no useful promotion possible.
- The user is inside an existing Soda Straw Agent's run (not Claude
  Code). Agents don't spawn other Agents this way.

## Naming conventions

- Agent name: `kebab-case`. If the user didn't suggest one, propose
  something based on their current work (e.g. `invoice-sync`,
  `weekly-report`).
- Description: one line, ending with when it was promoted. Keep it
  factual; don't oversell.
