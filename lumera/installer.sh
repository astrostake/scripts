#!/bin/bash
set -e

echo "====================================================="
echo " 🚀 Lumera Auto Installer"
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
    CUSTOM_PORTS=false
fi

###############################################################################
#                               CONFIG BLOCK                                   #
###############################################################################

BINARY_NAME="lumerad"
SERVICE_NAME="lumerad"
CHAIN_ID="lumera-mainnet-1"
FOLDER_NAME="lumera"

BINARY_URL="https://github.com/LumeraProtocol/lumera/releases/download/v1.9.1/lumera_v1.9.1_linux_amd64.tar.gz"
GENESIS_URL="https://snapshots.linknode.org/lumera/genesis"
ADDRBOOK_URL="https://snapshots.linknode.org/lumera/addrbook"
SNAPSHOT_API_URL="https://snapshots.linknode.org/lumera/api"

HOME_FOLDER="$HOME/.lumera"
CONFIG="$HOME_FOLDER/config"

SEEDS=""

PEERS="277773c00a7f7029775deba6e28532c40b670d16@95.214.55.46:30357,c8e9ab5451951bc8f75cdc0eb81b9cb25571e7df@161.35.221.191:26656,ddd091cecab267b467f9f6167e9268391fc0ec1f@57.128.98.34:20001,,faf9bc564f4d200d741da088731b6b3ba02192aa@65.108.232.93:30756,89757803f40da51678451735445ad40d5b15e059@169.155.45.78:26656,1ef18bb3ed8efee9fb150151cbcdfca438fa9db4@64.185.227.242:30756,ab5b0bafe670543d6f25dea19a264c7da1e50672@65.108.201.240:30756,5b8d4baa4e4c86b94322d452dc66c4bf218cfc95@184.107.244.74:12300,54361f222e87b7dd1cb90973079c44e7e31c03e5@15.235.42.134:12300,2afe400bfe662b915111ec6c1e5fcb0d2c0ba64e@37.27.239.10:26656"

###############################################################################
#                           SNAPSHOT CHECK                                     #
###############################################################################

echo -e "\n🔍 Checking latest snapshot availability..."

SNAPSHOT_JSON=$(curl -s $SNAPSHOT_API_URL)

if [ -z "$SNAPSHOT_JSON" ]; then
    echo "⚠️  Failed to fetch snapshot data. Skipping snapshot check."
    USE_SNAPSHOT=false
else
    SNAP_HEIGHT=$(echo $SNAPSHOT_JSON | jq -r '.[0].blockHeight')
    SNAP_UPDATED=$(echo $SNAPSHOT_JSON | jq -r '.[0].updated')
    SNAP_SIZE=$(echo $SNAPSHOT_JSON | jq -r '.[0].files[0].size')
    SNAP_URL=$(echo $SNAPSHOT_JSON | jq -r '.[0].files[0].downloadUrl')
    
    CURRENT_TIME=$(date +%s)
    SNAP_TIME=$(date -d "$SNAP_UPDATED" +%s)
    DIFF_SEC=$((CURRENT_TIME - SNAP_TIME))
    
    if [ $DIFF_SEC -gt 86400 ]; then
        TIME_AGO="$((DIFF_SEC / 86400)) days ago"
    elif [ $DIFF_SEC -gt 3600 ]; then
        TIME_AGO="$((DIFF_SEC / 3600)) hours ago"
    else
        TIME_AGO="$((DIFF_SEC / 60)) minutes ago"
    fi

    echo "-----------------------------------------------------"
    echo "📸 LATEST SNAPSHOT INFO"
    echo "-----------------------------------------------------"
    echo "   📦 Block Height : $SNAP_HEIGHT"
    echo "   💾 Size         : $SNAP_SIZE"
    echo "   ⏰ Updated      : $TIME_AGO ($SNAP_UPDATED)"
    echo "-----------------------------------------------------"

    read -p "Do you want to install this snapshot? (y/n): " INSTALL_SNAP_OPT
    if [[ "$INSTALL_SNAP_OPT" =~ ^[Yy]$ ]]; then
        USE_SNAPSHOT=true
        SNAPSHOT_URL=$SNAP_URL
    else
        USE_SNAPSHOT=false
    fi
fi

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

echo -e "\n⬇️ Downloading $BINARY_NAME..."
cd $HOME
rm -rf $FOLDER_NAME
mkdir $FOLDER_NAME && cd $FOLDER_NAME

wget -q $BINARY_URL -O binary.tar.gz
tar -xvf binary.tar.gz
rm binary.tar.gz

chmod +x $BINARY_NAME
sudo mv $BINARY_NAME /usr/local/bin/
sudo mv libwasmvm.x86_64.so /usr/lib/

###############################################################################
#                           INIT NODE                                          #
###############################################################################

echo -e "\n🛠 Initializing node..."
$BINARY_NAME init "$MONIKER" --chain-id "$CHAIN_ID"

###############################################################################
#                        DOWNLOAD GENESIS + ADDRBOOK                           #
###############################################################################

echo -e "\n📄 Downloading genesis & addrbook..."
curl -Ls $GENESIS_URL > $CONFIG/genesis.json
curl -Ls $ADDRBOOK_URL > $CONFIG/addrbook.json

###############################################################################
#                         PORT CONFIGURATION                                   #
###############################################################################

if [ "$CUSTOM_PORTS" = true ]; then
  echo -e "\n⚙️ Applying custom port prefix: $PORT_PREFIX"

  sed -i.bak -e "s%:1317%:${PORT_PREFIX}317%g;
s%:8080%:${PORT_PREFIX}080%g;
s%:9090%:${PORT_PREFIX}090%g;
s%:9091%:${PORT_PREFIX}091%g;
s%:8545%:${PORT_PREFIX}545%g;
s%:8546%:${PORT_PREFIX}546%g" $CONFIG/app.toml

  sed -i.bak -e "s%:26658%:${PORT_PREFIX}658%g;
s%:26657%:${PORT_PREFIX}657%g;
s%:6060%:${PORT_PREFIX}060%g;
s%:26656%:${PORT_PREFIX}656%g;
s%^external_address = \"\"%external_address = \"$(wget -qO- eth0.me):${PORT_PREFIX}656\"%;
s%:26660%:${PORT_PREFIX}660%g" $CONFIG/config.toml

else
  echo -e "\n⚙️ Using default ports"
  sed -i "s%^external_address = \"\"%external_address = \"$(wget -qO- eth0.me):26656\"%" $CONFIG/config.toml
fi

###############################################################################
#                               SET PEERS                                     #
###############################################################################

echo -e "\n🌐 Setting P2P Peers..."

sed -i -e "/^\[p2p\]/,/^\[/{s/^[[:space:]]*seeds *=.*/seeds = \"$SEEDS\"/}" \
       -e "/^\[p2p\]/,/^\[/{s/^[[:space:]]*persistent_peers *=.*/persistent_peers = \"$PEERS\"/}" \
       $CONFIG/config.toml

###############################################################################
#                               SNAPSHOT                                       #
###############################################################################

if [ "$USE_SNAPSHOT" = true ]; then
    echo -e "\n📦 Installing snapshot..."
    echo "Target: $SNAPSHOT_URL"

    cp $HOME_FOLDER/data/priv_validator_state.json $HOME/priv_validator_state.backup

    $BINARY_NAME tendermint unsafe-reset-all --home $HOME_FOLDER --keep-addr-book

    curl -L $SNAPSHOT_URL | lz4 -dc - | tar -xf - -C $HOME_FOLDER

    mv $HOME/priv_validator_state.backup $HOME_FOLDER/data/priv_validator_state.json
    
    echo "✅ Snapshot installed successfully!"
else
    echo -e "\n⏭️  Skipping snapshot installation based on user choice."
fi

###############################################################################
#                           SYSTEMD SERVICE                                   #
###############################################################################

echo -e "\n🔧 Creating systemd service..."
sudo tee /etc/systemd/system/$SERVICE_NAME.service > /dev/null <<EOF
[Unit]
Description=$BINARY_NAME Node
After=network-online.target

[Service]
User=$USER
ExecStart=/usr/local/bin/$BINARY_NAME start --home $HOME/.lumera
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
