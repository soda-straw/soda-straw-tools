---
name: promote-session
description: >
  Promote the current Claude Code session into a persistent Soda Straw agent.
  Scans the transcript for tool calls to the Soda Straw MCP server, derives
  which straws were used and at what access level, and creates an agent with
  exactly those straw assignments in one atomic call. Use when the user says
  "promote this session to an agent", "save this as an agent", or "create an
  agent from what we just did".
compatibility: Requires connection to the Soda Straw MCP endpoint at /mcp.
allowed-tools: agents_create agents_list straws_list straws_tools
metadata:
  author: soda-straw
  version: "1.0"
  domain: build-plane
---

# Promote Session

Take the Soda Straw work done in the current Claude Code session and
register a persistent agent with access to the same straws.

The user has been using their **personal API key** to talk to the Soda
Straw MCP. Every straw they touched during this session is a candidate
for the new agent's assignments. Their explicit confirmation is required
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

Show a compact table and a proposed agent name/description:

```
I'll create agent `acme-ops` from this session:

  Straw              Tools used            Permission
  -------            ----------            ----------
  notion             search, get_page      read
  salesforce         query, update_lead    read_write
  pagerduty          trigger_incident      full

  Description: "Promoted from Claude Code session on 2026-04-22"

Shall I proceed? (or suggest a different name / tweak a permission)
```

Let the user tweak the name, description, or any per-straw permission
before confirming. If they ask to drop a straw entirely, remove it from
the payload.

### Step 4: Create the agent

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
rolls back and no partial agent is created.

### Step 5: Report

Surface the returned `id` and a link (if the user is on localhost:
`http://localhost:5799/agents/<id>`). Briefly recap what access the
new agent has. Don't mention the API key — that stays personal.

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

- The user just wants to *see* what happened in this session — no agent
  needed. Show the inventory and stop.
- No Soda Straw tool calls happened — no useful promotion possible.
- The user is inside an existing Soda Straw agent's run (not Claude
  Code). Agents don't spawn other agents this way.

## Naming conventions

- Agent name: `kebab-case`. If the user didn't suggest one, propose
  something based on their current work (e.g. `invoice-sync`,
  `weekly-report`).
- Description: one line, ending with when it was promoted. Keep it
  factual; don't oversell.
