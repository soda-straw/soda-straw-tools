# Soda Straw Tools

Builder tooling for [Soda Straw](https://sodastraw.ai): the Soda Straw MCP connection plus a lightweight skill for promoting Claude Code sessions into persistent agents.

## What's in here

- `soda-straw/` - a Claude Code plugin that bundles:
  - An MCP server connection to your Soda Straw `/mcp` endpoint (bearer-token auth, keychain-stored)
  - The `promote-session` skill: scans the current session for Soda Straw MCP tool calls and creates a persistent agent with exactly the straws that were used
- `install.sh` - a fallback installer for tools without a Claude-Code-style plugin format (Cursor, Windsurf, Gemini CLI, OpenCode, Codex CLI)

Skills follow the [Agent Skills spec](https://agentskills.io/specification) and are portable to any tool that honors `SKILL.md` discovery (Claude Code, Claude Desktop, Cursor 2.4+, Windsurf, Gemini CLI, Codex CLI, OpenCode, GitHub Copilot, and more).

## Install - Claude Code

```
/plugin marketplace add sodadata/soda-straw-tools
/plugin install soda-straw@soda-straw-tools
```

You'll be prompted for your Soda Straw endpoint and a personal API token. Both are stored in your OS keychain; the token is injected as a bearer header on every MCP call.

To generate a token, log in to your Soda Straw instance and open **Settings > API tokens**.

## Install - via an agent

Point any AI coding agent (Claude Code, Codex, Cursor, etc.) at this repo and ask it to install the tools:

> Install https://github.com/sodadata/soda-straw-tools

The agent will read [`AGENTS.md`](AGENTS.md) and walk you through the setup: prompting for your Soda Straw URL and API token, wiring the MCP server into its config, and linking the skills directory.

## Install - other tools

```
curl -fsSL https://raw.githubusercontent.com/sodadata/soda-straw-tools/main/install.sh | bash
```

The script detects which compatible tools are installed locally and wires up the MCP connection + symlinks the skills directory. Supports Cursor, Windsurf, Gemini CLI, OpenCode, Codex CLI, and Claude Code.

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
