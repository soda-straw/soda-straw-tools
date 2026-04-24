# Instructions for agents installing this repo

You (the agent) have been asked to install the Soda Straw tools into the environment you're running in. Follow these steps exactly. Do **not** invoke `install.sh` or `/plugin ...` - those are entrypoints for humans. You have file-write access; use it directly.

Soda Straw uses OAuth 2.1 device authorization (RFC 8628), so the user authenticates in their browser - no token paste.

## Step 1 - ask the user for their Soda Straw URL

Ask once: the base URL of their Soda Straw instance, e.g. `https://app.sodastraw.ai`. Strip any trailing slash.

## Step 2 - register this host as an OAuth client (one-time)

```
POST <URL>/api/oauth/register
Content-Type: application/json

{
  "client_name": "Soda Straw installer on <hostname>",
  "redirect_uris": ["http://localhost:0/callback"],
  "grant_types": [
    "urn:ietf:params:oauth:grant-type:device_code",
    "refresh_token"
  ],
  "response_types": ["code"],
  "token_endpoint_auth_method": "none"
}
```

Cache the returned `client_id` somewhere persistent (e.g. `~/.soda-straw-tools/client.json`). You only need to do this once per host.

## Step 3 - begin the device flow

```
POST <URL>/api/oauth/device_authorization
Content-Type: application/x-www-form-urlencoded

client_id=<stored_client_id>
scope=mcp
device_metadata={"hostname":"<hostname>"}
```

Response contains `device_code`, `user_code`, `verification_uri_complete`, `interval`, `expires_in`.

Print to the user, clearly:

```
Authorize this installation:
  Open:   <verification_uri_complete>
  Code:   <user_code>
```

## Step 4 - poll for approval

Every `interval` seconds:

```
POST <URL>/api/oauth/token
Content-Type: application/x-www-form-urlencoded

grant_type=urn:ietf:params:oauth:grant-type:device_code
device_code=<device_code>
client_id=<stored_client_id>
```

The server returns one of:

- `{ access_token, refresh_token, ... }` - success. Proceed to step 5.
- `{"detail":{"error":"authorization_pending"}}` - continue polling.
- `{"detail":{"error":"slow_down"}}` - continue polling (you polled too fast; the server has bumped your last-polled timestamp).
- `{"detail":{"error":"access_denied"}}` - user denied. Tell them and stop.
- `{"detail":{"error":"expired_token"}}` - the device code expired. Tell them and stop.

Respect the `interval` and don't poll faster than that.

## Step 5 - register the MCP server

Write the MCP server config into the host tool's config file. Use the `access_token` as the bearer:

- **Name**: `soda-straw`
- **Transport**: `http`
- **URL**: `<URL>/mcp`
- **Headers**: `Authorization: Bearer <access_token>`

For Claude Code specifically, prefer the CLI: `claude mcp add soda-straw --transport http --scope user --header "Authorization: Bearer <access_token>" <URL>/mcp`.

Other config locations:

- Codex CLI: `~/.codex/mcp_servers.json` under `mcpServers.soda-straw`
- Cursor: `~/.cursor/mcp.json` under `mcpServers.soda-straw`
- Windsurf: `~/.windsurf/mcp_config.json` (or `~/.codeium/windsurf/mcp_config.json`) under `mcpServers.soda-straw`
- Gemini CLI: `~/.gemini/settings.json` under `mcpServers.soda-straw`
- OpenCode: `~/.config/opencode/config.json` under `mcp.soda-straw`

## Step 6 - install the skills

Clone this repo to a stable location if it isn't already there:

```
git clone https://github.com/sodadata/soda-straw-tools.git ~/.soda-straw-tools
```

Symlink every subdirectory of `~/.soda-straw-tools/soda-straw/skills/` into the host tool's skills directory:

- Claude Code: `~/.claude/skills/`
- Codex CLI: `~/.codex/skills/`
- Cursor: `~/.cursor/skills/`
- Windsurf: `~/.windsurf/skills/`
- Gemini CLI: `~/.gemini/skills/`
- OpenCode: `~/.config/opencode/skills/`
- Fallback (cross-tool standard): `~/.agents/skills/`

Skills follow the [Agent Skills spec](https://agentskills.io/specification); no format conversion needed.

## Step 7 - keep the skills up to date

The skills evolve. Configure the host tool to refresh `~/.soda-straw-tools` once per session so updates land without the user thinking about it. The command to wire up:

```
git -C ~/.soda-straw-tools pull --quiet || true
```

The `|| true` keeps a bad network from blocking session startup. Use a ~10s timeout if the host tool exposes one.

Translate to whatever startup-hook mechanism the host tool offers:

- **Claude Code**: write to `~/.claude/settings.json` under `hooks.SessionStart` with `matcher: "startup"`, type `command`. Claude Code watches skill files live, so pulled changes take effect mid-session.
  ```json
  {
    "hooks": {
      "SessionStart": [
        {
          "matcher": "startup",
          "hooks": [
            { "type": "command", "command": "git -C ~/.soda-straw-tools pull --quiet || true", "timeout": 10, "statusMessage": "Syncing soda-straw skills" }
          ]
        }
      ]
    }
  }
  ```
- **Other tools** (Codex CLI, Cursor, Windsurf, Gemini CLI, OpenCode): check the tool's docs for an equivalent "on session start" or "pre-prompt" hook and wire the same command. If no such mechanism exists, skip the hook and tell the user to run `git -C ~/.soda-straw-tools pull` manually when they want updates.

Merge into existing hook config rather than overwriting it.

## Step 8 - confirm and hand off

Tell the user, in one short message:

- That the OAuth grant succeeded and the MCP server is configured.
- Where the MCP config was written (file path).
- Where the skills were linked (directory).
- That they should restart the tool.

Do not print the access/refresh tokens back. Stash the refresh token if you want automatic re-rotation (at `~/.soda-straw-tools/refresh_token`, mode 600); otherwise discard it after writing the MCP config.

## Failure modes

- **DCR rejected** (400 `invalid_redirect_uri`) - the Soda Straw instance URL may be wrong; double-check with the user.
- **No write access** to the config file - print the file path and JSON block; don't try to work around permissions.
- **Unknown host tool** - fall back to writing skills under `~/.agents/skills/` and ask the user where their tool keeps MCP configs.
- **Token rejected by /mcp** (401 Unauthorized) - the access token may have expired; rerun the device flow.
