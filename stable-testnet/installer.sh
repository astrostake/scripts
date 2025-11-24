#!/bin/bash
set -e

echo "====================================================="
echo " 🚀 Stable Testnet Auto Installer"
echo "====================================================="

###############################################################################
#                               USER INPUT                                     #
###############################################################################

read -p "Enter your moniker: " MONIKER
if [ -z "$MONIKER" ]; then
  echo "❌ Moniker cannot be empty!"
  exit 1
fi

echo
echo "Choose port configuration:"
echo "1) Use default ports"
echo "2) Use custom port prefix (recommended)"
read -p "Select option (1 or 2): " PORT_OPTION

if [ "$PORT_OPTION" == "2" ]; then
    read -p "Enter 2-digit port prefix (e.g., 13, 22, 10): " PORT_PREFIX
    if ! [[ "$PORT_PREFIX" =~ ^[0-9]{2}$ ]]; then
      echo "❌ Port prefix must be exactly 2 digits!"
      exit 1
    fi
    CUSTOM_PORTS=true
else
    echo "➡️ Using default ports"
    CUSTOM_PORTS=false
fi

###############################################################################
#                               CONFIG BLOCK                                   #
###############################################################################

BINARY_NAME="stabled"
SERVICE_NAME="stabled"
FOLDER_NAME="stabled"
CHAIN_ID="stabletestnet_2201-1"

BINARY_URL="https://stable-testnet-data.s3.us-east-1.amazonaws.com/stabled-1.1.1-linux-amd64-testnet.tar.gz"
GENESIS_URL="https://vault.astrostake.xyz/testnet/stable/genesis.json"
ADDRBOOK_URL="https://vault.astrostake.xyz/testnet/stable/addrbook.json"
SNAPSHOT_URL="https://vault.astrostake.xyz/testnet/stable/stable-testnet_snapshot.tar.lz4"

###############################################################################
#                        INSTALL DEPENDENCIES + GO                             #
###############################################################################

echo -e "\n📦 Installing dependencies..."
sudo apt update && sudo apt install -y curl git wget jq lz4 tmux htop build-essential unzip make

echo -e "\n📌 Installing Go..."
GO_VER="1.22.3"
cd $HOME
wget -q "https://golang.org/dl/go$GO_VER.linux-amd64.tar.gz"
sudo rm -rf /usr/local/go
sudo tar -C /usr/local -xzf "go$GO_VER.linux-amd64.tar.gz"
rm "go$GO_VER.linux-amd64.tar.gz"
echo "export PATH=\$PATH:/usr/local/go/bin:\$HOME/go/bin" >> ~/.bash_profile
source ~/.bash_profile

###############################################################################
#                           DOWNLOAD BINARY                                    #
###############################################################################

echo -e "\n⬇️ Downloading Stable binary..."
cd $HOME
rm -rf stable
mkdir stable && cd stable

wget -q $BINARY_URL -O binary.tar.gz
tar -xvf binary.tar.gz
rm binary.tar.gz

chmod +x stabled
sudo mv stabled /usr/local/bin/

###############################################################################
#                           INIT NODE                                          #
###############################################################################

echo -e "\n🛠 Initializing node..."
stabled init "$MONIKER" --chain-id "$CHAIN_ID"

###############################################################################
#                           DEFINE CONFIG PATH                                 #
###############################################################################

CONFIG="$HOME/.$FOLDER_NAME/config"   # FIXED PLACE

echo -e "\n📄 Downloading genesis & addrbook..."
curl -Ls $GENESIS_URL > $CONFIG/genesis.json
curl -Ls $ADDRBOOK_URL > $CONFIG/addrbook.json

###############################################################################
#                     ENABLE JSON-RPC FIRST (IMPORTANT)                        #
###############################################################################

echo -e "\n🟩 Enabling JSON-RPC..."

sed -i '/^\[json-rpc\]/,/^\[/{s/^enable *=.*/enable = true/}' $CONFIG/app.toml
sed -i '/^\[json-rpc\]/,/^\[/{s/address = ".*/address = "0.0.0.0:8545"/}' $CONFIG/app.toml
sed -i '/^\[json-rpc\]/,/^\[/{s/ws-address = ".*/ws-address = "0.0.0.0:8546"/}' $CONFIG/app.toml
sed -i '/^\[json-rpc\]/,/^\[/{s/^allow-unprotected-txs *=.*/allow-unprotected-txs = true/}' $CONFIG/app.toml

sed -i 's/^inter-block-cache *=.*/inter-block-cache = false/' $CONFIG/app.toml

###############################################################################
#                         PORT CONFIGURATION                                   #
###############################################################################

if [ "$CUSTOM_PORTS" = true ]; then
  echo -e "\n⚙️ Applying custom port prefix: $PORT_PREFIX"

  # app.toml
  sed -i.bak -e "s%:1317%:${PORT_PREFIX}317%g;
s%:8080%:${PORT_PREFIX}080%g;
s%:9090%:${PORT_PREFIX}090%g;
s%:9091%:${PORT_PREFIX}091%g;
s%:8545%:${PORT_PREFIX}545%g;
s%:8546%:${PORT_PREFIX}546%g" $CONFIG/app.toml

  # config.toml
  sed -i.bak -e "s%:26658%:${PORT_PREFIX}658%g;
s%:26657%:${PORT_PREFIX}657%g;
s%:6060%:${PORT_PREFIX}060%g;
s%:26656%:${PORT_PREFIX}656%g;
s%^external_address = \"\"%external_address = \"$(wget -qO- eth0.me):${PORT_PREFIX}656\"%;
s%:26660%:${PORT_PREFIX}660%g" $CONFIG/config.toml

else
  echo -e "\n⚙️ Skipping custom port configuration (using defaults)"
fi

###############################################################################
#                               SNAPSHOT                                       #
###############################################################################

echo -e "\n📦 Installing snapshot..."
cp $HOME/.$FOLDER_NAME/data/priv_validator_state.json $HOME/priv_validator_state.backup

rm -rf $HOME/.$FOLDER_NAME/data
curl -L $SNAPSHOT_URL | lz4 -dc - | tar -xf - -C $HOME/.$FOLDER_NAME

mv $HOME/priv_validator_state.backup $HOME/.$FOLDER_NAME/data/priv_validator_state.json

###############################################################################
#                           SYSTEMD SERVICE                                   #
###############################################################################

echo -e "\n🔧 Creating systemd service..."
sudo tee /etc/systemd/system/$SERVICE_NAME.service > /dev/null <<EOF
[Unit]
Description=Stable Node
After=network-online.target

[Service]
User=$USER
ExecStart=/usr/local/bin/stabled start --chain-id ${CHAIN_ID}
Restart=always
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

echo -e "\n🚀 Starting service..."
sudo systemctl daemon-reload
sudo systemctl enable $SERVICE_NAME
sudo systemctl restart $SERVICE_NAME

echo -e "\n🎉 DONE!"
echo "Logs:     sudo journalctl -u $SERVICE_NAME -fo cat"
echo "Status:   sudo systemctl status $SERVICE_NAME"
echo
