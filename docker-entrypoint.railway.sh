#!/usr/bin/env bash
set -euo pipefail

ZEROCLAW_UID=65534
ZEROCLAW_GID=65534
DATA_DIR=/zeroclaw-data
CONFIG_DIR="$DATA_DIR/.zeroclaw"
WORKSPACE_DIR="$DATA_DIR/workspace"
CONFIG_FILE="$CONFIG_DIR/config.toml"

# Create directories
mkdir -p "$CONFIG_DIR" "$WORKSPACE_DIR"

echo "[entrypoint v6] CONFIG=$CONFIG_FILE TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN:+SET} PROVIDER=${PROVIDER:-unset}"

PROVIDER="${PROVIDER:-anthropic}"
MODEL="${ZEROCLAW_MODEL:-claude-sonnet-4-6}"
TEMPERATURE="${ZEROCLAW_TEMPERATURE:-0.7}"
# Resolve API key: prefer explicit key, fall back to OAuth token
API_KEY="${ANTHROPIC_API_KEY:-${ANTHROPIC_OAUTH_TOKEN:-}}"

if [ ! -f "$CONFIG_FILE" ]; then
  echo "Generating initial config..."

  cat > "$CONFIG_FILE" << TOML
default_provider = "${PROVIDER}"
default_model = "${MODEL}"
default_temperature = ${TEMPERATURE}
api_key = "${API_KEY}"
model_routes = []
embedding_routes = []

[gateway]
port = 8080
host = "0.0.0.0"
require_pairing = true
allow_public_bind = true
paired_tokens = []
pair_rate_limit_per_minute = 10
webhook_rate_limit_per_minute = 60
trust_forwarded_headers = false

[channels_config]
cli = true
message_timeout_secs = 300

[memory]
backend = "sqlite"
auto_save = true
hygiene_enabled = false
archive_after_days = 0
purge_after_days = 0
conversation_retention_days = 0
auto_hydrate = true

[autonomy]
level = "supervised"
workspace_only = true
allowed_commands = ["git","npm","cargo","ls","cat","grep","find","echo","pwd","wc","head","tail","date"]
auto_approve = ["memory_recall","memory_store","file_read","file_write","file_edit","web_search_tool","web_fetch","calculator","glob_search","content_search","weather"]

[secrets]
encrypt = true

[scheduler]
enabled = true
max_tasks = 64
max_concurrent = 4

[cron]
enabled = true

[heartbeat]
enabled = false
interval_minutes = 30

[hooks]
enabled = true
TOML

  # Append Telegram config if bot token is provided
  if [ -n "${TELEGRAM_BOT_TOKEN:-}" ]; then
    ALLOWED="${TELEGRAM_ALLOWED_USERS:-*}"
    # Build TOML array from comma-separated values
    USERS_ARRAY=$(echo "$ALLOWED" | awk -F',' '{
      result = ""
      for (i=1; i<=NF; i++) {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", $i)
        result = result (i>1 ? ", " : "") "\"" $i "\""
      }
      print result
    }')
    cat >> "$CONFIG_FILE" << TOML

[channels_config.telegram]
bot_token = "${TELEGRAM_BOT_TOKEN}"
allowed_users = [${USERS_ARRAY}]
stream_mode = "off"
interrupt_on_new_message = false
mention_only = false
TOML
    echo "Telegram channel configured."
  fi

else
  echo "Existing config found — preserving user settings."

  # Ensure gateway is bound to 0.0.0.0 for Railway networking
  sed -i '/^\[gateway\]/,/^\[/{s/^host = .*/host = "0.0.0.0"/}' "$CONFIG_FILE" || true
  sed -i '/^\[gateway\]/,/^\[/{s/^allow_public_bind = .*/allow_public_bind = true/}' "$CONFIG_FILE" || true

  # Patch memory settings for persistence (disable hygiene/purge)
  sed -i '/^\[memory\]/,/^\[/{s/^hygiene_enabled = .*/hygiene_enabled = false/}' "$CONFIG_FILE" || true
  grep -q "^hygiene_enabled" "$CONFIG_FILE" || sed -i '/^\[memory\]/a hygiene_enabled = false' "$CONFIG_FILE" || true
  sed -i '/^\[memory\]/,/^\[/{s/^archive_after_days = .*/archive_after_days = 0/}' "$CONFIG_FILE" || true
  sed -i '/^\[memory\]/,/^\[/{s/^purge_after_days = .*/purge_after_days = 0/}' "$CONFIG_FILE" || true

  # Patch autonomy auto_approve if missing
  grep -q "^auto_approve" "$CONFIG_FILE" || sed -i '/^\[autonomy\]/a auto_approve = ["memory_recall","memory_store","file_read","file_write","file_edit","web_search_tool","web_fetch","calculator","glob_search","content_search","weather"]' "$CONFIG_FILE" || true
fi

# Always sync api_key from env vars into config (so zeroclaw doctor shows green)
if [ -n "${API_KEY:-}" ]; then
  if grep -q "^api_key = " "$CONFIG_FILE"; then
    sed -i "s|^api_key = .*|api_key = \"${API_KEY}\"|" "$CONFIG_FILE"
  else
    sed -i "1s|^|api_key = \"${API_KEY}\"\n|" "$CONFIG_FILE"
  fi
fi

# Always rewrite Telegram section from env vars (handles stale/missing config on volume)
if [ -n "${TELEGRAM_BOT_TOKEN:-}" ]; then
  ALLOWED="${TELEGRAM_ALLOWED_USERS:-*}"
  USERS_ARRAY=$(echo "$ALLOWED" | awk -F',' '{
    result = ""
    for (i=1; i<=NF; i++) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $i)
      result = result (i>1 ? ", " : "") "\"" $i "\""
    }
    print result
  }')
  # Remove existing telegram section (if any) then re-add fresh
  awk 'BEGIN{skip=0} /^\[channels_config\.telegram\]/{skip=1;next} skip && /^\[/{skip=0} !skip{print}' \
    "$CONFIG_FILE" > /tmp/config_tmp && mv /tmp/config_tmp "$CONFIG_FILE"
  cat >> "$CONFIG_FILE" << TOML

[channels_config.telegram]
bot_token = "${TELEGRAM_BOT_TOKEN}"
allowed_users = [${USERS_ARRAY}]
stream_mode = "off"
interrupt_on_new_message = false
mention_only = false
TOML
  echo "Telegram channel configured from env vars."
fi

# Fix ownership before dropping privileges
chown -R "$ZEROCLAW_UID:$ZEROCLAW_GID" "$DATA_DIR"

echo "[entrypoint v6] Final telegram section in config:"
grep -A5 "\[channels_config.telegram\]" "$CONFIG_FILE" || echo "[entrypoint v6] NO telegram section found in config!"

MODE="${ZEROCLAW_MODE:-daemon}"
exec gosu "$ZEROCLAW_UID" zeroclaw "$MODE"
