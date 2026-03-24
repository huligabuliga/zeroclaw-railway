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

PROVIDER="${PROVIDER:-anthropic}"
MODEL="${ZEROCLAW_MODEL:-claude-sonnet-4-6}"
TEMPERATURE="${ZEROCLAW_TEMPERATURE:-0.7}"

if [ ! -f "$CONFIG_FILE" ]; then
  echo "Generating initial config..."

  cat > "$CONFIG_FILE" << TOML
default_provider = "${PROVIDER}"
default_model = "${MODEL}"
default_temperature = ${TEMPERATURE}
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

[autonomy]
level = "supervised"
workspace_only = true
allowed_commands = ["git","npm","cargo","ls","cat","grep","find","echo","pwd","wc","head","tail","date"]

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

MODE="${ZEROCLAW_MODE:-daemon}"
exec gosu "$ZEROCLAW_UID" zeroclaw "$MODE"
