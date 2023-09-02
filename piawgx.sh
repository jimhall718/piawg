#!/bin/sh
# script to create PIA wireguard config on Openwrt
# doesn't requre wg interface to already be there
# Moved user creds to separate file (piauser.sh), creates template if file isn't there
# Generates keypair for piauser.sh creds file.
# Region identifier in piauser.sh also, can edit and rerun to change wg peer
# saves server list to /tmp
# originated from here: https://forum.openwrt.org/t/private-internet-access-pia-wireguard-vpn-on-openwrt
piauser="./piauser.sh"
if [ ! -f "$piauser" ]; then
  echo "Error: No $piauser file."
  echo "Creating keys and writing sample $piauser file"
  PUB_KEY="yourpubkeyhere"
  PRIV_KEY="yourprivkeyhere"
  umask go= 
  wg genkey | tee wgclient.key | wg pubkey > wgclient.pub
  if [ ! -f wgclient.key ]; then
     echo "Error: Cannot create wg key.  Ensure wireguard is installed (and jq and curl)"
     exit 2
  fi
  PUB_KEY="$(cat wgclient.pub)"
  PRIV_KEY="$(cat wgclient.key)"
  echo "Edit file with your user details and try again"
  echo "Check/set firewall config"
cat << EOF > $piauser
#see https://openwrt.org/docs/guide-user/services/vpn/wireguard/client
PIA_USER=pxxxxxxx
PIA_PASS=yourpassword
PUB_KEY="${PUB_KEY}"
PRIV_KEY="${PRIV_KEY}"
selectedRegion="us_alaska-pf"
EOF
umask 0022
exit 1
fi
. ./piauser.sh
VPN_IF="wg0_pia"
serverlist_url='https://serverlist.piaservers.net/vpninfo/servers/v6'
all_region_data="$(curl -s $serverlist_url | head -1 )"
echo "save server list"
echo $all_region_data | jq > /tmp/pia-server-list
echo "get all_region"
# Get all region data
#all_region_data=$(curl -s "$serverlist_url" | head -1)
regionData="$( echo "$all_region_data" |
  jq --arg REGION_ID "$selectedRegion" -r \
  '.regions[] | select(.id==$REGION_ID)')"
#echo "all region = $all_region_data" 
echo "print ip"
WG_SERVER_IP=$(echo "$regionData" | jq -r '.servers.wg[0].ip')
WG_HOSTNAME=$(echo "$regionData" | jq -r '.servers.wg[0].cn')
 
echo $WG_SERVER_IP
echo $WG_HOSTNAME
 
TOKEN_RES=$(curl -s --location --request POST \
  'https://www.privateinternetaccess.com/api/client/v2/token' \
  --form "username=$PIA_USER" \
  --form "password=$PIA_PASS" )
TOKEN=`echo $TOKEN_RES | jq -r '.token'`
 
echo "$TOKEN"
echo "${#TOKEN}"
 
if [ ${#TOKEN} != 128 ]; then
  echo "Couldn't get token"
  exit
else
  echo "Got token"
fi
 
wireguard_json=`curl -k -G --data-urlencode "pt=${TOKEN}" --data-urlencode "pubkey=$PUB_KEY" "https://${WG_SERVER_IP}:1337/addKey"`
 
echo $wireguard_json
 
dnsServer=$(echo "$wireguard_json" | jq -r '.dns_servers[0]')
dnsServer2=$(echo "$wireguard_json" | jq -r '.dns_servers[1]')
dnsSettingForVPN="DNS = $dnsServer"
 
VPN_ADDR=$(echo "$wireguard_json" | jq -r '.peer_ip')
VPN_PORT=$(echo "$wireguard_json" | jq -r '.server_port')
VPN_PUB=$(echo "$wireguard_json" | jq -r '.server_key')
echo "VPN_IF $VPN_IF"
echo "VPN_ADDR $VPN_ADDR"
echo "VPN_PORT $VPN_PORT"
echo "VPN_PUB $VPN_PUB"

echo "set wg info"
uci -q delete network.${VPN_IF}
uci set network.${VPN_IF}=interface 
uci set network.${VPN_IF}.addresses="${VPN_ADDR}"
uci set network.${VPN_IF}.proto="wireguard"
uci set network.${VPN_IF}.private_key="$PRIV_KEY"
uci add_list network.${VPN_IF}.dns="$dnsServer"
uci add_list network.${VPN_IF}.dns="$dnsServer2"

uci -q delete network.wgserver
uci set network.wgserver="wireguard_${VPN_IF}"
uci set network.wgserver.description="$selectedRegion-$WG_HOSTNAME"
uci set network.wgserver.route_allowed_ips="1"
uci set network.wgserver.persistent_keepalive="25"
uci add_list network.wgserver.allowed_ips="::/0"
uci add_list network.wgserver.allowed_ips="0.0.0.0/0"
uci set network.wgserver="wireguard_${VPN_IF}"
uci set network.wgserver.endpoint_host="${WG_SERVER_IP}"
uci set network.wgserver.endpoint_port="${VPN_PORT}"
uci set network.wgserver.public_key="${VPN_PUB}"
uci commit
ifdown ${VPN_IF}
ifup ${VPN_IF}

echo "Networking Config"
uci show network.${VPN_IF}
uci show network.wgserver 
echo "Wireguard status"
sleep 1 
wg show
echo "done"
