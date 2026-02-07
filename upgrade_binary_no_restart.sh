#!/bin/bash

#======================================================================================================================
# ASTROSTAKE - COSMOS UPGRADE BOT (v1.5 - Flexible Progress)
#
# FEATURES:
# - Automated binary swap at a target block height.
# - Rich embed notifications for Discord with detailed monitoring information.
# - Dynamic ETA calculation based on average block time.
# - Fast mode for more frequent checks when approaching the target block.
# - Proposal status monitoring to halt on failure.
# - Enhanced logging and error handling with upgrade step validation.
# - Progress tracking with periodic updates (can be disabled).
#======================================================================================================================

#======================================================================================================================
# PARSE COMMAND-LINE ARGUMENTS
#======================================================================================================================

# Set default values
NORMAL_SLEEP_INTERVAL=30
FAST_SLEEP_INTERVAL=3
FAST_CHECK_THRESHOLD=50
BINARY_INSTALL_PATH="$HOME/go/bin"
API_URL="http://localhost:1317"
RPC_URL="http://localhost:26657"
DISCORD_WEBHOOK_URL=""
PROGRESS_UPDATE_INTERVAL=300  # Default: Send progress updates every 5 minutes. Set to 0 to disable.

# Loop through arguments and process them
while [ $# -gt 0 ]; do
    case "$1" in
        -b|--binary-name) DAEMON_NAME="$2"; shift 2 ;;
        -t|--target-block) TARGET_BLOCK="$2"; shift 2 ;;
        -n|--new-binary-path) NEW_BINARY_PATH="$2"; shift 2 ;;
        -p|--install-path) BINARY_INSTALL_PATH="$2"; shift 2 ;;
        -r|--rpc-url) RPC_URL="$2"; shift 2 ;;
        -i|--proposal-id) PROPOSAL_ID="$2"; shift 2 ;;
        -a|--api-url) API_URL="$2"; shift 2 ;;
        -d|--discord-webhook) DISCORD_WEBHOOK_URL="$2"; shift 2 ;;
        --progress-interval) PROGRESS_UPDATE_INTERVAL="$2"; shift 2 ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done

# --- Validate required arguments ---
if [ -z "$DAEMON_NAME" ] || [ -z "$TARGET_BLOCK" ] || [ -z "$NEW_BINARY_PATH" ]; then
    echo "🔥 ERROR: Missing required arguments."
    echo "Usage: $0 -b <binary_name> -t <target_block> -n <new_binary_path> [options]"
    echo "Example: ./upgrade_bot.sh -b lumerad -t 425000 -n /root/lumerad-v2 --progress-interval 0"
    exit 1
fi

# --- Derive dependent variables ---
SERVICE_NAME="${DAEMON_NAME}.service"
SCRIPT_START_TIME=$(date +%s)
LAST_PROGRESS_UPDATE=0

#======================================================================================================================
# SCRIPT CONSTANTS AND FUNCTIONS
#======================================================================================================================

# --- Color Codes for terminal output ---
C_RESET='\033[0m';C_RED='\033[0;31m';C_GREEN='\033[0;32m';C_YELLOW='\033[0;33m';C_BLUE='\033[0;34m';C_CYAN='\033[0;36m';C_WHITE='\033[0;37m'

# --- Enhanced Discord notification function ---
function send_discord_notification() {
    if [ -z "$DISCORD_WEBHOOK_URL" ]; then return; fi
    
    local type="$1"
    local message="$2"
    local additional_data="$3"
    local hostname=$(hostname)
    local json_payload
    local color title
    local current_time=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")

    case "$type" in
        "SUCCESS")   color=3066993;  title="🟢 UPGRADE COMPLETED" ;;
        "FAILURE")   color=15158332; title="🔴 UPGRADE FAILED" ;;
        "START")     color=3447003;  title="🔵 MONITORING INITIATED" ;;
        "FAST_MODE") color=15105570; title="🟠 FAST MODE ACTIVATED" ;;
        "UPGRADING") color=16776960; title="🟡 UPGRADE IN PROGRESS" ;;
        "WARNING")   color=15844367; title="🟠 SYSTEM WARNING" ;;
        "PROGRESS")  color=5793266;  title="📊 PROGRESS REPORT" ;;
        "MILESTONE") color=9936031;  title="🎯 MILESTONE ACHIEVED" ;;
        *)           color=5793266;  title="ℹ️ SYSTEM NOTIFICATION" ;;
    esac

    case "$type" in
        "START")
            local network_info=$(get_network_info)
            local description_text="Cosmos blockchain upgrade monitoring system has been successfully initialized and is now actively monitoring block progression."
            json_payload=$(jq -n \
                --arg title "$title" --arg description "$description_text" --arg daemon "$DAEMON_NAME" \
                --arg current_version "$CURRENT_VERSION" --arg new_version "$NEW_VERSION" \
                --arg target_block "$TARGET_BLOCK" --arg current_block "$latest_block" \
                --arg prop_id "${PROPOSAL_ID:-N/A}" --arg network_info "$network_info" \
                --argjson color "$color" --arg timestamp "$current_time" \
                --arg footer_text "Server: $hostname | Status: Monitoring Active" \
                '{embeds: [{ "title": $title, "description": $description, "color": $color, "timestamp": $timestamp, "footer": {"text": $footer_text}, "fields": [{"name": "🔧 Service Name", "value": $daemon, "inline": true}, {"name": "🎯 Target Block Height", "value": $target_block, "inline": true}, {"name": "📊 Current Block Height", "value": $current_block, "inline": true}, {"name": "📦 Current Version", "value": $current_version, "inline": true}, {"name": "🆕 Target Version", "value": $new_version, "inline": true}, {"name": "🗳️ Governance Proposal", "value": $prop_id, "inline": true}, {"name": "🌐 Network Information", "value": $network_info, "inline": false}] }]}'
            ) ;;
        "PROGRESS")
            local blocks_remaining=$((TARGET_BLOCK - latest_block))
            local progress_percent=$(echo "scale=1; ($latest_block * 100) / $TARGET_BLOCK" | bc)
            local runtime=$(($(date +%s) - SCRIPT_START_TIME))
            local runtime_formatted=$(format_eta $runtime)
            local description_text="Automated monitoring system continues to track blockchain progression towards the designated upgrade block height."
            local progress_display="${progress_percent}%"
            local block_time_display="${avg_block_time}s"
            json_payload=$(jq -n \
                --arg title "$title" --arg description "$description_text" --arg daemon "$DAEMON_NAME" \
                --arg current_block "$latest_block" --arg target_block "$TARGET_BLOCK" --arg blocks_remaining "$blocks_remaining" \
                --arg progress_display "$progress_display" --arg eta_formatted "$additional_data" --arg block_time_display "$block_time_display" \
                --arg runtime "$runtime_formatted" --argjson color "$color" --arg timestamp "$current_time" \
                --arg footer_text "Server: $hostname | Uptime: $runtime_formatted" \
                '{embeds: [{ "title": $title, "description": $description, "color": $color, "timestamp": $timestamp, "footer": {"text": $footer_text}, "fields": [{"name": "📊 Current Block Height", "value": $current_block, "inline": true}, {"name": "🎯 Target Block Height", "value": $target_block, "inline": true}, {"name": "⏳ Remaining Blocks", "value": $blocks_remaining, "inline": true}, {"name": "📈 Completion Progress", "value": $progress_display, "inline": true}, {"name": "⏱️ Average Block Time", "value": $block_time_display, "inline": true}, {"name": "🕐 Estimated Time to Completion", "value": $eta_formatted, "inline": true}] }]}'
            ) ;;
        "SUCCESS")
            local total_runtime=$(($(date +%s) - SCRIPT_START_TIME))
            local runtime_formatted=$(format_eta $total_runtime)
            # Ubah deskripsi agar memberitahu bahwa service STOPPED
            local description_text="The blockchain node binary has been swapped successfully. **The service is currently STOPPED** as requested for manual verification."
            local version_upgrade="${CURRENT_VERSION} → ${NEW_VERSION}"
            json_payload=$(jq -n \
                --arg title "🟢 BINARY SWAPPED (STOPPED)" --arg description "$description_text" --arg daemon "$DAEMON_NAME" \
                --arg version_upgrade "$version_upgrade" --arg target_block "$TARGET_BLOCK" \
                --arg actual_block "$latest_block" --arg runtime "$runtime_formatted" \
                --argjson color "$color" --arg timestamp "$current_time" \
                --arg footer_text "Server: $hostname | Status: Manual Intervention Required" \
                '{embeds: [{ "title": $title, "description": $description, "color": $color, "timestamp": $timestamp, "footer": {"text": $footer_text}, "fields": [{"name": "📦 Version Upgrade", "value": $version_upgrade, "inline": false}, {"name": "🎯 Target Block Height", "value": $target_block, "inline": true}, {"name": "✅ Swap Block", "value": $actual_block, "inline": true}, {"name": "⏱️ Total Operation Time", "value": $runtime, "inline": true}] }]}'
            ) ;;
        "FAILURE")
            local total_runtime=$(($(date +%s) - SCRIPT_START_TIME))
            local runtime_formatted=$(format_eta $total_runtime)
            local description_text="The blockchain node upgrade process has encountered a critical error and requires immediate attention."
            json_payload=$(jq -n \
                --arg title "$title" --arg description "$description_text" --arg daemon "$DAEMON_NAME" \
                --arg error_msg "$message" --arg current_block "${latest_block:-Unknown}" \
                --arg target_block "$TARGET_BLOCK" --arg runtime "$runtime_formatted" \
                --argjson color "$color" --arg timestamp "$current_time" \
                --arg footer_text "Server: $hostname | Status: Requires Attention" \
                '{embeds: [{ "title": $title, "description": $description, "color": $color, "timestamp": $timestamp, "footer": {"text": $footer_text}, "fields": [{"name": "🔥 Error Details", "value": $error_msg, "inline": false}, {"name": "📊 Current Block Height", "value": $current_block, "inline": true}, {"name": "🎯 Target Block Height", "value": $target_block, "inline": true}, {"name": "⏱️ Operation Runtime", "value": $runtime, "inline": true}] }]}'
            ) ;;
        *)
            json_payload=$(jq -n \
                --arg title "$title" --arg description "$message" --argjson color "$color" \
                --arg timestamp "$current_time" --arg footer_text "Server: $hostname | System Notification" \
                '{embeds: [{ "title": $title, "description": $description, "color": $color, "timestamp": $timestamp, "footer": {"text": $footer_text} }]}'
            ) ;;
    esac
    curl -s -w "\n%{http_code}" -H "Content-Type: application/json" -X POST -d "$json_payload" "$DISCORD_WEBHOOK_URL" &>/dev/null
}

function get_network_info() {
    local chain_id=$(curl -s "${RPC_URL}/status" | jq -r .result.node_info.network 2>/dev/null)
    local node_version=$(curl -s "${RPC_URL}/status" | jq -r .result.node_info.version 2>/dev/null)
    echo "Chain: ${chain_id:-Unknown} | Node: ${node_version:-Unknown}"
}

function check_milestones() {
    if [ "$PROGRESS_UPDATE_INTERVAL" -le 0 ]; then return; fi # Do not send milestones if progress is off
    local current_block="$1"
    local target_block="$2"
    local progress_percent=$(echo "scale=2; ($current_block * 100) / $target_block" | bc)
    local progress_int=$(echo "$progress_percent / 1" | bc)
    for milestone in 75 90 95 99; do
        if [[ $progress_int -eq $milestone ]] && [[ ! -f "/tmp/milestone_${milestone}_sent" ]]; then
            local blocks_remaining=$((target_block - current_block))
            local eta_seconds=$(echo "($blocks_remaining * $avg_block_time) / 1" | bc)
            local eta_formatted=$(format_eta $eta_seconds)
            send_discord_notification "MILESTONE" "🎯 **${milestone}%** progress reached!" "Blocks remaining: **${blocks_remaining}** | ETA: **${eta_formatted}**"
            touch "/tmp/milestone_${milestone}_sent"
            break
        fi
    done
}

function send_progress_update() {
    # NEW: Check if progress updates are disabled
    if [ "$PROGRESS_UPDATE_INTERVAL" -le 0 ]; then
        return
    fi
    local current_time=$(date +%s)
    if (( current_time - LAST_PROGRESS_UPDATE >= PROGRESS_UPDATE_INTERVAL )); then
        local eta_seconds=$(echo "(($TARGET_BLOCK - $latest_block) * $avg_block_time) / 1" | bc)
        local eta_formatted=$(format_eta $eta_seconds)
        send_discord_notification "PROGRESS" "Regular monitoring update" "$eta_formatted"
        LAST_PROGRESS_UPDATE=$current_time
    fi
}

function perform_health_check() {
    local service_status=$(systemctl is-active "$SERVICE_NAME" 2>/dev/null)
    if [[ "$service_status" != "active" ]]; then
        send_discord_notification "WARNING" "⚠️ Service **$SERVICE_NAME** is not active (Status: $service_status)"
        return 1
    fi
    local sync_status=$(curl -s "${RPC_URL}/status" | jq -r .result.sync_info.catching_up 2>/dev/null)
    if [[ "$sync_status" == "true" ]]; then
        send_discord_notification "WARNING" "⚠️ Node is currently catching up (not fully synced)"
    fi
    return 0
}

SCRIPT_STATUS="FAILURE"
FAILURE_REASON="Script exited for an unknown reason. Please check node logs."
function final_message() {
    echo ""
    echo -e "${C_WHITE}================================================================${C_RESET}"
    echo -e "${C_WHITE}                    OPERATION COMPLETED                         ${C_RESET}"
    echo -e "${C_WHITE}================================================================${C_RESET}"
    if [ "$SCRIPT_STATUS" == "SUCCESS" ]; then
        echo -e "🎉 ${C_GREEN}SUCCESS: Binary swap completed successfully.${C_RESET}"
        echo -e "   ${C_WHITE}• New binary has been deployed${C_RESET}"
        echo -e "   ${C_YELLOW}• Service remains STOPPED for manual start${C_RESET}"
        send_discord_notification "SUCCESS"
    else
        echo -e "🔴 ${C_RED}FAILURE: Critical error encountered during upgrade process.${C_RESET}"
        echo -e "   ${C_WHITE}• Immediate attention required${C_RESET}"
        echo -e "   ${C_WHITE}• Check system logs for detailed error information${C_RESET}"
        send_discord_notification "FAILURE" "$FAILURE_REASON"
    fi
    echo -e "${C_WHITE}================================================================${C_RESET}"
    rm -f /tmp/milestone_*_sent 2>/dev/null
}
trap final_message EXIT

for cmd in jq bc curl; do
  if ! command -v $cmd &> /dev/null; then 
    echo -e "⚠️ ${C_RED}Command '$cmd' not found. Please install it first.${C_RESET}"
    FAILURE_REASON="Missing required command: \`$cmd\`. Please install it and try again."
    exit 1
  fi
done

format_eta() {
  local total_seconds="$1"
  if [ "$total_seconds" -le 0 ]; then echo "Now"; return; fi
  local days=$((total_seconds / 86400))
  local hours=$(((total_seconds % 86400) / 3600))
  local minutes=$(((total_seconds % 3600) / 60))
  local seconds=$((total_seconds % 60))
  if [ "$days" -gt 0 ]; then
    printf "%dd %02dh %02dm" $days $hours $minutes
  elif [ "$hours" -gt 0 ]; then
    printf "%02dh %02dm %02ds" $hours $minutes $seconds
  else
    printf "%02dm %02ds" $minutes $seconds
  fi
}

# --- Script Start ---
rm -f /tmp/milestone_*_sent 2>/dev/null
echo -e "🚀 ${C_GREEN}ASTROSTAKE COSMOS UPGRADE AUTOMATION SYSTEM${C_RESET}"
echo -e "${C_WHITE}================================================================${C_RESET}"
echo -e "   ${C_WHITE}Service Name:         ${C_CYAN}$DAEMON_NAME${C_RESET}"
echo -e "   ${C_WHITE}Target Block Height:  ${C_CYAN}$TARGET_BLOCK${C_RESET}"
if [ "$PROGRESS_UPDATE_INTERVAL" -le 0 ]; then
    echo -e "   ${C_WHITE}Progress Reporting:   ${C_YELLOW}Disabled${C_RESET}"
else
    echo -e "   ${C_WHITE}Progress Reporting:   ${C_GREEN}Enabled (Every ${PROGRESS_UPDATE_INTERVAL}s)${C_RESET}"
fi
# ... (rest of startup info)
echo -e "${C_WHITE}================================================================${C_RESET}"

echo -e "🔍 ${C_YELLOW}SYSTEM INITIALIZATION & VALIDATION${C_RESET}"
latest_block=$(curl -s --max-time 10 "${RPC_URL}/status" | jq -r .result.sync_info.latest_block_height 2>/dev/null)
if [[ ! "$latest_block" =~ ^[0-9]+$ ]]; then
    echo -e "🔥 ${C_RED}ERROR: Cannot connect to RPC endpoint or get block height${C_RESET}"
    FAILURE_REASON="Cannot connect to RPC endpoint \`$RPC_URL\` or retrieve current block height."
    exit 1
fi
if [ ! -f "$BINARY_INSTALL_PATH/$DAEMON_NAME" ]; then
    echo -e "🔥 ${C_RED}ERROR: Current binary not found at $BINARY_INSTALL_PATH/$DAEMON_NAME${C_RESET}"
    FAILURE_REASON="Current binary not found at \`$BINARY_INSTALL_PATH/$DAEMON_NAME\`."
    exit 1
fi
CURRENT_VERSION=$($BINARY_INSTALL_PATH/$DAEMON_NAME version 2>&1)
echo -e "   ✔️  ${C_WHITE}Current Version: ${C_GREEN}$CURRENT_VERSION${C_RESET}"
if [ ! -f "$NEW_BINARY_PATH" ]; then
    echo -e "🔥 ${C_RED}ERROR: New binary not found at $NEW_BINARY_PATH${C_RESET}"
    FAILURE_REASON="New binary not found at \`$NEW_BINARY_PATH\`."
    exit 1
fi
chmod +x "$NEW_BINARY_PATH"
NEW_VERSION=$($NEW_BINARY_PATH version 2>&1)
echo -e "   ✔️  ${C_WHITE}New Version:     ${C_GREEN}$NEW_VERSION${C_RESET}"
if [ "$CURRENT_VERSION" == "$NEW_VERSION" ]; then
    echo -e "⚠️ ${C_YELLOW}WARNING: Versions are identical.${C_RESET}"
    send_discord_notification "WARNING" "The current and new binary versions are identical (**$CURRENT_VERSION**). Nothing to upgrade."
    exit 1
fi
perform_health_check
echo -e "   ${C_GREEN}✓ All system validations passed. Initiating blockchain monitoring...${C_RESET}"
echo -e "${C_WHITE}================================================================${C_RESET}"
send_discord_notification "START"

# --- Main Loop ---
avg_block_time=6.0; last_update_time=0; UPDATE_INTERVAL=60; proposal_status_str=""; FAST_MODE_NOTIFIED=0; HEALTH_CHECK_COUNTER=0
while true; do
    latest_block=$(curl -s --max-time 10 "${RPC_URL}/status" | jq -r .result.sync_info.latest_block_height 2>/dev/null)
    if [[ ! "$latest_block" =~ ^[0-9]+$ || "$latest_block" -lt 1 ]]; then
        echo -e "\n❌ ${C_RED}Failed to get valid block height. Retrying...${C_RESET}"
        send_discord_notification "WARNING" "Failed to retrieve block height from RPC endpoint. Retrying..."
        sleep $NORMAL_SLEEP_INTERVAL
        continue
    fi

    if [ "$latest_block" -ge "$TARGET_BLOCK" ]; then
        echo -e "\n🚀 ${C_GREEN}TARGET BLOCK REACHED - INITIATING UPGRADE SEQUENCE${C_RESET}"
        send_discord_notification "UPGRADING" "Target block height **$TARGET_BLOCK** has been reached at current block **$latest_block**. Initiating automated upgrade sequence."
        
        echo -e "   🔄 ${C_YELLOW}Phase 1: Stopping blockchain service...${C_RESET}"
        sudo systemctl stop "$SERVICE_NAME"
        if [ $? -ne 0 ]; then
            FAILURE_REASON="Failed to stop the '$SERVICE_NAME' service. Please check system logs."
            exit 1
        fi

        echo -e "   📦 ${C_YELLOW}Phase 2: Deploying new binary version...${C_RESET}"
        sudo cp "$NEW_BINARY_PATH" "$BINARY_INSTALL_PATH/$DAEMON_NAME"
        if [ $? -ne 0 ]; then
            FAILURE_REASON="Failed to copy the new binary. Check permissions and disk space. Attempting to restart original service."
            # sudo systemctl start "$SERVICE_NAME"
            exit 1
        fi
        sudo chmod +x "$BINARY_INSTALL_PATH/$DAEMON_NAME"

        echo -e "   🔄 ${C_YELLOW}Phase 3: Skipping automatic restart (Manual Mode)...${C_RESET}"
        # sudo systemctl start "$SERVICE_NAME"
        if [ $? -ne 0 ]; then
            FAILURE_REASON="**CRITICAL:** Service failed to start with the new binary. The node is DOWN and requires immediate manual intervention."
            exit 1
        fi

        sleep 5
        actual_version=$($BINARY_INSTALL_PATH/$DAEMON_NAME version 2>&1)
        echo -e "   ✅ ${C_WHITE}Post-upgrade version verification: ${C_GREEN}$actual_version${C_RESET}"
        
        SCRIPT_STATUS="SUCCESS"
        break
    fi

    blocks_remaining=$((TARGET_BLOCK - latest_block))
    current_time=$(date +%s)
    if (( current_time - last_update_time > UPDATE_INTERVAL )); then
        if [ -n "$PROPOSAL_ID" ]; then
            prop_data=$(curl -s --max-time 10 "$API_URL/cosmos/gov/v1/proposals/$PROPOSAL_ID" 2>/dev/null)
            current_prop_status=$(echo "$prop_data" | jq -r .proposal.status 2>/dev/null)
            case "$current_prop_status" in
                "PROPOSAL_STATUS_REJECTED"|"PROPOSAL_STATUS_FAILED")
                    local err_msg="Proposal #$PROPOSAL_ID has **failed** with status: $current_prop_status."
                    echo -e "\n🔥 ${C_RED}ERROR: $err_msg${C_RESET}"
                    FAILURE_REASON="$err_msg"
                    exit 1
                    ;;
                "PROPOSAL_STATUS_PASSED") 
                    proposal_status_str="──[ 🗳️  Prop #${PROPOSAL_ID}: ${C_GREEN}Passed${C_WHITE} ]" 
                    ;;
                "PROPOSAL_STATUS_VOTING_PERIOD") 
                    proposal_status_str="──[ 🗳️  Prop #${PROPOSAL_ID}: ${C_CYAN}Voting${C_WHITE} ]" 
                    ;;
                *) 
                    proposal_status_str="──[ 🗳️  Prop #${PROPOSAL_ID}: ${C_YELLOW}Unknown${C_WHITE} ]" 
                    ;;
            esac
        fi

        block_curr_time_str=$(curl -s --max-time 10 "${RPC_URL}/block?height=${latest_block}" 2>/dev/null | jq -r .result.block.header.time)
        time_curr=$(date -d "$block_curr_time_str" +%s.%N 2>/dev/null)
        if [[ -n "$time_curr" ]]; then
            prev_block_height=$((latest_block - 10))
            [ "$prev_block_height" -lt 1 ] && prev_block_height=1
            block_prev_time_str=$(curl -s --max-time 10 "${RPC_URL}/block?height=${prev_block_height}" 2>/dev/null | jq -r .result.block.header.time)
            time_prev=$(date -d "$block_prev_time_str" +%s.%N 2>/dev/null)
            if [[ -n "$time_prev" && "$latest_block" -gt "$prev_block_height" ]]; then
                time_diff=$(echo "$time_curr - $time_prev" | bc)
                block_diff=$((latest_block - prev_block_height))
                new_avg_block_time=$(echo "scale=2; $time_diff / $block_diff" | bc)
                if (( $(echo "$new_avg_block_time > 0" | bc -l) )); then avg_block_time=$new_avg_block_time; fi
            fi
        fi
        last_update_time=$current_time
        HEALTH_CHECK_COUNTER=$((HEALTH_CHECK_COUNTER + 1))
        if (( HEALTH_CHECK_COUNTER >= 10 )); then
            perform_health_check
            HEALTH_CHECK_COUNTER=0
        fi
    fi

    eta_seconds=$(echo "($blocks_remaining * $avg_block_time) / 1" | bc)
    eta_formatted=$(format_eta $eta_seconds)
    check_milestones "$latest_block" "$TARGET_BLOCK"
    send_progress_update
    
    if [ "$blocks_remaining" -le "$FAST_CHECK_THRESHOLD" ]; then
        current_sleep_interval=$FAST_SLEEP_INTERVAL
        mode_icon="${C_RED}⚡ HIGH-FREQ MODE"
        if [ "$FAST_MODE_NOTIFIED" -eq 0 ]; then
            send_discord_notification "FAST_MODE" "System proximity detection: Less than **$FAST_CHECK_THRESHOLD** blocks remaining (**$blocks_remaining** blocks). Monitoring frequency increased to **${FAST_SLEEP_INTERVAL} seconds** intervals. Estimated completion: **$eta_formatted**"
            FAST_MODE_NOTIFIED=1
        fi
    else
        current_sleep_interval=$NORMAL_SLEEP_INTERVAL
        mode_icon="${C_BLUE}📊 STANDARD MODE"
    fi

    printf "\r${C_WHITE}[ 📊 BLOCK: ${C_GREEN}%'d${C_WHITE}/${C_GREEN}%'d${C_WHITE} ] [ ⏱️  ETA: ${C_YELLOW}%s${C_WHITE} ]%b [ %b ] [ 🔄 NEXT: ${C_CYAN}%ss${C_WHITE} ]    " \
    "$latest_block" "$TARGET_BLOCK" "$eta_formatted" "$proposal_status_str" "$mode_icon" "$current_sleep_interval"
    
    sleep $current_sleep_interval
done
