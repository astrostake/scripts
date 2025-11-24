#!/bin/bash

#======================================================================================================================
# ASTROSTAKE - COSMOS UPGRADE BOT (v2.0 - WebSocket Hybrid Edition)
#
# FEATURES:
# - Hybrid Monitoring: Polling (for far distance) + WebSocket Streaming (near target).
# - Zero-latency Upgrade: Trigger execution exactly when the target block is reached via WebSocket event.
# - Optimized for Sub-Second Block Times (Lumera, Sei, 0G, etc.).
# - Rich Discord Notifications, Milestones, Health Checks, ETA Calculation.
#======================================================================================================================

#======================================================================================================================
# DEFAULT CONFIGURATION
#======================================================================================================================

NORMAL_SLEEP_INTERVAL=5          # polling interval (seconds) when far from the target block
FAST_CHECK_THRESHOLD=100         # when remaining blocks <= this, switch to WebSocket mode
BINARY_INSTALL_PATH="$HOME/go/bin"
API_URL="http://localhost:1317"
RPC_URL="http://localhost:26657"
DISCORD_WEBHOOK_URL=""
PROGRESS_UPDATE_INTERVAL=300     # progress report interval to Discord (seconds). 0 = disabled.

#======================================================================================================================
# PARSE ARGUMENTS
#======================================================================================================================

while [ $# -gt 0 ]; do
  case "$1" in
    -b|--binary-name)      DAEMON_NAME="$2"; shift 2 ;;
    -t|--target-block)     TARGET_BLOCK="$2"; shift 2 ;;
    -n|--new-binary-path)  NEW_BINARY_PATH="$2"; shift 2 ;;
    -p|--install-path)     BINARY_INSTALL_PATH="$2"; shift 2 ;;
    -r|--rpc-url)          RPC_URL="$2"; shift 2 ;;
    -a|--api-url)          API_URL="$2"; shift 2 ;;
    -i|--proposal-id)      PROPOSAL_ID="$2"; shift 2 ;;
    -d|--discord-webhook)  DISCORD_WEBHOOK_URL="$2"; shift 2 ;;
    --progress-interval)   PROGRESS_UPDATE_INTERVAL="$2"; shift 2 ;;
    --fast-threshold)      FAST_CHECK_THRESHOLD="$2"; shift 2 ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

if [ -z "$DAEMON_NAME" ] || [ -z "$TARGET_BLOCK" ] || [ -z "$NEW_BINARY_PATH" ]; then
  echo "🔥 ERROR: Missing required arguments."
  echo "Usage: $0 -b <binary_name> -t <target_block> -n <new_binary_path> [options]"
  echo "Example: $0 -b lumerad -t 425000 -n /root/lumerad-v2 -d <discord_webhook>"
  exit 1
fi

SERVICE_NAME="${DAEMON_NAME}.service"
SCRIPT_START_TIME=$(date +%s)
LAST_PROGRESS_UPDATE=0
AVG_BLOCK_TIME=1.0

# Convert RPC → WS URL (http → ws, https → wss)
if [[ "$RPC_URL" =~ ^https:// ]]; then
  WS_URL="${RPC_URL/https:/wss:}/websocket"
elif [[ "$RPC_URL" =~ ^http:// ]]; then
  WS_URL="${RPC_URL/http:/ws:}/websocket"
else
  # assume host:port only
  WS_URL="ws://$RPC_URL/websocket"
  RPC_URL="http://$RPC_URL"
fi

#======================================================================================================================
# COLORS
#======================================================================================================================

C_RESET='\033[0m'
C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[0;33m'
C_BLUE='\033[0;34m'
C_CYAN='\033[0;36m'
C_WHITE='\033[0;37m'

#======================================================================================================================
# UTILS & DISCORD
#======================================================================================================================

send_discord_notification() {
  if [ -z "$DISCORD_WEBHOOK_URL" ]; then return; fi

  local type="$1"
  local message="$2"
  local additional="$3"
  local hostname=$(hostname)
  local color title
  local ts=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")

  case "$type" in
    START)     color=3447003;  title="🔵 UPGRADE MONITOR STARTED (v2)" ;;
    FAST_MODE) color=15105570; title="⚡ FAST MODE (WebSocket) ENABLED" ;;
    UPGRADING) color=16776960; title="🟡 UPGRADE EXECUTING" ;;
    SUCCESS)   color=3066993;  title="🟢 UPGRADE COMPLETED" ;;
    FAILURE)   color=15158332; title="🔴 UPGRADE FAILED" ;;
    WARNING)   color=15844367; title="🟠 WARNING" ;;
    PROGRESS)  color=5793266;  title="📊 PROGRESS REPORT" ;;
    MILESTONE) color=9936031;  title="🎯 MILESTONE" ;;
    *)         color=5793266;  title="ℹ️ NOTIFICATION" ;;
  esac

  local payload
  case "$type" in
    START)
      local net_info
      net_info=$(get_network_info)
      payload=$(jq -n \
        --arg title "$title" \
        --arg desc "Cosmos upgrade monitor v2 started (Hybrid Polling + WebSocket)." \
        --arg daemon "$DAEMON_NAME" \
        --arg target "$TARGET_BLOCK" \
        --arg rpc "$RPC_URL" \
        --arg ws "$WS_URL" \
        --arg net "$net_info" \
        --arg ts "$ts" \
        --arg footer "Server: $hostname" \
        --argjson color "$color" \
        '{embeds:[{
          title:$title,
          description:$desc,
          color:$color,
          timestamp:$ts,
          footer:{text:$footer},
          fields:[
            {name:"🔧 Daemon",value:$daemon,inline:true},
            {name:"🎯 Target Block",value:$target,inline:true},
            {name:"🌐 RPC",value:$rpc,inline:false},
            {name:"🌐 WebSocket",value:$ws,inline:false},
            {name:"🧱 Network",value:$net,inline:false}
          ]
        }] }')
      ;;
    PROGRESS)
      local blocks_remaining="$additional"
      payload=$(jq -n \
        --arg title "$title" \
        --arg desc "$message" \
        --arg current "$latest_block" \
        --arg target "$TARGET_BLOCK" \
        --arg remain "$blocks_remaining" \
        --arg ts "$ts" \
        --arg footer "Server: $hostname" \
        --argjson color "$color" \
        '{embeds:[{
          title:$title,
          description:$desc,
          color:$color,
          timestamp:$ts,
          footer:{text:$footer},
          fields:[
            {name:"📊 Current Block",value:$current,inline:true},
            {name:"🎯 Target Block",value:$target,inline:true},
            {name:"⏳ Remaining Blocks",value:$remain,inline:true}
          ]
        }] }')
      ;;
    SUCCESS)
      local total_runtime=$(( $(date +%s) - SCRIPT_START_TIME ))
      local runtime_str
      runtime_str=$(format_eta "$total_runtime")
      payload=$(jq -n \
        --arg title "$title" \
        --arg desc "Upgrade sequence completed successfully." \
        --arg daemon "$DAEMON_NAME" \
        --arg target "$TARGET_BLOCK" \
        --arg block "${latest_block:-unknown}" \
        --arg runtime "$runtime_str" \
        --arg ts "$ts" \
        --arg footer "Server: $hostname" \
        --argjson color "$color" \
        '{embeds:[{
          title:$title,
          description:$desc,
          color:$color,
          timestamp:$ts,
          footer:{text:$footer},
          fields:[
            {name:"🔧 Daemon",value:$daemon,inline:true},
            {name:"🎯 Target Block",value:$target,inline:true},
            {name:"✅ Triggered At Block",value:$block,inline:true},
            {name:"⏱️ Runtime",value:$runtime,inline:true}
          ]
        }] }')
      ;;
    FAILURE|WARNING|FAST_MODE|UPGRADING|MILESTONE)
      payload=$(jq -n \
        --arg title "$title" \
        --arg desc "$message" \
        --arg extra "$additional" \
        --arg ts "$ts" \
        --arg footer "Server: $hostname" \
        --argjson color "$color" \
        '{embeds:[{
          title:$title,
          description:$desc,
          color:$color,
          timestamp:$ts,
          footer:{text:$footer},
          fields:(
            $extra|select(.!="")|
            [{name:"Details",value:$extra,inline:false}]
          )
        }] }')
      ;;
    *)
      payload=$(jq -n \
        --arg title "$title" \
        --arg desc "$message" \
        --arg ts "$ts" \
        --arg footer "Server: $hostname" \
        --argjson color "$color" \
        '{embeds:[{title:$title,description:$desc,color:$color,timestamp:$ts,footer:{text:$footer}}]}')
      ;;
  esac

  curl -s -H "Content-Type: application/json" -X POST -d "$payload" "$DISCORD_WEBHOOK_URL" >/dev/null 2>&1 || true
}

get_network_info() {
  local chain_id node_version
  chain_id=$(curl -s "${RPC_URL}/status" | jq -r .result.node_info.network 2>/dev/null)
  node_version=$(curl -s "${RPC_URL}/status" | jq -r .result.node_info.version 2>/dev/null)
  echo "Chain: ${chain_id:-Unknown}, Node: ${node_version:-Unknown}"
}

format_eta() {
  local total_seconds="$1"
  if [ "$total_seconds" -le 0 ]; then echo "Now"; return; fi
  local days=$((total_seconds / 86400))
  local hours=$(((total_seconds % 86400) / 3600))
  local minutes=$(((total_seconds % 3600) / 60))
  local seconds=$((total_seconds % 60))
  if   [ "$days" -gt 0 ];  then printf "%dd %02dh %02dm" $days $hours $minutes
  elif [ "$hours" -gt 0 ]; then printf "%02dh %02dm %02ds" $hours $minutes $seconds
  else                          printf "%02dm %02ds" $minutes $seconds
  fi
}

perform_health_check() {
  local service_status
  service_status=$(systemctl is-active "$SERVICE_NAME" 2>/dev/null || echo "unknown")
  if [[ "$service_status" != "active" ]]; then
    send_discord_notification "WARNING" "Service **$SERVICE_NAME** is not active (status: $service_status)" ""
    return 1
  fi
  return 0
}

check_milestones() {
  if [ "$PROGRESS_UPDATE_INTERVAL" -le 0 ]; then return; fi
  local current_block="$1"
  local target_block="$2"
  local progress_percent
  progress_percent=$(echo "scale=2; ($current_block * 100) / $target_block" | bc)
  local progress_int
  progress_int=$(echo "$progress_percent / 1" | bc)

  for milestone in 75 90 95 99; do
    if [[ $progress_int -eq $milestone ]] && [[ ! -f "/tmp/astrostake_milestone_${milestone}_sent" ]]; then
      local blocks_remaining=$((target_block - current_block))
      local eta_seconds
      eta_seconds=$(echo "($blocks_remaining * $AVG_BLOCK_TIME)" | bc | cut -d'.' -f1)
      local eta_str
      eta_str=$(format_eta "$eta_seconds")
      send_discord_notification "MILESTONE" "Reached **${milestone}%** of target block." "Remaining: ${blocks_remaining} blocks, ETA: ${eta_str}"
      touch "/tmp/astrostake_milestone_${milestone}_sent"
      break
    fi
  done
}

send_progress_update() {
  if [ "$PROGRESS_UPDATE_INTERVAL" -le 0 ]; then return; fi
  local now
  now=$(date +%s)
  if (( now - LAST_PROGRESS_UPDATE < PROGRESS_UPDATE_INTERVAL )); then
    return
  fi
  local blocks_remaining=$((TARGET_BLOCK - latest_block))
  local eta_seconds
  eta_seconds=$(echo "($blocks_remaining * $AVG_BLOCK_TIME)" | bc | cut -d'.' -f1)
  local eta_str
  eta_str=$(format_eta "$eta_seconds")
  send_discord_notification "PROGRESS" "Routine monitoring update." "$blocks_remaining"
  LAST_PROGRESS_UPDATE=$now
}

SCRIPT_STATUS="FAILURE"
FAILURE_REASON="Script exited unexpectedly. Check logs for details."

cleanup_temp_files() {
  rm -f /tmp/astrostake_milestone_*_sent 2>/dev/null || true
  rm -f /tmp/astrostake_upgrade_success 2>/dev/null || true
  rm -f /tmp/astrostake_ws_pipe_* 2>/dev/null || true
}

final_message() {
  echo
  echo -e "${C_WHITE}================================================================${C_RESET}"
  echo -e "${C_WHITE}                    OPERATION COMPLETED                         ${C_RESET}"
  echo -e "${C_WHITE}================================================================${C_RESET}"
  if [ "$SCRIPT_STATUS" == "SUCCESS" ]; then
    echo -e "🎉 ${C_GREEN}SUCCESS:${C_RESET} Upgrade completed."
    send_discord_notification "SUCCESS" "" ""
  else
    echo -e "🔴 ${C_RED}FAILURE:${C_RESET} $FAILURE_REASON"
    send_discord_notification "FAILURE" "$FAILURE_REASON" ""
  fi
  echo -e "${C_WHITE}================================================================${C_RESET}"
  cleanup_temp_files
}
trap final_message EXIT

#======================================================================================================================
# INITIAL VALIDATION
#======================================================================================================================

for cmd in jq bc curl websocat; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo -e "⚠️  ${C_RED}Missing required command:${C_RESET} $cmd"
    FAILURE_REASON="Missing required command: $cmd"
    exit 1
  fi
done

echo -e "🚀 ${C_GREEN}ASTROSTAKE UPGRADE BOT v2 (Hybrid WS)${C_RESET}"
echo -e "${C_WHITE}================================================================${C_RESET}"
echo -e "   ${C_WHITE}Daemon:              ${C_CYAN}$DAEMON_NAME${C_RESET}"
echo -e "   ${C_WHITE}Target Block:        ${C_CYAN}$TARGET_BLOCK${C_RESET}"
echo -e "   ${C_WHITE}RPC URL:             ${C_CYAN}$RPC_URL${C_RESET}"
echo -e "   ${C_WHITE}WebSocket URL:       ${C_CYAN}$WS_URL${C_RESET}"
echo -e "   ${C_WHITE}Fast Threshold:      ${C_CYAN}$FAST_CHECK_THRESHOLD blocks${C_RESET}"
if [ "$PROGRESS_UPDATE_INTERVAL" -le 0 ]; then
  echo -e "   ${C_WHITE}Progress Reporting:  ${C_YELLOW}Disabled${C_RESET}"
else
  echo -e "   ${C_WHITE}Progress Reporting:  ${C_GREEN}Every ${PROGRESS_UPDATE_INTERVAL}s${C_RESET}"
fi
echo -e "${C_WHITE}================================================================${C_RESET}"

# Current block
latest_block=$(curl -s --max-time 10 "${RPC_URL}/status" | jq -r .result.sync_info.latest_block_height 2>/dev/null)
if [[ ! "$latest_block" =~ ^[0-9]+$ ]]; then
  FAILURE_REASON="Cannot get latest block from RPC: $RPC_URL"
  echo -e "🔥 ${C_RED}$FAILURE_REASON${C_RESET}"
  exit 1
fi

# Binary check
if [ ! -f "$BINARY_INSTALL_PATH/$DAEMON_NAME" ]; then
  FAILURE_REASON="Current binary not found at $BINARY_INSTALL_PATH/$DAEMON_NAME"
  echo -e "🔥 ${C_RED}$FAILURE_REASON${C_RESET}"
  exit 1
fi
CURRENT_VERSION=$("$BINARY_INSTALL_PATH/$DAEMON_NAME" version 2>&1 || echo "unknown")
echo -e "   ✔️  ${C_WHITE}Current Version: ${C_GREEN}$CURRENT_VERSION${C_RESET}"

if [ ! -f "$NEW_BINARY_PATH" ]; then
  FAILURE_REASON="New binary not found at $NEW_BINARY_PATH"
  echo -e "🔥 ${C_RED}$FAILURE_REASON${C_RESET}"
  exit 1
fi
chmod +x "$NEW_BINARY_PATH"
NEW_VERSION=$("$NEW_BINARY_PATH" version 2>&1 || echo "unknown")
echo -e "   ✔️  ${C_WHITE}New Version:   ${C_GREEN}$NEW_VERSION${C_RESET}"

if [ "$CURRENT_VERSION" == "$NEW_VERSION" ]; then
  FAILURE_REASON="Current and new versions are identical ($CURRENT_VERSION). Nothing to upgrade."
  echo -e "⚠️  ${C_YELLOW}$FAILURE_REASON${C_RESET}"
  exit 1
fi

# Test WS connectivity (simple)
echo -e "🔍 ${C_YELLOW}Testing WebSocket connectivity...${C_RESET}"
if ! timeout 5 websocat -E "$WS_URL" <<< '' >/dev/null 2>&1; then
  FAILURE_REASON="Cannot connect to WebSocket at $WS_URL. Ensure RPC WebSocket is enabled."
  echo -e "🔥 ${C_RED}$FAILURE_REASON${C_RESET}"
  exit 1
fi
echo -e "   ✔️  ${C_GREEN}WebSocket reachable${C_RESET}"

# Estimate avg block time (1-time)
echo -e "⏱️  ${C_YELLOW}Estimating average block time...${C_RESET}"
start_block=$((latest_block - 100))
[ "$start_block" -lt 1 ] && start_block=1
start_time_str=$(curl -s "${RPC_URL}/block?height=${start_block}" | jq -r .result.block.header.time 2>/dev/null)
if [ -z "$start_time_str" ] || [ "$start_time_str" = "null" ]; then
  AVG_BLOCK_TIME=1.0
  echo -e "   ⚠️  Could not sample history, using default 1.0s"
else
  now_s=$(date +%s.%N)
  old_s=$(date -d "$start_time_str" +%s.%N 2>/dev/null)
  if [ -n "$old_s" ]; then
    diff=$(echo "$now_s - $old_s" | bc)
    AVG_BLOCK_TIME=$(echo "scale=4; $diff / ($latest_block - $start_block)" | bc)
  fi
  echo -e "   ✔️  ${C_GREEN}Estimated block time: ${AVG_BLOCK_TIME}s${C_RESET}"
fi

perform_health_check || true
send_discord_notification "START" "" ""

#======================================================================================================================
# WEBSOCKET FAST MODE
#======================================================================================================================

run_websocket_fast_mode() {
  local pipe="/tmp/astrostake_ws_pipe_$$"
  local sub='{"jsonrpc":"2.0","method":"subscribe","params":{"query":"tm.event='\''NewBlock'\''"},"id":1}'

  rm -f "$pipe"
  mkfifo "$pipe"

  echo -e "\n⚡ ${C_YELLOW}Entering WebSocket FAST MODE...${C_RESET}"
  send_discord_notification "FAST_MODE" "Entering WebSocket fast mode. Monitoring each new block in real-time." ""

  # Start websocat in background, output → named pipe
  {
    websocat -E -t "$WS_URL" <<< "$sub"
  } > "$pipe" 2>/dev/null &
  local ws_pid=$!

  while IFS= read -r line < "$pipe"; do
    local ws_height
    ws_height=$(echo "$line" | jq -r '.result.data.value.block.header.height' 2>/dev/null)
    if [[ "$ws_height" =~ ^[0-9]+$ ]]; then
      local rem=$((TARGET_BLOCK - ws_height))
      printf "\r${C_RED}⚡ WS MODE${C_RESET} | Block: ${C_GREEN}%d${C_RESET} | Target: ${C_CYAN}%d${C_RESET} | Rem: ${C_YELLOW}%d${C_RESET}   " \
        "$ws_height" "$TARGET_BLOCK" "$rem"

      if (( ws_height >= TARGET_BLOCK )); then
        echo -e "\n\n🚀 ${C_GREEN}TARGET BLOCK REACHED via WebSocket (${ws_height}) — starting upgrade...${C_RESET}"
        latest_block="$ws_height"
        echo "$ws_height" > /tmp/astrostake_upgrade_success
        kill "$ws_pid" 2>/dev/null || true
        break
      fi
    fi
  done

  rm -f "$pipe" 2>/dev/null || true

  if [ -f /tmp/astrostake_upgrade_success ]; then
    return 0
  else
    echo -e "\n⚠️  ${C_RED}WebSocket stream ended unexpectedly. Falling back to polling...${C_RESET}"
    return 1
  fi
}

#======================================================================================================================
# UPGRADE SEQUENCE
#======================================================================================================================

perform_upgrade() {
  send_discord_notification "UPGRADING" "Executing upgrade sequence at block ${latest_block}." ""

  echo -e "   🛑 ${C_YELLOW}Stopping service ${SERVICE_NAME}...${C_RESET}"
  if ! sudo systemctl stop "$SERVICE_NAME"; then
    FAILURE_REASON="Failed to stop service $SERVICE_NAME"
    return 1
  fi

  echo -e "   📦 ${C_YELLOW}Deploying new binary...${C_RESET}"
  if ! sudo cp "$NEW_BINARY_PATH" "$BINARY_INSTALL_PATH/$DAEMON_NAME"; then
    FAILURE_REASON="Failed to copy new binary to $BINARY_INSTALL_PATH/$DAEMON_NAME"
    sudo systemctl start "$SERVICE_NAME" || true
    return 1
  fi
  sudo chmod +x "$BINARY_INSTALL_PATH/$DAEMON_NAME"

  echo -e "   ▶️  ${C_YELLOW}Starting service...${C_RESET}"
  if ! sudo systemctl start "$SERVICE_NAME"; then
    FAILURE_REASON="Service failed to start with new binary. Manual intervention required."
    return 1
  fi

  sleep 5
  local ver
  ver=$("$BINARY_INSTALL_PATH/$DAEMON_NAME" version 2>&1 || echo "unknown")
  echo -e "   ✔️  ${C_WHITE}Post-upgrade version: ${C_GREEN}$ver${C_RESET}"
  SCRIPT_STATUS="SUCCESS"
  return 0
}

#======================================================================================================================
# MAIN LOOP
#======================================================================================================================

cleanup_temp_files
FAST_MODE_ENTERED=0

while true; do
  latest_block=$(curl -s --max-time 5 "${RPC_URL}/status" \
      | jq -r .result.sync_info.latest_block_height 2>/dev/null)

  if [[ ! "$latest_block" =~ ^[0-9]+$ ]]; then
    echo -e "\r⚠️  ${C_RED}Failed to get latest block, retrying...${C_RESET}   "
    sleep "$NORMAL_SLEEP_INTERVAL"
    continue
  fi

  blocks_remaining=$((TARGET_BLOCK - latest_block))

  if (( blocks_remaining <= 0 )); then
    echo -e "\n🚀 ${C_GREEN}TARGET BLOCK REACHED in polling mode (${latest_block}) — starting upgrade...${C_RESET}"
    if perform_upgrade; then exit 0; else exit 1; fi
  fi

  # Switch to FAST WS mode
  if (( blocks_remaining <= FAST_CHECK_THRESHOLD )) && [ "$FAST_MODE_ENTERED" -eq 0 ]; then
    FAST_MODE_ENTERED=1
    if run_websocket_fast_mode; then
      if perform_upgrade; then exit 0; else exit 1; fi
    fi
  fi

  eta_seconds=$(echo "($blocks_remaining * $AVG_BLOCK_TIME)" | bc | cut -d'.' -f1)
  eta_str=$(format_eta "$eta_seconds")

  prop_str=""
  if [ -n "$PROPOSAL_ID" ]; then
    status=$(curl -s --max-time 2 "$API_URL/cosmos/gov/v1/proposals/$PROPOSAL_ID" \
        | jq -r .proposal.status 2>/dev/null)
    status=${status#PROPOSAL_STATUS_}
    prop_str=" | Prop #$PROPOSAL_ID: ${status:-UNKNOWN}"
  fi

  printf "\r${C_BLUE}POLL MODE${C_RESET} | Block: ${C_GREEN}%d${C_RESET} | Rem: ${C_YELLOW}%d${C_RESET} | ETA: ${C_CYAN}%s${C_RESET}%s   " \
    "$latest_block" "$blocks_remaining" "$eta_str" "$prop_str"

  check_milestones "$latest_block" "$TARGET_BLOCK"
  send_progress_update
  perform_health_check || true

  sleep "$NORMAL_SLEEP_INTERVAL"
done
