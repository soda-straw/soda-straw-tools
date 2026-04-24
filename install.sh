#!/usr/bin/env bash
# Soda Straw tools - cross-tool installer
#
# Detects installed AI agent tools, wires up the Soda Straw MCP
# connection, and links in the Soda Straw skills bundle. Uses the
# OAuth 2.1 device authorization flow - the user authorizes in
# their browser, no token paste.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/sodadata/soda-straw-tools/main/install.sh | bash
#   SODA_STRAW_URL=https://my-instance.sodastraw.ai bash install.sh
#
# For Claude Code, prefer:
#   /plugin marketplace add sodadata/soda-straw-tools
#   /plugin install soda-straw@soda-straw-tools
# The plugin flow lets Claude Code drive OAuth directly via its
# native /mcp authorization flow and stores tokens in the system
# keychain automatically.

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

# ---- prompt for endpoint ----------------------------------------------------

prompt_endpoint() {
  if [[ -z "${SODA_STRAW_URL:-}" ]]; then
    read -r -p "Soda Straw endpoint [https://app.sodastraw.ai]: " SODA_STRAW_URL
    SODA_STRAW_URL="${SODA_STRAW_URL:-https://app.sodastraw.ai}"
  fi
  SODA_STRAW_URL="${SODA_STRAW_URL%/}"
}

# ---- OAuth device authorization flow ---------------------------------------

# Ensures we have a client_id for this host; registers one via DCR the
# first time. Caches in ~/.soda-straw-tools/client.json.
ensure_client_id() {
  local cache="$INSTALL_DIR/client.json"
  if [[ -f "$cache" ]]; then
    CLIENT_ID="$(jq -r '.client_id' "$cache")"
    if [[ -n "$CLIENT_ID" && "$CLIENT_ID" != "null" ]]; then return; fi
  fi
  log "Registering this host with Soda Straw (one-time)"
  local body
  body=$(
    jq -n \
      --arg name "Soda Straw installer ($(hostname))" \
      '{
        client_name: $name,
        redirect_uris: ["http://localhost:0/callback"],
        grant_types: ["urn:ietf:params:oauth:grant-type:device_code", "refresh_token"],
        response_types: ["code"],
        token_endpoint_auth_method: "none"
      }'
  )
  local resp
  resp=$(curl -fsS -X POST -H 'Content-Type: application/json' \
    --data "$body" "$SODA_STRAW_URL/api/oauth/register") \
    || err "DCR request failed against $SODA_STRAW_URL"
  CLIENT_ID="$(printf '%s' "$resp" | jq -r .client_id)"
  printf '%s' "$resp" > "$cache"
  chmod 600 "$cache"
}

# Begin the device flow; print the user code + URL, then poll until
# the user approves (or interval elapses / timeout).
run_device_flow() {
  ensure_client_id
  local hostname
  hostname="$(hostname)"
  local begin
  begin=$(curl -fsS -X POST \
    --data-urlencode "client_id=$CLIENT_ID" \
    --data-urlencode "scope=mcp" \
    --data-urlencode "device_metadata={\"hostname\":\"$hostname\"}" \
    "$SODA_STRAW_URL/api/oauth/device_authorization") \
    || err "device_authorization request failed"

  local device_code user_code verification_uri_complete interval expires_in
  device_code="$(printf '%s' "$begin" | jq -r .device_code)"
  user_code="$(printf '%s' "$begin" | jq -r .user_code)"
  verification_uri_complete="$(printf '%s' "$begin" | jq -r .verification_uri_complete)"
  interval="$(printf '%s' "$begin" | jq -r .interval)"
  expires_in="$(printf '%s' "$begin" | jq -r .expires_in)"

  printf '\n\033[1mAuthorize this installation:\033[0m\n'
  printf '  Open:   %s\n' "$verification_uri_complete"
  printf '  Code:   %s\n\n' "$user_code"
  printf 'Waiting for approval'

  local deadline=$((SECONDS + expires_in))
  while [[ $SECONDS -lt $deadline ]]; do
    sleep "$interval"
    printf '.'
    local poll
    if poll=$(curl -fsS -X POST \
      --data-urlencode "grant_type=urn:ietf:params:oauth:grant-type:device_code" \
      --data-urlencode "device_code=$device_code" \
      --data-urlencode "client_id=$CLIENT_ID" \
      "$SODA_STRAW_URL/api/oauth/token" 2>/dev/null); then
      printf '\n'
      SODA_STRAW_ACCESS_TOKEN="$(printf '%s' "$poll" | jq -r .access_token)"
      SODA_STRAW_REFRESH_TOKEN="$(printf '%s' "$poll" | jq -r .refresh_token)"
      log "Authorization granted"
      return
    fi
    # Non-2xx: inspect error; slow_down/authorization_pending are expected.
    local err_body
    err_body=$(curl -sS -X POST \
      --data-urlencode "grant_type=urn:ietf:params:oauth:grant-type:device_code" \
      --data-urlencode "device_code=$device_code" \
      --data-urlencode "client_id=$CLIENT_ID" \
      "$SODA_STRAW_URL/api/oauth/token")
    local err_code
    err_code="$(printf '%s' "$err_body" | jq -r '.detail.error // .error // ""')"
    case "$err_code" in
      authorization_pending|slow_down) ;;
      access_denied)
        printf '\n'
        err "User denied authorization"
        ;;
      expired_token)
        printf '\n'
        err "Device code expired - rerun the installer"
        ;;
      *)
        printf '\n'
        err "Unexpected OAuth error: $err_code"
        ;;
    esac
  done
  printf '\n'
  err "Timed out waiting for authorization"
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

write_mcp_http() {
  local file="$1" name="$2" key="$3"
  local tmp
  tmp="$(mktemp)"
  [[ -f "$file" ]] || echo '{}' > "$file"
  jq --arg name "$name" \
     --arg key "$key" \
     --arg url "$SODA_STRAW_URL/mcp" \
     --arg auth "Bearer $SODA_STRAW_ACCESS_TOKEN" \
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
  if have claude; then
    claude mcp add soda-straw \
      --transport http \
      --scope user \
      --header "Authorization: Bearer $SODA_STRAW_ACCESS_TOKEN" \
      "$SODA_STRAW_URL/mcp" 2>/dev/null || warn "  claude mcp add failed (already configured?)"
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
run_device_flow

installed_any=0
for fn in setup_claude_code setup_codex setup_cursor setup_windsurf setup_gemini setup_opencode; do
  if $fn; then installed_any=1; fi
done

if [[ "$installed_any" -eq 0 ]]; then
  warn "No supported AI tools detected."
  warn "Supported: Claude Code, Codex CLI, Cursor, Windsurf, Gemini CLI, OpenCode."
  exit 1
fi

# Cache the refresh token so subsequent reruns can silently rotate.
printf '%s\n' "$SODA_STRAW_REFRESH_TOKEN" > "$INSTALL_DIR/refresh_token"
chmod 600 "$INSTALL_DIR/refresh_token"

log "Done. Restart your tools to pick up the new MCP server and skills."
