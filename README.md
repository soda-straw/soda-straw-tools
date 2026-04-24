# Soda Straw Tools

Builder tooling for [Soda Straw](https://sodastraw.ai): the Soda Straw MCP connection plus a lightweight skill for promoting Claude Code sessions into persistent agents.

Authentication uses OAuth 2.1 with the device authorization flow - you authorize in your browser once, the installer (or plugin) handles the rest. No token paste.

## What's in here

- `soda-straw/` - a Claude Code plugin that bundles:
  - An MCP server connection to your Soda Straw `/mcp` endpoint. Claude Code handles OAuth discovery + authorization automatically via the `/.well-known/oauth-protected-resource` metadata the backend serves.
  - The `promote-session` skill: scans the current session for Soda Straw MCP tool calls and creates a persistent agent with exactly the straws that were used.
- `install.sh` - a fallback installer for tools without a Claude-Code-style plugin format. Runs the OAuth device flow, writes the MCP config, symlinks skills.
- `AGENTS.md` - natural-language install instructions for agents pointed at this repo.

Skills follow the [Agent Skills spec](https://agentskills.io/specification) and are portable to any tool that honors `SKILL.md` discovery (Claude Code, Claude Desktop, Cursor 2.4+, Windsurf, Gemini CLI, Codex CLI, OpenCode, GitHub Copilot, and more).

## Install - Claude Code

```
/plugin marketplace add sodadata/soda-straw-tools
/plugin install soda-straw@soda-straw-tools
```

You'll be prompted for your Soda Straw endpoint once. The first time the MCP server is called, Claude Code discovers the OAuth authorization server from `/.well-known/oauth-protected-resource`, opens your browser, and you approve the connection. The resulting token lives in your OS keychain and refreshes automatically.

## Install - via an agent

Point any AI coding agent (Claude Code, Codex, Cursor, etc.) at this repo and ask it to install the tools:

> Install https://github.com/sodadata/soda-straw-tools

The agent will read [`AGENTS.md`](AGENTS.md) and walk you through the setup.

## Install - other tools

```
curl -fsSL https://raw.githubusercontent.com/sodadata/soda-straw-tools/main/install.sh | bash
```

The script:

1. Asks for your Soda Straw endpoint.
2. Registers this host as an OAuth client (once, cached locally).
3. Starts the device flow: prints a URL + short code, tells you to open the URL in your browser.
4. Polls until you approve.
5. Detects installed tools (Cursor, Windsurf, Gemini CLI, OpenCode, Codex CLI, Claude Code) and writes the MCP config + symlinks skills.

No token paste at any point. The refresh token is cached at `~/.soda-straw-tools/refresh_token` (mode 600) so rerunning the installer silently rotates the access token.

## Update

```
/plugin update soda-straw@soda-straw-tools
```

Or, for script-based installs, re-run `install.sh`.

## Development

Skills are maintained in this repo. To test changes locally without publishing:

```
/plugin marketplace add /path/to/soda-straw-tools
```

Then install as usual. Edits to `SKILL.md` files are picked up on the next invocation.
