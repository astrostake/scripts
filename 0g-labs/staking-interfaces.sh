#!/bin/bash

# ==============================================================================
# 0G Chain - Enhanced Interactive Staking Helper
#
# Description:
#   This script provides a comprehensive command-line interface (CLI) for
#   interacting with the 0G Chain staking smart contracts. It includes
#   automatic signature generation, public key extraction, and simplified
#   validator creation and delegation management.
#
# Prerequisites:
#   - bash
#   - foundry (for the 'cast' command) installed and in your PATH
#   - 0gchaind binary (for signature generation)
#   - bc (for calculations)
#   - curl (for RPC calls)
#
# Disclaimer:
#   This script is a helper tool. It constructs and executes blockchain
#   transactions. Always review the commands it generates before confirming
#   execution. The authors are not responsible for any loss of funds.
# ==============================================================================

# --- Configuration ---
RPC_URL="https://evmrpc-testnet.0g.ai"
STAKING_CONTRACT="0xea224dBB52F57752044c0C86aD50930091F561B9" # Testnet Address

# Default paths - can be overridden
DEFAULT_HOMEDIR="$HOME/.0gchaind/galileo/0g-home/0gchaind-home"
DEFAULT_CHAIN_SPEC="devnet"
DEFAULT_BINARY_PATH="/usr/local/bin/0gchaind"

# --- Colors for UI ---
C_RESET='\033[0m'
C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[0;33m'
C_BLUE='\033[0;34m'
C_CYAN='\033[0;36m'
C_MAGENTA='\033[0;35m'

# --- Utility Functions ---
function print_color() {
    echo -e "${2}${1}${C_RESET}"
}

function print_header() {
    echo
    print_color "==========================================" $C_BLUE
    print_color "  $1" $C_BLUE
    print_color "==========================================" $C_BLUE
    echo
}

function press_enter_to_continue() {
    echo
    read -p "Press [Enter] to continue..."
}

function check_dependencies() {
    local missing_deps=()
    
    if ! command -v cast &> /dev/null; then
        missing_deps+=("foundry (cast)")
    fi
    
    if ! command -v bc &> /dev/null; then
        missing_deps+=("bc")
    fi
    
    if ! command -v curl &> /dev/null; then
        missing_deps+=("curl")
    fi
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        print_color "Missing dependencies:" $C_RED
        for dep in "${missing_deps[@]}"; do
            echo "  - $dep"
        done
        echo
        print_color "Please install the missing dependencies before proceeding." $C_YELLOW
        return 1
    fi
    
    return 0
}

function validate_address() {
    local address=$1
    if [[ ! "$address" =~ ^0x[a-fA-F0-9]{40}$ ]]; then
        print_color "Error: Invalid Ethereum address format." $C_RED
        return 1
    fi
    return 0
}

function validate_pubkey() {
    local pubkey=$1
    if [[ ! "$pubkey" =~ ^0x[a-fA-F0-9]{96}$ ]]; then
        print_color "Error: Invalid public key format. Expected 48-byte hex string." $C_RED
        return 1
    fi
    return 0
}

# --- Core Logic Functions ---

function get_validator_address() {
    local pubkey=$1
    print_color "Querying validator contract address for pubkey: ${pubkey}..." $C_CYAN >&2
    
    local validator_address
    validator_address=$(cast call --rpc-url "$RPC_URL" "$STAKING_CONTRACT" "getValidator(bytes)(address)" "$pubkey" 2>/dev/null)

    if [[ -z "$validator_address" || "$validator_address" == "0x0000000000000000000000000000000000000000" ]]; then
        print_color "Error: Validator not found for the given public key." $C_RED >&2
        print_color "Please ensure the validator has been created." $C_YELLOW >&2
        return 1
    fi

    echo "$validator_address"
    return 0
}

function compute_validator_address() {
    local pubkey=$1
    print_color "Computing validator contract address for pubkey: ${pubkey}..." $C_CYAN >&2
    
    local validator_address
    validator_address=$(cast call --rpc-url "$RPC_URL" "$STAKING_CONTRACT" "computeValidatorAddress(bytes)(address)" "$pubkey" 2>/dev/null)

    if [[ -z "$validator_address" ]]; then
        print_color "Error: Failed to compute validator address." $C_RED >&2
        return 1
    fi

    echo "$validator_address"
    return 0
}

# NEW: Generate Public Key and Signature
function generate_validator_keys() {
    print_header "Generate Validator Keys & Signature"
    
    print_color "This function will help you generate the public key and signature needed for validator creation." $C_YELLOW
    echo
    
    # Get configuration
    read -p "Enter 0gchaind home directory (default: $DEFAULT_HOMEDIR): " homedir
    homedir=${homedir:-$DEFAULT_HOMEDIR}
    
    read -p "Enter chain spec (default: $DEFAULT_CHAIN_SPEC): " chain_spec
    chain_spec=${chain_spec:-$DEFAULT_CHAIN_SPEC}
    
    read -p "Enter 0gchaind binary path (default: $DEFAULT_BINARY_PATH): " binary_path
    binary_path=${binary_path:-$DEFAULT_BINARY_PATH}
    
    read -p "Enter initial delegation amount in Ether (default: 32): " initial_delegation
    initial_delegation=${initial_delegation:-32}
    
    # Validate binary exists
    if [[ ! -f "$binary_path" ]]; then
        print_color "Error: 0gchaind binary not found at: $binary_path" $C_RED
        print_color "Please ensure the binary path is correct." $C_YELLOW
        press_enter_to_continue
        return
    fi
    
    # Validate home directory
    if [[ ! -d "$homedir/config" ]]; then
        print_color "Error: Config directory not found at: $homedir/config" $C_RED
        print_color "Please ensure the home directory is correct and contains validator configuration." $C_YELLOW
        press_enter_to_continue
        return
    fi
    
    print_color "\n--- Step 1: Extracting Public Key ---" $C_CYAN
    
    local pubkey_output
    pubkey_output=$($binary_path deposit validator-keys --home "$homedir" --chaincfg.chain-spec="$chain_spec" 2>&1)
    
    if [[ $? -ne 0 ]]; then
        print_color "Error extracting public key:" $C_RED
        echo "$pubkey_output"
        press_enter_to_continue
        return
    fi
    
    local pubkey
    pubkey=$(echo "$pubkey_output" | grep -o "0x[a-fA-F0-9]\{96\}" | head -n1)
    
    if [[ -z "$pubkey" ]]; then
        print_color "Error: Could not extract public key from output:" $C_RED
        echo "$pubkey_output"
        press_enter_to_continue
        return
    fi
    
    print_color "✅ Public Key extracted: $pubkey" $C_GREEN
    
    print_color "\n--- Step 2: Computing Validator Address ---" $C_CYAN
    
    local validator_address
    validator_address=$(compute_validator_address "$pubkey")
    if [[ $? -ne 0 ]]; then
        press_enter_to_continue
        return
    fi
    
    print_color "✅ Validator Address computed: $validator_address" $C_GREEN
    
    print_color "\n--- Step 3: Generating Signature ---" $C_CYAN
    
    local initial_delegation_gwei
    initial_delegation_gwei=$(echo "$initial_delegation * 1000000000" | bc)
    
    local signature_output
    signature_output=$($binary_path deposit create-validator \
        "$validator_address" \
        "$initial_delegation_gwei" \
        "$homedir/config/genesis.json" \
        --home "$homedir" \
        --chaincfg.chain-spec="$chain_spec" 2>&1)
    
    if [[ $? -ne 0 ]]; then
        print_color "Error generating signature:" $C_RED
        echo "$signature_output"
        press_enter_to_continue
        return
    fi
    
    local signature
    signature=$(echo "$signature_output" | grep -o "0x[a-fA-F0-9]\{192\}" | head -n1)
    
    if [[ -z "$signature" ]]; then
        print_color "Error: Could not extract signature from output:" $C_RED
        echo "$signature_output"
        press_enter_to_continue
        return
    fi
    
    print_color "✅ Signature generated successfully!" $C_GREEN
    
    print_header "Generated Validator Information"
    print_color "Public Key:        $pubkey" $C_CYAN
    print_color "Validator Address: $validator_address" $C_CYAN
    print_color "Signature:         $signature" $C_CYAN
    print_color "Initial Delegation: $initial_delegation ETH" $C_CYAN
    
    echo
    print_color "Save this information! You'll need it for validator initialization." $C_YELLOW
    
    # Ask if user wants to proceed with validator creation
    echo
    read -p "Do you want to proceed with creating the validator now? (y/N): " proceed
    if [[ "$proceed" =~ ^[Yy]$ ]]; then
        create_validator_with_keys "$pubkey" "$signature" "$initial_delegation"
    fi
    
    press_enter_to_continue
}

# Enhanced Create Validator function
function create_validator_with_keys() {
    local provided_pubkey=$1
    local provided_signature=$2
    local provided_delegation=$3
    
    local pubkey signature self_delegation_eth
    
    if [[ -n "$provided_pubkey" && -n "$provided_signature" && -n "$provided_delegation" ]]; then
        pubkey=$provided_pubkey
        signature=$provided_signature
        self_delegation_eth=$provided_delegation
        print_color "Using provided keys from signature generation." $C_GREEN
    else
        print_color "Step 1: Validator Keys" $C_CYAN
        print_color "You can either:" $C_YELLOW
        echo "  1. Use the 'Generate Keys' option first (recommended)"
        echo "  2. Enter manually generated keys"
        echo
        
        read -p "Enter Validator Public Key (0x...): " pubkey
        if ! validate_pubkey "$pubkey"; then
            press_enter_to_continue
            return
        fi
        
        read -p "Enter Signature (0x...): " signature
        read -p "Enter Initial Self-Delegation (in Ether, min 32): " self_delegation_eth
        
        # Validate minimum delegation
        if (( $(echo "$self_delegation_eth < 32" | bc -l) )); then
            print_color "Error: Minimum delegation is 32 OG tokens." $C_RED
            press_enter_to_continue
            return
        fi
    fi

    print_color "\nStep 2: Validator Description" $C_CYAN
    read -p "Moniker (display name, max 70 chars): " moniker
    read -p "Identity (e.g., keybase ID, max 3000 chars): " identity
    read -p "Website (URL, max 140 chars): " website
    read -p "Security Contact (email, max 140 chars): " security_contact
    read -p "Details (short description, max 280 chars): " details

    print_color "\nStep 3: Operational Parameters" $C_CYAN
    read -p "Commission Rate (e.g., 50000 for 5%, max 1000000): " commission_rate
    read -p "Withdrawal Fee (in Gwei, e.g., 1): " withdrawal_fee

    # Validate commission rate
    if (( commission_rate > 1000000 )); then
        print_color "Error: Commission rate cannot exceed 100% (1000000)." $C_RED
        press_enter_to_continue
        return
    fi

    local description="[\"$moniker\",\"$identity\",\"$website\",\"$security_contact\",\"$details\"]"

    print_header "Transaction Review"
    echo "Contract:          $STAKING_CONTRACT"
    echo "Function:          createAndInitializeValidatorIfNecessary"
    echo "RPC URL:           $RPC_URL"
    echo "Self-Delegation:   $self_delegation_eth ETH"
    print_color "Parameters:" $C_YELLOW
    echo "  Moniker:         $moniker"
    echo "  Commission:      $(echo "scale=2; $commission_rate / 10000" | bc)%"
    echo "  Withdrawal Fee:  ${withdrawal_fee} Gwei"
    echo "  Public Key:      $pubkey"
    echo "  Signature:       ${signature:0:20}...${signature: -20}"
    echo

    read -p "Do you want to execute this transaction? (y/N): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        print_color "Executing transaction..." $C_CYAN
        
        local tx_result
        tx_result=$(cast send --rpc-url "$RPC_URL" --value "${self_delegation_eth}ether" --private-key "$ETH_PRIVATE_KEY" \
            "$STAKING_CONTRACT" \
            "createAndInitializeValidatorIfNecessary((string,string,string,string,string),uint32,uint96,bytes,bytes)" \
            "$description" "$commission_rate" "$withdrawal_fee" "$pubkey" "$signature" 2>&1)

        if [[ $? -eq 0 ]]; then
            print_color "✅ Transaction sent successfully!" $C_GREEN
            echo "Transaction Hash: $(echo "$tx_result" | grep -o "0x[a-fA-F0-9]\{64\}")"
            print_color "Please check the block explorer for confirmation." $C_CYAN
        else
            print_color "❌ Transaction failed:" $C_RED
            echo "$tx_result"
        fi
    else
        print_color "Operation cancelled." $C_RED
    fi
    press_enter_to_continue
}

function create_validator() {
    print_header "Create and Initialize a New Validator"
    print_color "This function will help you call 'createAndInitializeValidatorIfNecessary'." $C_YELLOW
    echo
    create_validator_with_keys
}

function delegate_to_validator() {
    print_header "Delegate Tokens to a Validator"
    
    read -p "Enter the validator's Public Key (0x...): " pubkey
    if ! validate_pubkey "$pubkey"; then
        press_enter_to_continue
        return
    fi
    
    read -p "Enter the amount of OG tokens to delegate (in Ether): " amount_eth
    
    if (( $(echo "$amount_eth <= 0" | bc -l) )); then
        print_color "Error: Delegation amount must be greater than 0." $C_RED
        press_enter_to_continue
        return
    fi

    local validator_address
    validator_address=$(get_validator_address "$pubkey")
    if [[ $? -ne 0 ]]; then
        press_enter_to_continue
        return
    fi
    
    print_color "Found Validator Contract: ${validator_address}" $C_GREEN

    print_header "Transaction Review"
    echo "Validator Contract: $validator_address"
    echo "Function:           delegate(address delegatorAddress)"
    echo "Delegation Amount:  ${amount_eth} ETH"
    echo "RPC URL:            $RPC_URL"
    print_color "Note: Your wallet address will be used as the delegator address." $C_YELLOW
    echo

    read -p "Do you want to execute this transaction? (y/N): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        print_color "Executing transaction..." $C_CYAN
        
        local delegator_address
        delegator_address=$(cast wallet address "$ETH_PRIVATE_KEY" 2>/dev/null)
        
        if [[ -z "$delegator_address" ]]; then
            print_color "Error: Could not derive address from private key." $C_RED
            print_color "Please ensure ETH_PRIVATE_KEY environment variable is set." $C_YELLOW
            press_enter_to_continue
            return
        fi
        
        local tx_result
        tx_result=$(cast send --rpc-url "$RPC_URL" --value "${amount_eth}ether" --private-key "$ETH_PRIVATE_KEY" \
            "$validator_address" \
            "delegate(address)" \
            "$delegator_address" 2>&1)
        
        if [[ $? -eq 0 ]]; then
            print_color "✅ Delegation transaction sent successfully!" $C_GREEN
            echo "Transaction Hash: $(echo "$tx_result" | grep -o "0x[a-fA-F0-9]\{64\}")"
            print_color "Please check the block explorer for confirmation." $C_CYAN
        else
            print_color "❌ Transaction failed:" $C_RED
            echo "$tx_result"
        fi
    else
        print_color "Operation cancelled." $C_RED
    fi
    press_enter_to_continue
}

function undelegate_from_validator() {
    print_header "Undelegate Tokens from Validator"
    
    read -p "Enter the validator's Public Key (0x...): " pubkey
    if ! validate_pubkey "$pubkey"; then
        press_enter_to_continue
        return
    fi
    
    local validator_address
    validator_address=$(get_validator_address "$pubkey")
    if [[ $? -ne 0 ]]; then
        press_enter_to_continue
        return
    fi
    
    print_color "Found Validator Contract: ${validator_address}" $C_GREEN
    
    # Get current delegation info
    local delegator_address
    delegator_address=$(cast wallet address "$ETH_PRIVATE_KEY" 2>/dev/null)
    
    if [[ -z "$delegator_address" ]]; then
        print_color "Error: Could not derive address from private key." $C_RED
        press_enter_to_continue
        return
    fi
    
    local shares_raw
    shares_raw=$(cast call --rpc-url "$RPC_URL" "$validator_address" "getDelegation(address)(address,uint256)" "$delegator_address" 2>/dev/null | sed -n '2p')
    local shares
    shares=$(clean_number "$shares_raw")
    
    if [[ -z "$shares" || "$shares" == "0" ]]; then
        print_color "You have no delegation with this validator." $C_YELLOW
        press_enter_to_continue
        return
    fi
    
    local withdrawal_fee_raw
    withdrawal_fee_raw=$(cast call --rpc-url "$RPC_URL" "$validator_address" "withdrawalFeeInGwei()(uint96)" 2>/dev/null)
    local withdrawal_fee
    withdrawal_fee=$(clean_number "$withdrawal_fee_raw")
    
    print_color "Current delegation shares: $shares" $C_CYAN
    print_color "Withdrawal fee: $withdrawal_fee Gwei" $C_CYAN
    
    read -p "Enter the number of shares to undelegate: " undelegate_shares
    read -p "Enter withdrawal address (press Enter for current address): " withdrawal_address
    withdrawal_address=${withdrawal_address:-$delegator_address}
    
    if ! validate_address "$withdrawal_address"; then
        press_enter_to_continue
        return
    fi
    
    # Use bc for large number comparison
    local valid_amount
    valid_amount=$(echo "$undelegate_shares <= $shares" | bc -l 2>/dev/null)
    if [[ "$valid_amount" != "1" ]]; then
        print_color "Error: Cannot undelegate more shares than you have." $C_RED
        press_enter_to_continue
        return
    fi

    print_header "Transaction Review"
    echo "Validator Contract:   $validator_address"
    echo "Function:             undelegate(address,uint256)"
    echo "Shares to Undelegate: $undelegate_shares"
    echo "Withdrawal Address:   $withdrawal_address"
    echo "Withdrawal Fee:       $withdrawal_fee Gwei"
    echo

    read -p "Do you want to execute this transaction? (y/N): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        print_color "Executing transaction..." $C_CYAN
        
        local fee_in_wei
        fee_in_wei=$(echo "$withdrawal_fee * 1000000000" | bc -l)
        
        local tx_result
        tx_result=$(cast send --rpc-url "$RPC_URL" --value "${fee_in_wei}wei" --private-key "$ETH_PRIVATE_KEY" \
            "$validator_address" \
            "undelegate(address,uint256)" \
            "$withdrawal_address" "$undelegate_shares" 2>&1)
        
        if [[ $? -eq 0 ]]; then
            print_color "✅ Undelegation transaction sent successfully!" $C_GREEN
            echo "Transaction Hash: $(echo "$tx_result" | grep -o "0x[a-fA-F0-9]\{64\}")"
            print_color "Note: There is a withdrawal delay period before tokens become available." $C_YELLOW
        else
            print_color "❌ Transaction failed:" $C_RED
            echo "$tx_result"
        fi
    else
        print_color "Operation cancelled." $C_RED
    fi
    press_enter_to_continue
}

function clean_number() {
    local input=$1
    # Remove scientific notation and brackets, keep only the number
    echo "$input" | sed 's/\[.*\]//g' | tr -d ' '
}

function get_delegation_info() {
    print_header "Get Delegation Information"
    
    read -p "Enter the validator's Public Key (0x...): " pubkey
    if ! validate_pubkey "$pubkey"; then
        press_enter_to_continue
        return
    fi
    
    read -p "Enter the Delegator's Address (leave empty for your address): " delegator_address
    
    if [[ -z "$delegator_address" ]]; then
        delegator_address=$(cast wallet address "$ETH_PRIVATE_KEY" 2>/dev/null)
        if [[ -z "$delegator_address" ]]; then
            print_color "Error: Could not derive address from private key." $C_RED
            press_enter_to_continue
            return
        fi
        print_color "Using your wallet address: $delegator_address" $C_CYAN
    fi
    
    if ! validate_address "$delegator_address"; then
        press_enter_to_continue
        return
    fi

    local validator_address
    validator_address=$(get_validator_address "$pubkey")
    if [[ $? -ne 0 ]]; then
        press_enter_to_continue
        return
    fi
    
    print_color "Found Validator Contract: ${validator_address}" $C_GREEN
    print_color "Fetching delegation info..." $C_CYAN

    # Get delegation info
    local delegation_result
    delegation_result=$(cast call --rpc-url "$RPC_URL" "$validator_address" "getDelegation(address)(address,uint256)" "$delegator_address" 2>/dev/null)
    
    local shares_raw
    shares_raw=$(echo "$delegation_result" | sed -n '2p')
    local shares
    shares=$(clean_number "$shares_raw")
    
    # Get validator info
    local total_tokens_raw
    total_tokens_raw=$(cast call --rpc-url "$RPC_URL" "$validator_address" "tokens()(uint256)" 2>/dev/null)
    local total_tokens
    total_tokens=$(clean_number "$total_tokens_raw")
    
    local total_shares_raw
    total_shares_raw=$(cast call --rpc-url "$RPC_URL" "$validator_address" "delegatorShares()(uint256)" 2>/dev/null)
    local total_shares
    total_shares=$(clean_number "$total_shares_raw")
    
    local commission_rate_raw
    commission_rate_raw=$(cast call --rpc-url "$RPC_URL" "$validator_address" "commissionRate()(uint32)" 2>/dev/null)
    local commission_rate
    commission_rate=$(clean_number "$commission_rate_raw")
    
    local withdrawal_fee_raw
    withdrawal_fee_raw=$(cast call --rpc-url "$RPC_URL" "$validator_address" "withdrawalFeeInGwei()(uint96)" 2>/dev/null)
    local withdrawal_fee
    withdrawal_fee=$(clean_number "$withdrawal_fee_raw")

    print_header "Delegation Details"
    echo "Validator Contract:   $validator_address"
    echo "Delegator Address:    $delegator_address"
    print_color "Delegation Shares:    ${shares:-0}" $C_GREEN
    print_color "Raw Shares Output:    $shares_raw" $C_YELLOW
    
    # Calculate estimated tokens with better validation
    local estimated_tokens_eth="0"
    if [[ -n "$total_shares" && -n "$shares" && -n "$total_tokens" ]]; then
        # Use bc for comparison since bash can't handle large numbers
        local has_shares
        has_shares=$(echo "$shares > 0" | bc -l 2>/dev/null)
        local has_total_shares
        has_total_shares=$(echo "$total_shares > 0" | bc -l 2>/dev/null)
        
        if [[ "$has_shares" == "1" && "$has_total_shares" == "1" ]]; then
            local estimated_tokens
            estimated_tokens=$(echo "scale=0; ($shares * $total_tokens) / $total_shares" | bc -l 2>/dev/null)
            if [[ -n "$estimated_tokens" && "$estimated_tokens" != "0" ]]; then
                estimated_tokens_eth=$(cast --from-wei "$estimated_tokens" 2>/dev/null || echo "0")
            fi
        fi
    fi
    
    print_color "Estimated Tokens:     ~${estimated_tokens_eth} OG" $C_GREEN
    if [[ "$estimated_tokens_eth" != "0" ]]; then
        print_color "(Includes principal + accrued rewards)" $C_YELLOW
    fi
    
    echo
    print_header "Validator Information"
    local total_tokens_eth
    total_tokens_eth=$(cast --from-wei "${total_tokens:-0}" 2>/dev/null || echo "0")
    echo "Total Validator Tokens: $total_tokens_eth OG"
    echo "Total Delegator Shares: ${total_shares:-0}"
    echo "Commission Rate:        $(echo "scale=2; ${commission_rate:-0} / 10000" | bc -l)%"
    echo "Withdrawal Fee:         ${withdrawal_fee:-0} Gwei"

    press_enter_to_continue
}

function get_validator_info() {
    print_header "Get Validator Information"
    
    read -p "Enter the validator's Public Key (0x...): " pubkey
    if ! validate_pubkey "$pubkey"; then
        press_enter_to_continue
        return
    fi

    local validator_address
    validator_address=$(get_validator_address "$pubkey")
    if [[ $? -ne 0 ]]; then
        press_enter_to_continue
        return
    fi
    
    print_color "Found Validator Contract: ${validator_address}" $C_GREEN
    print_color "Fetching validator information..." $C_CYAN

    # Get validator details with cleaning
    local total_tokens_raw
    total_tokens_raw=$(cast call --rpc-url "$RPC_URL" "$validator_address" "tokens()(uint256)" 2>/dev/null)
    local total_tokens
    total_tokens=$(clean_number "$total_tokens_raw")
    
    local total_shares_raw
    total_shares_raw=$(cast call --rpc-url "$RPC_URL" "$validator_address" "delegatorShares()(uint256)" 2>/dev/null)
    local total_shares
    total_shares=$(clean_number "$total_shares_raw")
    
    local commission_rate_raw
    commission_rate_raw=$(cast call --rpc-url "$RPC_URL" "$validator_address" "commissionRate()(uint32)" 2>/dev/null)
    local commission_rate
    commission_rate=$(clean_number "$commission_rate_raw")
    
    local withdrawal_fee_raw
    withdrawal_fee_raw=$(cast call --rpc-url "$RPC_URL" "$validator_address" "withdrawalFeeInGwei()(uint96)" 2>/dev/null)
    local withdrawal_fee
    withdrawal_fee=$(clean_number "$withdrawal_fee_raw")

    # Get global staking info
    local validator_count_raw
    validator_count_raw=$(cast call --rpc-url "$RPC_URL" "$STAKING_CONTRACT" "validatorCount()(uint32)" 2>/dev/null)
    local validator_count
    validator_count=$(clean_number "$validator_count_raw")
    
    local max_validators_raw
    max_validators_raw=$(cast call --rpc-url "$RPC_URL" "$STAKING_CONTRACT" "maxValidatorCount()(uint32)" 2>/dev/null)
    local max_validators
    max_validators=$(clean_number "$max_validators_raw")

    print_header "Validator Details"
    echo "Public Key:           $pubkey"
    echo "Contract Address:     $validator_address"
    local total_tokens_eth
    total_tokens_eth=$(cast --from-wei "${total_tokens:-0}" 2>/dev/null || echo "0")
    echo "Total Tokens:         $total_tokens_eth OG"
    echo "Total Shares:         ${total_shares:-0}"
    echo "Commission Rate:      $(echo "scale=2; ${commission_rate:-0} / 10000" | bc -l)%"
    echo "Withdrawal Fee:       ${withdrawal_fee:-0} Gwei"
    
    echo
    print_header "Network Information"
    echo "Active Validators:    ${validator_count:-0}"
    echo "Max Validators:       ${max_validators:-0}"

    press_enter_to_continue
}

# --- Environment Check ---
function check_environment() {
    print_color "Checking environment..." $C_CYAN
    
    if [[ -z "$ETH_PRIVATE_KEY" ]]; then
        print_color "Warning: ETH_PRIVATE_KEY environment variable not set." $C_YELLOW
        print_color "You'll need to set this for transactions to work." $C_YELLOW
        print_color "Example: export ETH_PRIVATE_KEY='0x...'" $C_YELLOW
        echo
    fi
    
    if ! check_dependencies; then
        exit 1
    fi
    
    print_color "Environment check completed." $C_GREEN
    echo
}

# --- Main Menu ---
function main_menu() {
    check_environment
    
    while true; do
        clear
        print_color "==========================================" $C_BLUE
        print_color "   0G Chain Enhanced Staking Helper" $C_BLUE
        print_color "==========================================" $C_BLUE
        echo
        print_color "  Network:          Testnet" $C_CYAN
        print_color "  Staking Contract: $STAKING_CONTRACT" $C_CYAN
        print_color "  RPC Endpoint:     $RPC_URL" $C_CYAN
        echo
        print_color "  🔑 Validator Management:" $C_YELLOW
        echo "  1. Generate Validator Keys & Signature"
        echo "  2. Create and Initialize Validator"
        echo "  3. Get Validator Information"
        echo
        print_color "  💰 Delegation Management:" $C_YELLOW
        echo "  4. Delegate Tokens to Validator"
        echo "  5. Undelegate Tokens from Validator"
        echo "  6. Check Delegation Information"
        echo
        print_color "  ⚙️  Utilities:" $C_YELLOW
        echo "  7. Check Environment & Dependencies"
        echo "  8. Exit"
        echo
        read -p "  Enter your choice [1-8]: " choice

        case $choice in
            1) generate_validator_keys ;;
            2) create_validator ;;
            3) get_validator_info ;;
            4) delegate_to_validator ;;
            5) undelegate_from_validator ;;
            6) get_delegation_info ;;
            7) check_environment; press_enter_to_continue ;;
            8) print_color "Exiting. Goodbye!" $C_GREEN; exit 0 ;;
            *) print_color "Invalid option. Please try again." $C_RED; press_enter_to_continue ;;
        esac
    done
}

# --- Script Start ---

# Show welcome message
clear
print_color "==========================================" $C_BLUE
print_color "   Welcome to 0G Chain Staking Helper!" $C_BLUE
print_color "==========================================" $C_BLUE
echo
print_color "Enhanced features:" $C_GREEN
echo "  ✅ Automatic key generation & signature creation"
echo "  ✅ Complete validator lifecycle management"
echo "  ✅ Advanced delegation operations"
echo "  ✅ Comprehensive validation & error handling"
echo "  ✅ Real-time network information"
echo
print_color "Prerequisites:" $C_YELLOW
echo "  • 0gchaind binary (for key generation)"
echo "  • Foundry (cast command)"
echo "  • ETH_PRIVATE_KEY environment variable"
echo
print_color "Safety Notice:" $C_RED
echo "  • Always verify transaction details before confirming"
echo "  • Keep your private keys secure"
echo "  • Test with small amounts first"
echo

press_enter_to_continue

# Start main menu
main_menu
