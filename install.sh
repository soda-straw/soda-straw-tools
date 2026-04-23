#!/usr/bin/env bash
# Soda Straw tools - cross-tool installer
#
# Detects installed AI agent tools, wires up the Soda Straw MCP
# connection, and links in the Soda Straw skills bundle.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/sodadata/soda-straw-tools/main/install.sh | bash
#   SODA_STRAW_URL=https://my-instance.sodastraw.ai SODA_STRAW_TOKEN=... bash install.sh
#
# For Claude Code, prefer:
#   /plugin marketplace add sodadata/soda-straw-tools
#   /plugin install soda-straw@soda-straw-tools
# The plugin flow manages updates automatically and stores the token in the
# system keychain.

set -euo pipefail

REPO_URL="https://github.com/sodadata/soda-straw-tools.git"
INSTALL_DIR="${SODA_STRAW_INSTALL_DIR:-$HOME/.soda-straw-tools}"

log() { printf "\033[36m==>\033[0m %s\n" "$*"; }
warn() { printf "\033[33mwarn:\033[0m %s\n" "$*" >&2; }
err() { printf "\033[31merror:\033[0m %s\n" "$*" >&2; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

# ---- fetch the repo ---------------------------------------------------------

ensure_repo() {
  if [[ -d "$INSTALL_DIR/.git" ]]; then
    log "Updating $INSTALL_DIR"
    git -C "$INSTALL_DIR" pull --ff-only --quiet
  else
    log "Cloning to $INSTALL_DIR"
    git clone --quiet "$REPO_URL" "$INSTALL_DIR"
  fi
}

# ---- prompt for config ------------------------------------------------------

prompt_config() {
  if [[ -z "${SODA_STRAW_URL:-}" ]]; then
    read -r -p "Soda Straw endpoint [https://localhost]: " SODA_STRAW_URL
    SODA_STRAW_URL="${SODA_STRAW_URL:-https://localhost}"
  fi
  SODA_STRAW_URL="${SODA_STRAW_URL%/}"

  if [[ -z "${SODA_STRAW_TOKEN:-}" ]]; then
    read -r -s -p "API token (generate one under Settings > API tokens): " SODA_STRAW_TOKEN
    echo
  fi
  [[ -n "$SODA_STRAW_TOKEN" ]] || err "API token is required"
}

# ---- per-tool wiring --------------------------------------------------------

SKILLS_SRC="$INSTALL_DIR/soda-straw/skills"

# Symlink each skill under $SKILLS_SRC into $1 (the target skills directory).
link_skills() {
  local target_dir="$1"
  mkdir -p "$target_dir"
  local count=0
  for skill in "$SKILLS_SRC"/*/; do
    local name
    name="$(basename "$skill")"
    ln -snf "$skill" "$target_dir/$name"
    count=$((count + 1))
  done
  log "  linked $count skills into $target_dir"
}

# Write an MCP config block for HTTP transport to $1 using jq.
# Signature: write_mcp_http <config_file> <server_name> <top_level_key>
write_mcp_http() {
  local file="$1" name="$2" key="$3"
  local tmp
  tmp="$(mktemp)"
  [[ -f "$file" ]] || echo '{}' > "$file"
  jq --arg name "$name" \
     --arg key "$key" \
     --arg url "$SODA_STRAW_URL/mcp" \
     --arg auth "Bearer $SODA_STRAW_TOKEN" \
     '.[$key] = (.[$key] // {}) | .[$key][$name] = {
        type: "http",
        url: $url,
        headers: { Authorization: $auth }
      }' "$file" > "$tmp" && mv "$tmp" "$file"
  log "  wrote MCP config to $file"
}

setup_claude_code() {
  [[ -d "$HOME/.claude" ]] || return 1
  log "Claude Code detected"
  warn "  for Claude Code, prefer: /plugin marketplace add sodadata/soda-straw-tools && /plugin install soda-straw@soda-straw-tools"
  link_skills "$HOME/.claude/skills"
  # Claude Code uses `claude mcp add` rather than a static JSON; invoke it if available.
  if have claude; then
    claude mcp add soda-straw \
      --transport http \
      --scope user \
      --header "Authorization: Bearer $SODA_STRAW_TOKEN" \
      "$SODA_STRAW_URL/mcp" 2>/dev/null || warn "  claude mcp add failed (already configured?)"
  fi
}

setup_codex() {
  [[ -d "$HOME/.codex" ]] || have codex || return 1
  log "Codex CLI detected"
  mkdir -p "$HOME/.codex"
  link_skills "$HOME/.codex/skills"
  local cfg="$HOME/.codex/mcp_servers.json"
  write_mcp_http "$cfg" "soda-straw" "mcpServers"
}

setup_cursor() {
  [[ -d "$HOME/.cursor" ]] || return 1
  log "Cursor detected"
  # Cursor reads skills from ~/.cursor/skills/ and MCP from ~/.cursor/mcp.json
  link_skills "$HOME/.cursor/skills"
  write_mcp_http "$HOME/.cursor/mcp.json" "soda-straw" "mcpServers"
}

setup_windsurf() {
  local base=""
  if [[ -d "$HOME/.windsurf" ]]; then
    base="$HOME/.windsurf"
  elif [[ -d "$HOME/.codeium/windsurf" ]]; then
    base="$HOME/.codeium/windsurf"
  else
    return 1
  fi
  log "Windsurf detected"
  link_skills "$base/skills"
  write_mcp_http "$base/mcp_config.json" "soda-straw" "mcpServers"
}

setup_gemini() {
  [[ -d "$HOME/.gemini" ]] || have gemini || return 1
  log "Gemini CLI detected"
  mkdir -p "$HOME/.gemini"
  link_skills "$HOME/.gemini/skills"
  write_mcp_http "$HOME/.gemini/settings.json" "soda-straw" "mcpServers"
}

setup_opencode() {
  local base=""
  if [[ -d "$HOME/.config/opencode" ]]; then
    base="$HOME/.config/opencode"
  elif [[ -d "$HOME/.opencode" ]]; then
    base="$HOME/.opencode"
  elif have opencode; then
    base="$HOME/.config/opencode"
    mkdir -p "$base"
  else
    return 1
  fi
  log "OpenCode detected"
  # OpenCode honors .agents/skills/ as a portable path.
  link_skills "$base/skills"
  write_mcp_http "$base/config.json" "soda-straw" "mcp"
}

# ---- main -------------------------------------------------------------------

have git || err "git is required"
have jq  || err "jq is required (brew install jq / apt install jq)"

ensure_repo
prompt_config

installed_any=0
for fn in setup_claude_code setup_codex setup_cursor setup_windsurf setup_gemini setup_opencode; do
  if $fn; then installed_any=1; fi
done

if [[ "$installed_any" -eq 0 ]]; then
  warn "No supported AI tools detected."
  warn "Supported: Claude Code, Codex CLI, Cursor, Windsurf, Gemini CLI, OpenCode."
  exit 1
fi

log "Done. Restart your tools to pick up the new MCP server and skills."
