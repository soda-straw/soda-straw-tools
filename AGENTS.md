# Instructions for agents installing this repo

You (the agent) have been asked to install the Soda Straw tools into the environment you're running in. Follow these steps exactly. Do **not** invoke `install.sh` or `/plugin ...` - those are entrypoints for humans. You have file-write access; use it directly.

Soda Straw's `/mcp` endpoint is OAuth 2.1 protected (RFC 8414 + RFC 9728 metadata, RFC 7591 dynamic client registration, RFC 8628 device grant). The host tool's MCP HTTP transport handles the entire authorization flow on its own - you don't pre-mint a token, and you don't bake a bearer header into the config. The host stores tokens in its own credential store and refreshes them as needed.

## Step 1 - ask the user for their Soda Straw URL

Ask once: the base URL of their Soda Straw instance, e.g. `https://app.sodastraw.ai`. Strip any trailing slash.

## Step 2 - register the MCP server in the host's config

Write the MCP server entry. **Do not include any `Authorization` header.** The host will discover the OAuth metadata at `<URL>/.well-known/oauth-protected-resource`, run dynamic client registration against `<URL>/api/oauth/register`, drive the user through the browser auth flow on first connection, and rotate refresh tokens itself.

- **Name**: `soda-straw`
- **Transport**: `http`
- **URL**: `<URL>/mcp`

For Claude Code specifically, prefer the CLI:

```
claude mcp add soda-straw --transport http --scope user <URL>/mcp
```

Other config locations (write only `type: "http"` and `url`; **no `headers`**):

- Codex CLI: `~/.codex/mcp_servers.json` under `mcpServers.soda-straw`
- Cursor: `~/.cursor/mcp.json` under `mcpServers.soda-straw`
- Windsurf: `~/.windsurf/mcp_config.json` (or `~/.codeium/windsurf/mcp_config.json`) under `mcpServers.soda-straw`
- Gemini CLI: `~/.gemini/settings.json` under `mcpServers.soda-straw`
- OpenCode: `~/.config/opencode/config.json` under `mcp.soda-straw`

The user is prompted to authorize on the first connection - typically the next tool restart.

## Step 3 - install the skills

Clone this repo to a stable location if it isn't already there:

```
git clone https://github.com/soda-straw/soda-straw-tools.git ~/.soda-straw-tools
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

## Step 4 - keep the skills up to date

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

## Step 5 - confirm and guide the user through authorization

The MCP server is registered but unauthenticated. You can't trigger OAuth from your current session - the host won't surface the new MCP server until it restarts, and even if it did, OAuth must be driven by the host's MCP transport (not by you) so the host owns the token and can refresh it. Pre-minting a token here would break refresh, exactly as it did before.

Tell the user, in one short message:

- That the MCP server is registered (no token was minted; the host will run the OAuth flow itself).
- Where the MCP config was written (file path).
- Where the skills were linked (directory).
- That they need to **restart the host tool**, then **trigger the OAuth flow** with one of:
  - **Claude Code**: run `/mcp` and pick `soda-straw` -> Authenticate. (Or just ask the next session to call any Soda Straw tool, e.g. `mcp__soda-straw__whoami`, and the transport will pop the browser.)
  - **Codex CLI / Cursor / Windsurf / Gemini CLI / OpenCode**: in a fresh session, ask the agent to call `mcp__soda-straw__whoami` (or any Soda Straw tool). The host's MCP HTTP transport discovers the OAuth metadata, opens the browser, and stores the resulting token in its own keystore. Refresh is automatic from there.
- That a successful `whoami` reply (their email + workspace) means auth is wired up; if the browser doesn't open, fall back to the API-key path under "Failure modes".

## Failure modes

- **Host tool doesn't speak MCP OAuth.** Some hosts only accept a static `Authorization` header on HTTP MCPs and won't drive the auth flow themselves. In that case, do **not** mint a short-lived OAuth access token (it expires in ~1 hour with no refresh path on the host's end). Instead, ask the user to create a long-lived API key at `<URL>/settings?tab=api-keys`, paste it back to you, and write it as `Authorization: Bearer <api_key>` into the MCP config. API keys revoke individually and don't decay.
- **No write access** to the config file - print the file path and JSON block; don't try to work around permissions.
- **Unknown host tool** - fall back to writing skills under `~/.agents/skills/` and ask the user where their tool keeps MCP configs.
- **OAuth flow fails on first connection** (e.g. host can't open a browser, or the tunnel is unreachable) - the user can rerun the host's MCP authorization command (Claude Code: `/mcp`), or fall back to the API-key path above.
