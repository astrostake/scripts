#!/bin/bash

# === HELP FUNCTION ===
usage() {
  echo "Usage: $0 [OPTIONS]"
  echo "Monitors the synchronization status of a Cosmos SDK node."
  echo ""
  echo "Options:"
  echo "  -l, --local-rpc URL      Specify the local node RPC endpoint (e.g., http://localhost:26657)."
  echo "  -p, --public-rpc URL     Specify the public/remote RPC endpoint for comparison."
  echo "  -d, --directory PATH     Path to the node's home directory (e.g., $HOME/.lumera)."
  echo "  -i, --interval SECONDS   Refresh interval in seconds (default: 5)."
  echo "  -h, --help               Display this help message."
  exit 1
}

# === DEFAULT CONFIGURATION ===
DEFAULT_PUBLIC_RPC="https://lumera-testnet-rpc.linknode.org"
DEFAULT_NODE_HOME="$HOME/.lumera"
DEFAULT_LOCAL_RPC_FALLBACK="http://localhost:26657"
INTERVAL=5
LINE_WIDTH=108

# === VARIABLES TO STORE FLAG VALUES ===
LOCAL_RPC_FLAG=""
PUBLIC_RPC_FLAG=""
NODE_HOME_FLAG=""

# === PARSE COMMAND-LINE ARGUMENTS (FLAGS) ===
while [[ "$#" -gt 0 ]]; do
  case $1 in
    -l|--local-rpc) LOCAL_RPC_FLAG="$2"; shift ;;
    -p|--public-rpc) PUBLIC_RPC_FLAG="$2"; shift ;;
    -d|--directory) NODE_HOME_FLAG="$2"; shift ;;
    -i|--interval) INTERVAL="$2"; shift ;;
    -h|--help) usage ;;
    *) echo "Unknown parameter passed: $1"; usage ;;
  esac
  shift
done

# === COLORS ===
BLUE='\033[1;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# === HELPER FUNCTIONS ===
center_text_raw() {
  local text="$1"
  local width="$2"
  local raw_length=${#text}
  local padding=$(( (width - raw_length) / 2 ))
  printf "%*s%s\n" "$padding" "" "$text"
}

check_deps() {
  for cmd in curl jq bc; do
    if ! command -v "$cmd" &> /dev/null; then
      echo -e "${RED}Error: Required command '$cmd' is not installed. Please install it first.${NC}"
      exit 1
    fi
  done
}

# === FUNCTION TO GET RPC FROM CONFIG FILE ===
get_rpc_from_config() {
  local node_home="$1"
  local config_path="$node_home/config/config.toml"
  if [[ ! -f "$config_path" ]]; then
    echo "$DEFAULT_LOCAL_RPC_FALLBACK" # Fallback if config doesn't exist
    return
  fi

  local rpc_section
  rpc_section=$(awk '/^\[rpc\]/{flag=1;next}/^\[/{flag=0}flag' "$config_path")
  local rpc_laddr
  rpc_laddr=$(echo "$rpc_section" | grep -E '^\s*laddr\s*=' | head -n1 | cut -d '=' -f2- | tr -d ' "')

  if [[ "$rpc_laddr" == tcp://* ]]; then
    rpc_laddr="http://${rpc_laddr#tcp://}"
  fi

  # If empty, use the fallback
  [[ -z "$rpc_laddr" ]] && rpc_laddr="$DEFAULT_LOCAL_RPC_FALLBACK"

  echo "$rpc_laddr"
}

# === CHECK DEPENDENCIES ===
check_deps

# === DETERMINE FINAL CONFIGURATION (FLAG > CONFIG > DEFAULT) ===
NODE_HOME=${NODE_HOME_FLAG:-$DEFAULT_NODE_HOME}
RPC_PUBLIC=${PUBLIC_RPC_FLAG:-$DEFAULT_PUBLIC_RPC}

# Logic for Local RPC:
# 1. Use the -l flag if provided.
# 2. If not, try to read from the config file in NODE_HOME.
# 3. If that fails, use the default fallback.
if [[ -n "$LOCAL_RPC_FLAG" ]]; then
  RPC_LOCAL="$LOCAL_RPC_FLAG"
else
  RPC_LOCAL=$(get_rpc_from_config "$NODE_HOME")
fi


# === HEADER OUTPUT ===
LINE=$(printf -- '-%.0s' $(seq 1 $LINE_WIDTH))
echo -e "${BLUE}${LINE}${NC}"
echo -e "${BLUE}$(center_text_raw '🚀 Node Sync Monitor — Built by AstroStake 🛰️' $LINE_WIDTH)${NC}"
echo -e "${BLUE}$(center_text_raw 'https://astrostake.xyz' $LINE_WIDTH)${NC}"
echo -e "${BLUE}${LINE}${NC}"
echo -e "${YELLOW}Local RPC    : ${NC}$RPC_LOCAL"
echo -e "${YELLOW}Public RPC   : ${NC}$RPC_PUBLIC"
echo -e "${YELLOW}Node Home    : ${NC}$NODE_HOME"
echo -e "${YELLOW}Interval     : ${NC}${INTERVAL}s"
echo -e "${BLUE}${LINE}${NC}"
printf "${BLUE}%-10s | %-10s | %-10s | %-10s | %-10s | %-15s | %-12s | %-11s${NC}\n" \
  "Time" "Local" "Remote" "Behind" "+Blocks" "Speed (blk/s)" "ETA" "Syncing"
echo -e "${BLUE}${LINE}${NC}"

# === INIT ===
prev_height=0
prev_time=$(date +%s)
first_loop=true

# === MAIN LOOP ===
while true; do
  local_status=$(curl -s "$RPC_LOCAL/status")
  local_height=$(echo "$local_status" | jq -r '.result.sync_info.latest_block_height')
  catching_up=$(echo "$local_status" | jq -r '.result.sync_info.catching_up')
  
  public_status=$(curl -s "$RPC_PUBLIC/status")
  public_height=$(echo "$public_status" | jq -r '.result.sync_info.latest_block_height')

  # Validate JSON output, set to 'N/A' on error
  if [[ -z "$local_height" || "$local_height" == "null" ]]; then local_height="N/A"; fi
  if [[ -z "$public_height" || "$public_height" == "null" ]]; then public_height="N/A"; fi
  if [[ -z "$catching_up" || "$catching_up" == "null" ]]; then catching_up="N/A"; fi
  
  now=$(date +%s)
  
  # Only perform calculations if heights are numbers
  if [[ "$local_height" =~ ^[0-9]+$ && "$public_height" =~ ^[0-9]+$ ]]; then
    diff_public=$((public_height - local_height))
  else
    diff_public="N/A"
  fi

  if [ "$first_loop" = true ]; then
    speed="--"
    eta_fmt="--"
    diff_local="--"
    first_loop=false
  elif [[ "$prev_height" =~ ^[0-9]+$ && "$local_height" =~ ^[0-9]+$ ]]; then
    elapsed=$((now - prev_time))
    diff_local=$((local_height - prev_height))

    # Avoid division by zero
    if [[ $elapsed -gt 0 ]]; then
      speed=$(echo "scale=2; $diff_local / $elapsed" | bc)
    else
      speed="0.00"
    fi
    [[ "$speed" == ".00" ]] && speed="0.00"

    if [[ $(echo "$speed > 0" | bc -l) -eq 1 && "$diff_public" -gt 0 ]]; then
      eta_sec=$(echo "$diff_public / $speed" | bc -l)
      eta_sec_int=$(printf "%.0f" "$eta_sec")
      eta_fmt=$(printf '%02dh:%02dm:%02ds' $((eta_sec_int / 3600)) $(((eta_sec_int % 3600) / 60)) $((eta_sec_int % 60)))
    else
      eta_fmt="∞"
    fi
  else
      speed="N/A"
      eta_fmt="N/A"
      diff_local="N/A"
  fi

  # Color coding
  if [[ "$diff_public" =~ ^[0-9]+$ ]]; then
    if (( diff_public < 50 )); then diff_color=$GREEN
    elif (( diff_public < 1000 )); then diff_color=$YELLOW
    else diff_color=$RED
    fi
  else
    diff_color=$NC
  fi

  if [[ "$speed" =~ ^[0-9.]+$ ]]; then
    if [[ $(echo "$speed >= 10" | bc -l) -eq 1 ]]; then speed_color=$GREEN
    elif [[ $(echo "$speed >= 1" | bc -l) -eq 1 ]]; then speed_color=$YELLOW
    else speed_color=$RED
    fi
  else
    speed_color=$NC
  fi

  printf "%-10s | %-10s | %-10s | ${diff_color}%-10s${NC} | +%-9s | ${speed_color}%-15s${NC} | %-12s | %-11s\n" \
    "$(date '+%H:%M:%S')" "$local_height" "$public_height" "$diff_public" "$diff_local" "$speed blk/s" "$eta_fmt" "$catching_up"

  prev_height=$local_height
  prev_time=$now

  sleep "$INTERVAL"
done
