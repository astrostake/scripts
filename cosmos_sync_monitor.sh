#!/bin/bash

# ==============================================================================
# Node Sync Monitor — Powered by AstroStake
# ==============================================================================

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Required flags are marked with *."
    echo ""
    echo "Options:"
    echo "  -p, --rpc-public <URL>* Public RPC URL for comparison."
    echo "  -l, --rpc-local <URL>     Your node's local RPC URL."
    echo "  -c, --config <PATH>       Path to config.toml (alternative to --rpc-local)."
    echo "  -i, --interval <SECONDS>* Refresh interval in seconds."
    echo "  -w, --width <NUMBER>      Width of the output table. (Max: 108, Default: auto)"
    echo "  -h, --help                Display this help message."
}

while [[ "$#" -gt 0 ]]; do
    case $1 in
        -p|--rpc-public) RPC_PUBLIC="$2"; shift ;;
        -l|--rpc-local) RPC_LOCAL="$2"; shift ;;
        -c|--config) CONFIG_PATH="$2"; shift ;;
        -i|--interval) INTERVAL="$2"; shift ;;
        -w|--width) LINE_WIDTH="$2"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1"; usage; exit 1 ;;
    esac
    shift
done

if [[ -z "$LINE_WIDTH" ]]; then
    if command -v tput &> /dev/null && tput cols &> /dev/null; then
        LINE_WIDTH=$(tput cols)
    else
        LINE_WIDTH=108 # Fallback width if auto-detection fails
    fi
fi

# Set a maximum width of 108
if (( LINE_WIDTH > 108 )); then
    LINE_WIDTH=108
fi

determine_local_rpc() {
    local config_file="$1"
    if [[ ! -f "$config_file" ]]; then echo ""; return; fi
    local rpc_laddr=$(grep -E '^\s*laddr\s*=' "$config_file" | tail -n1 | cut -d'=' -f2- | tr -d ' "')
    if [[ "$rpc_laddr" == tcp://* ]]; then rpc_laddr="http://${rpc_laddr#tcp://}"; fi
    echo "$rpc_laddr"
}

if [[ -z "$RPC_LOCAL" && -n "$CONFIG_PATH" ]]; then
    RPC_LOCAL=$(determine_local_rpc "$CONFIG_PATH")
fi

if [[ -z "$RPC_PUBLIC" || -z "$RPC_LOCAL" || -z "$INTERVAL" ]]; then
    echo "Error: Missing required flags (--rpc-public, --interval, and --rpc-local or --config)." >&2
    usage
    exit 1
fi

BLUE='\033[1;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

center_text_raw() {
    local text="$1"
    local width="$2"
    printf "%*s%s\n" $(( (width - ${#text}) / 2 )) "" "$text"
}

LINE=$(printf -- '-%.0s' $(seq 1 $LINE_WIDTH))
echo -e "${BLUE}${LINE}${NC}"
echo -e "${BLUE}$(center_text_raw '🛰️ Sync Monitor — Powered by AstroStake 🚀' $LINE_WIDTH)${NC}"
echo -e "${BLUE}${LINE}${NC}"
printf "${BLUE}%-10s | %-10s | %-10s | %-10s | %-10s | %-15s | %-12s | %-11s${NC}\n" \
    "Time" "Local" "Remote" "Behind" "+Blocks" "Speed (blk/s)" "ETA" "Syncing"
echo -e "${BLUE}${LINE}${NC}"

prev_height=0
prev_time=$(date +%s)
first_loop=true

while true; do
    local_status=$(curl -s "$RPC_LOCAL/status")
    local_height=$(echo "$local_status" | jq -r '.result.sync_info.latest_block_height')
    catching_up=$(echo "$local_status" | jq -r '.result.sync_info.catching_up')

    public_status=$(curl -s "$RPC_PUBLIC/status")
    public_height=$(echo "$public_status" | jq -r '.result.sync_info.latest_block_height')

    # Improved error handling for local RPC
    if [[ ! "$local_height" =~ ^[0-9]+$ ]]; then
        printf "%-10s | ${RED}%-10s${NC} | %-10s | ${RED}%-10s${NC} | %-10s | %-15s | %-12s | ${RED}%-11s${NC}\n" \
            "$(date '+%H:%M:%S')" "RPC ERR" "${public_height:--}" "ERR" "--" "--" "--" "ERR"
        sleep "$INTERVAL"
        continue
    fi

    now=$(date +%s)
    diff_public=$((public_height - local_height))

    if [ "$first_loop" = true ]; then
        speed="--"
        eta_fmt="--"
        diff_local="--"
        first_loop=false
    else
        elapsed=$((now - prev_time))
        diff_local=$((local_height - prev_height))
        speed=$(echo "scale=2; $diff_local / ($elapsed + 0.0001)" | bc)
        [[ "$speed" = ".00" ]] && speed="0.00"

        if [[ $(echo "$speed > 0" | bc -l) -eq 1 && "$diff_public" -gt 0 ]]; then
            eta_sec_int=$(echo "$diff_public / $speed" | bc)
            eta_fmt=$(printf '%02dh:%02dm:%02ds' $((eta_sec_int / 3600)) $(((eta_sec_int % 3600) / 60)) $((eta_sec_int % 60)))
        else
            eta_fmt="∞"
        fi
    fi

    if (( diff_public < 50 )); then diff_color=$GREEN
    elif (( diff_public < 1000 )); then diff_color=$YELLOW
    else diff_color=$RED; fi

    if [[ $(echo "$speed >= 10" | bc -l) -eq 1 ]]; then speed_color=$GREEN
    elif [[ $(echo "$speed >= 1" | bc -l) -eq 1 ]]; then speed_color=$YELLOW
    else speed_color=$RED; fi

    printf "%-10s | %-10s | %-10s | ${diff_color}%-10s${NC} | +%-9s | ${speed_color}%-15s${NC} | %-12s | %-11s${NC}\n" \
        "$(date '+%H:%M:%S')" "$local_height" "$public_height" "$diff_public" "$diff_local" "$speed blk/s" "$eta_fmt" "$catching_up"

    prev_height=$local_height
    prev_time=$now
    sleep "$INTERVAL"
done
