#!/bin/sh
set +e
DEV=/dev/cdc-wdm0
IF=wwan0
APN='internet.proximus.be'
#APN='globaldata'
APN=$(uci get network.wan.apn)

echo "APN=$APN"

CID=$(uqmi -d $DEV --get-client-id wds)
echo "Client ID: $CID"

echo "Saved profile 1:"
uqmi -d $DEV --set-client-id wds,$CID --get-profile-settings 3gpp,1


uqmi -d $DEV --set-client-id wds,$CID --modify-profile 3gpp,1 --apn $APN
uqmi -d $DEV --set-client-id wds,$CID --set-ip-family ipv4
uqmi -d $DEV --set-client-id wds,$CID --start-network --profile 1
uqmi -d $DEV --set-client-id wds,$CID --get-data-status
uqmi -d $DEV --set-client-id wds,$CID --get-current-settings |tee  /tmp/wan-settings.json

ip=$(jq -r '.ipv4.ip' < /tmp/wan-settings.json)
gw=$(jq -r '.ipv4.gateway' < /tmp/wan-settings.json)
mask=$(jq -r '.ipv4.subnet' < /tmp/wan-settings.json)

count=0
OLDIFS=$IFS; IFS=.
set -- $mask
IFS=$OLDIFS

for oct in "$1" "$2" "$3" "$4"; do
  v=$oct
  i=0
  while [ "$i" -lt 8 ]; do
    if [ $((v & 128)) -ne 0 ]; then
      count=$((count + 1))
    fi
    v=$(( (v << 1) & 255 ))
    i=$((i + 1))
  done
done


ip link set wwan0 up
ip addr flush dev wwan0
ip addr add $ip/$count dev wwan0
ip route replace default via $gw dev wwan0

dns1=$(jq -r '.ipv4.dns1' < /tmp/wan-settings.json)
dns2=$(jq -r '.ipv4.dns2' < /tmp/wan-settings.json)

printf "nameserver $dns1\nnameserver $dns2\n" > /tmp/resolv.conf

uqmi -d $DEV --release-client-id wds
