#!/bin/bash

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
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done

# --- Validate required arguments ---
if [ -z "$DAEMON_NAME" ] || [ -z "$TARGET_BLOCK" ] || [ -z "$NEW_BINARY_PATH" ]; then
    echo "🔥 ERROR: Missing required arguments."
    echo "Usage: $0 -b <binary_name> -t <target_block> -n <new_binary_path> [options]"
    echo "Example: ... | bash -s -- -b lumerad -t 425000 -n /root/lumerad-v2 -i 12"
    exit 1
fi

# --- Derive dependent variables ---
SERVICE_NAME="${DAEMON_NAME}.service"

#======================================================================================================================
# SCRIPT CONSTANTS AND FUNCTIONS
#======================================================================================================================

# --- Color Codes ---
C_RESET='\033[0m';C_RED='\033[0;31m';C_GREEN='\033[0;32m';C_YELLOW='\033[0;33m';C_BLUE='\033[0;34m';C_CYAN='\033[0;36m';C_WHITE='\033[0;37m'

# --- Final Status and Exit Trap ---
SCRIPT_STATUS="FAILURE"
function final_message() {
    echo ""; echo -e "${C_WHITE}======================= SCRIPT FINISHED =======================${C_RESET}"
    if [ "$SCRIPT_STATUS" == "SUCCESS" ]; then
        echo -e "🎉 ${C_GREEN}Mission Accomplished: Upgrade process completed successfully.${C_RESET}"
    else
        echo -e "🔥 ${C_RED}Mission Failed: Script exited with an error.${C_RESET}"
    fi
    echo -e "${C_WHITE}===============================================================${C_RESET}"
}
trap final_message EXIT

# --- Dependency and Helper Functions ---
for cmd in jq bc; do
  if ! command -v $cmd &> /dev/null; then echo -e "⚠️ ${C_RED}Command '$cmd' not found.${C_RESET}"; exit 1; fi
done
format_eta() {
  local h m s; h=$(($1/3600)); m=$(($1%3600/60)); s=$(($1%60)); printf "%02dh %02dm %02ds" $h $m $s
}

# --- Script Start ---
echo -e "✅ ${C_GREEN}Cosmos Auto-Update Script Started${C_RESET}"
echo -e "${C_WHITE}------------------------------------------------${C_RESET}"
echo -e "   ${C_WHITE}Daemon:               ${C_CYAN}$DAEMON_NAME${C_RESET}"
echo -e "   ${C_WHITE}Target Block:         ${C_CYAN}$TARGET_BLOCK${C_RESET}"
if [ -n "$PROPOSAL_ID" ]; then
echo -e "   ${C_WHITE}Proposal ID:          ${C_CYAN}$PROPOSAL_ID${C_RESET}"
echo -e "   ${C_WHITE}API Endpoint:         ${C_CYAN}$API_URL${C_RESET}"
fi
echo -e "   ${C_WHITE}⚡ Fast Mode:          ${C_YELLOW}Active when remaining blocks ≤ $FAST_CHECK_THRESHOLD (checks every ${FAST_SLEEP_INTERVAL}s)${C_RESET}"
echo -e "${C_WHITE}------------------------------------------------${C_RESET}"

# --- Initial Checks ---
echo -e "🔬 ${C_YELLOW}Performing initial checks...${C_RESET}"
if [ ! -f "$BINARY_INSTALL_PATH/$DAEMON_NAME" ]; then echo -e "🔥 ${C_RED}ERROR: Current binary not found at $BINARY_INSTALL_PATH/$DAEMON_NAME${C_RESET}"; exit 1; fi
CURRENT_VERSION=$($BINARY_INSTALL_PATH/$DAEMON_NAME version 2>&1); echo -e "   ✔️  ${C_WHITE}Current Version: ${C_GREEN}$CURRENT_VERSION${C_RESET}"
if [ ! -f "$NEW_BINARY_PATH" ]; then echo -e "🔥 ${C_RED}ERROR: New binary not found at $NEW_BINARY_PATH${C_RESET}"; exit 1; fi
chmod +x "$NEW_BINARY_PATH"; NEW_VERSION=$($NEW_BINARY_PATH version 2>&1); echo -e "   ✔️  ${C_WHITE}New Version:     ${C_GREEN}$NEW_VERSION${C_RESET}"
if [ "$CURRENT_VERSION" == "$NEW_VERSION" ]; then echo -e "⚠️ ${C_YELLOW}WARNING: Versions are identical.${C_RESET}"; exit 1; fi
echo -e "   ${C_GREEN}Checks passed. Starting monitoring...${C_RESET}"
echo -e "${C_WHITE}------------------------------------------------${C_RESET}"

# --- Main Loop ---
avg_block_time=6.0; last_update_time=0; UPDATE_INTERVAL=60; proposal_status_str=""

while true; do
    latest_block=$(curl -s "${RPC_URL}/status" | jq -r .result.sync_info.latest_block_height)
    if [[ ! "$latest_block" =~ ^[0-9]+$ || "$latest_block" -lt 1 ]]; then
        echo -e "\n❌ ${C_RED}Failed to get valid block height. Retrying...${C_RESET}"; sleep $NORMAL_SLEEP_INTERVAL; continue; fi

    if [ "$latest_block" -ge "$TARGET_BLOCK" ]; then
        echo -e "\n🚀 ${C_GREEN}Target Block Reached! Starting upgrade...${C_RESET}"; sudo systemctl stop "$SERVICE_NAME"
        sudo cp "$NEW_BINARY_PATH" "$BINARY_INSTALL_PATH/$DAEMON_NAME"; sudo chmod +x "$BINARY_INSTALL_PATH/$DAEMON_NAME"
        echo "   Version after copy: $($BINARY_INSTALL_PATH/$DAEMON_NAME version 2>&1)"; sudo systemctl start "$SERVICE_NAME"
        SCRIPT_STATUS="SUCCESS"; break; fi

    blocks_remaining=$((TARGET_BLOCK - latest_block)); current_time=$(date +%s)
    
    if (( current_time - last_update_time > UPDATE_INTERVAL )); then
        if [ -n "$PROPOSAL_ID" ]; then
            prop_data=$(curl -s "$API_URL/cosmos/gov/v1/proposals/$PROPOSAL_ID"); current_prop_status=$(echo "$prop_data" | jq -r .proposal.status)
            case "$current_prop_status" in
                "PROPOSAL_STATUS_REJECTED"|"PROPOSAL_STATUS_FAILED")
                    echo -e "\n🔥 ${C_RED}ERROR: Proposal #$PROPOSAL_ID has failed with status: $current_prop_status${C_RESET}"; exit 1 ;;
                "PROPOSAL_STATUS_PASSED") proposal_status_str="──[ 🗳️  Prop #${PROPOSAL_ID}: ${C_GREEN}Passed${C_WHITE} ]" ;;
                "PROPOSAL_STATUS_VOTING_PERIOD") proposal_status_str="──[ 🗳️  Prop #${PROPOSAL_ID}: ${C_CYAN}Voting${C_WHITE} ]" ;;
                *) proposal_status_str="──[ 🗳️  Prop #${PROPOSAL_ID}: ${C_YELLOW}Unknown${C_WHITE} ]" ;;
            esac; fi

        block_curr_time_str=$(curl -s "${RPC_URL}/block?height=${latest_block}" | jq -r .result.block.header.time)
        time_curr=$(date -d "$block_curr_time_str" +%s.%N 2>/dev/null)
        if [[ -n "$time_curr" ]]; then
            prev_block_height=$((latest_block - 5)); [ "$prev_block_height" -lt 1 ] && prev_block_height=1
            block_prev_time_str=$(curl -s "${RPC_URL}/block?height=${prev_block_height}" | jq -r .result.block.header.time)
            time_prev=$(date -d "$block_prev_time_str" +%s.%N 2>/dev/null)
            if [[ -n "$time_prev" && "$latest_block" -gt "$prev_block_height" ]]; then
                time_diff=$(echo "$time_curr-$time_prev"|bc); block_diff=$((latest_block-prev_block_height))
                new_avg_block_time=$(echo "scale=2;$time_diff/$block_diff"|bc)
                if (( $(echo "$new_avg_block_time > 0" | bc -l) )); then avg_block_time=$new_avg_block_time; fi; fi; fi
        last_update_time=$current_time; fi

    eta_seconds=$(echo "($blocks_remaining*$avg_block_time)/1"|bc); eta_formatted=$(format_eta $eta_seconds)
    if [ "$blocks_remaining" -le "$FAST_CHECK_THRESHOLD" ]; then
        current_sleep_interval=$FAST_SLEEP_INTERVAL; mode_icon="${C_RED}⚡ Mode: Fast  "; else
        current_sleep_interval=$NORMAL_SLEEP_INTERVAL; mode_icon="${C_BLUE}💤 Mode: Normal"; fi

    printf "\r${C_WHITE}[ 🧱 ${C_GREEN}%'d${C_WHITE} / ${C_GREEN}%'d${C_WHITE} ]──[ ⏳ ${C_YELLOW}ETA: ~%s${C_WHITE} ]%b──[ %b | ⏱️  Next: ${C_CYAN}%ss${C_WHITE} ]    " \
    "$latest_block" "$TARGET_BLOCK" "$eta_formatted" "$proposal_status_str" "$mode_icon" "$current_sleep_interval"
    sleep $current_sleep_interval
done
