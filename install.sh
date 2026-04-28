#!/usr/bin/env bash
# Soda Straw tools - cross-tool installer
#
# Detects installed AI agent tools, wires up the Soda Straw MCP
# connection, and links in the Soda Straw skills bundle. Soda Straw's
# /mcp endpoint speaks OAuth 2.1 (RFC 8414 / 9728 metadata, RFC 7591
# DCR, RFC 8628 device grant) - we let each host's MCP HTTP transport
# drive the auth flow itself on first connect, so this script never
# mints a token. The host stores and refreshes credentials in its own
# keystore.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/soda-straw/soda-straw-tools/main/install.sh | bash
#   SODA_STRAW_URL=https://my-instance.sodastraw.ai bash install.sh
#
# For hosts that don't support MCP OAuth on HTTP transports, set
# SODA_STRAW_API_KEY to a long-lived API key minted in the Soda Straw
# UI (Settings -> API keys). The script will then write a static
# Authorization header instead of leaving auth to the host:
#   SODA_STRAW_API_KEY=ssk_... bash install.sh
#
# For Claude Code, prefer:
#   /plugin marketplace add soda-straw/soda-straw-tools
#   /plugin install soda-straw@soda-straw-tools

set -euo pipefail

REPO_URL="https://github.com/soda-straw/soda-straw-tools.git"
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

# ---- prompt for endpoint ----------------------------------------------------

prompt_endpoint() {
  if [[ -z "${SODA_STRAW_URL:-}" ]]; then
    read -r -p "Soda Straw endpoint [https://app.sodastraw.ai]: " SODA_STRAW_URL
    SODA_STRAW_URL="${SODA_STRAW_URL:-https://app.sodastraw.ai}"
  fi
  SODA_STRAW_URL="${SODA_STRAW_URL%/}"
}

# ---- per-tool wiring --------------------------------------------------------

SKILLS_SRC="$INSTALL_DIR/soda-straw/skills"

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

# Write an MCP HTTP entry. If SODA_STRAW_API_KEY is set, include a
# static Authorization header; otherwise emit URL only and let the
# host drive OAuth on first connect.
write_mcp_http() {
  local file="$1" name="$2" key="$3"
  local tmp
  tmp="$(mktemp)"
  [[ -f "$file" ]] || echo '{}' > "$file"
  if [[ -n "${SODA_STRAW_API_KEY:-}" ]]; then
    jq --arg name "$name" \
       --arg key "$key" \
       --arg url "$SODA_STRAW_URL/mcp" \
       --arg auth "Bearer $SODA_STRAW_API_KEY" \
       '.[$key] = (.[$key] // {}) | .[$key][$name] = {
          type: "http",
          url: $url,
          headers: { Authorization: $auth }
        }' "$file" > "$tmp" && mv "$tmp" "$file"
  else
    jq --arg name "$name" \
       --arg key "$key" \
       --arg url "$SODA_STRAW_URL/mcp" \
       '.[$key] = (.[$key] // {}) | .[$key][$name] = {
          type: "http",
          url: $url
        }' "$file" > "$tmp" && mv "$tmp" "$file"
  fi
  log "  wrote MCP config to $file"
}

setup_claude_code() {
  [[ -d "$HOME/.claude" ]] || return 1
  log "Claude Code detected"
  warn "  for Claude Code, prefer: /plugin marketplace add soda-straw/soda-straw-tools && /plugin install soda-straw@soda-straw-tools"
  link_skills "$HOME/.claude/skills"
  if have claude; then
    if [[ -n "${SODA_STRAW_API_KEY:-}" ]]; then
      claude mcp add soda-straw \
        --transport http \
        --scope user \
        --header "Authorization: Bearer $SODA_STRAW_API_KEY" \
        "$SODA_STRAW_URL/mcp" 2>/dev/null || warn "  claude mcp add failed (already configured?)"
    else
      claude mcp add soda-straw \
        --transport http \
        --scope user \
        "$SODA_STRAW_URL/mcp" 2>/dev/null || warn "  claude mcp add failed (already configured?)"
    fi
  fi
}

setup_codex() {
  [[ -d "$HOME/.codex" ]] || have codex || return 1
  log "Codex CLI detected"
  mkdir -p "$HOME/.codex"
  link_skills "$HOME/.codex/skills"
  write_mcp_http "$HOME/.codex/mcp_servers.json" "soda-straw" "mcpServers"
}

setup_cursor() {
  [[ -d "$HOME/.cursor" ]] || return 1
  log "Cursor detected"
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
  link_skills "$base/skills"
  write_mcp_http "$base/config.json" "soda-straw" "mcp"
}

# ---- main -------------------------------------------------------------------

have git || err "git is required"
have jq  || err "jq is required (brew install jq / apt install jq)"
have curl || err "curl is required"

ensure_repo
prompt_endpoint

installed_any=0
for fn in setup_claude_code setup_codex setup_cursor setup_windsurf setup_gemini setup_opencode; do
  if $fn; then installed_any=1; fi
done

if [[ "$installed_any" -eq 0 ]]; then
  warn "No supported AI tools detected. Supported: Claude Code, Codex CLI, Cursor, Windsurf, Gemini CLI, OpenCode."
  exit 1
fi

if [[ -n "${SODA_STRAW_API_KEY:-}" ]]; then
  log "Done. Restart your tools to pick up the new MCP server and skills."
else
  log "Done. Restart your tools to pick up the new MCP server and skills. On first use of a Soda Straw tool, your host will open a browser to authorize. If your host doesn't support MCP OAuth, mint an API key at $SODA_STRAW_URL/settings?tab=api-keys and rerun with SODA_STRAW_API_KEY=<key> bash install.sh"
fi
