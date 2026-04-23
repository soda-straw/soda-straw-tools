# Instructions for agents installing this repo

You (the agent) have been asked to install the Soda Straw tools into the environment you're running in. Follow these steps exactly. Do **not** invoke `install.sh` or `/plugin ...` - those are entrypoints for humans. You have file-write access; use it directly.

## Step 1 - ask the user for credentials

Ask the user for two values and wait for both before continuing:

- **Soda Straw URL** - the base URL of their Soda Straw instance, e.g. `https://app.sodastraw.ai` or `https://localhost`. Strip any trailing slash.
- **API token** - a personal API token. If the user doesn't have one, tell them to generate one under **Settings > API tokens** in the Soda Straw UI, then come back with it. Treat this value as sensitive: don't echo it back, don't log it, don't write it anywhere except the config file in step 2.

## Step 2 - register the MCP server

Add a remote HTTP MCP server to the agent tool you're running in. The server spec is:

- **Name**: `soda-straw`
- **Transport**: `http` (streamable HTTP, not stdio)
- **URL**: `<SODA_STRAW_URL>/mcp`
- **Headers**: `Authorization: Bearer <API_TOKEN>`

Write it to whatever config file your host tool reads. Common locations (use the one that matches your host, or whatever equivalent applies):

- Claude Code: run `claude mcp add soda-straw --transport http --scope user --header "Authorization: Bearer <TOKEN>" <URL>/mcp`
- Codex CLI: `~/.codex/config.toml` under `[mcp_servers.soda-straw]`
- Cursor: `~/.cursor/mcp.json` under `mcpServers.soda-straw`
- Windsurf: `~/.windsurf/mcp_config.json` (or `~/.codeium/windsurf/mcp_config.json`) under `mcpServers.soda-straw`
- Gemini CLI: `~/.gemini/settings.json` under `mcpServers.soda-straw`
- OpenCode: `~/.config/opencode/config.json` under `mcp.soda-straw`

If the tool already has a `soda-straw` entry, overwrite it with the new values.

## Step 3 - install the skills

Clone this repo to a stable location if it isn't already there:

```
git clone https://github.com/sodadata/soda-straw-tools.git ~/.soda-straw-tools
```

Then symlink every subdirectory of `~/.soda-straw-tools/soda-straw/skills/` into your host tool's skills directory. Use the path convention for your host:

- Claude Code: `~/.claude/skills/`
- Codex CLI: `~/.codex/skills/`
- Cursor: `~/.cursor/skills/`
- Windsurf: `~/.windsurf/skills/`
- Gemini CLI: `~/.gemini/skills/`
- OpenCode: `~/.config/opencode/skills/`
- Fallback (cross-tool standard): `~/.agents/skills/`

Example (bash):

```
for s in ~/.soda-straw-tools/soda-straw/skills/*/; do
  ln -snf "$s" "<TARGET_SKILLS_DIR>/$(basename "$s")"
done
```

Skills follow the [Agent Skills spec](https://agentskills.io/specification); no format conversion needed.

## Step 4 - confirm and hand off

Tell the user, in one short message:

- Which MCP server was added and where its config was written (file path).
- Which skills were installed and where they were linked (directory).
- That they need to restart the tool (or reload the MCP connection) before the server shows up.
- That they can now say things like "promote this session to an agent" to use the `promote-session` skill.

Do not print the API token back. Do not recommend next actions beyond the restart.

## Failure modes

- **No write access** to the relevant config file - tell the user the exact path and the JSON/TOML block to paste; don't try to work around permissions.
- **Unknown host tool** - fall back to writing skills under `~/.agents/skills/` and ask the user where their tool keeps MCP configs.
- **URL rejected** (non-200 on a test request to `<URL>/mcp`) - tell the user; don't retry with a different URL.
