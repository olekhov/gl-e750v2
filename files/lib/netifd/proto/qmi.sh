#!/bin/sh

[ -n "$INCLUDE_ONLY" ] || {
	. /lib/functions.sh
	. ../netifd-proto.sh
	init_proto "$@"
}

qmi_json_get() {
	local payload="$1"
	local expr="$2"

	[ -n "$payload" ] || return 1
	printf '%s' "$payload" | jsonfilter -e "$expr" 2>/dev/null
}

qmi_wait_for_ipv4_settings() {
	local device="$1"
	local cid="$2"
	local timeout="${3:-10}"
	local elapsed=0
	local settings ip gateway

	while [ "$elapsed" -lt "$timeout" ]; do
		settings="$(uqmi -s -d "$device" -t 1000 --set-client-id wds,"$cid" --get-current-settings 2>/dev/null)"
		ip="$(qmi_json_get "$settings" '@.ipv4.ip')"
		gateway="$(qmi_json_get "$settings" '@.ipv4.gateway')"

		if [ -n "$ip" ] && [ -n "$gateway" ]; then
			printf '%s' "$settings"
			return 0
		fi

		elapsed=$((elapsed + 1))
		sleep 1
	done

	return 1
}

qmi_wait_for_ipv6_settings() {
	local device="$1"
	local cid="$2"
	local timeout="${3:-10}"
	local elapsed=0
	local settings ip gateway

	while [ "$elapsed" -lt "$timeout" ]; do
		settings="$(uqmi -s -d "$device" -t 1000 --set-client-id wds,"$cid" --set-ip-family ipv6 --get-current-settings 2>/dev/null)"
		ip="$(qmi_json_get "$settings" '@.ipv6.ip')"
		gateway="$(qmi_json_get "$settings" '@.ipv6.gateway')"

		if [ -n "$ip" ] && [ -n "$gateway" ]; then
			printf '%s' "$settings"
			return 0
		fi

		elapsed=$((elapsed + 1))
		sleep 1
	done

	return 1
}

qmi_qmicli_ip_type() {
	case "$1" in
		ip|ipv4)
			printf '4'
			;;
		ipv6)
			printf '6'
			;;
		ipv4v6)
			printf '4'
			;;
		*)
			printf '4'
			;;
	esac
}

qmi_qmicli_start_network() {
	local device="$1"
	local apn="$2"
	local ip_type="$3"
	local profile="$4"
	local auth="$5"
	local username="$6"
	local password="$7"
	local roaming="$8"
	local cmd_args output cid pdh

	command -v qmicli >/dev/null 2>&1 || return 1

	cmd_args="ip-type=$(qmi_qmicli_ip_type "$ip_type")"
	[ -n "$apn" ] && cmd_args="apn=$apn,$cmd_args"
	[ -n "$profile" ] && cmd_args="3gpp-profile=$profile,$cmd_args"

	case "$auth" in
		pap|chap|both|PAP|CHAP|BOTH|none|NONE)
			cmd_args="$cmd_args,auth=${auth}"
			;;
	esac

	[ -n "$username" ] && cmd_args="$cmd_args,username=$username"
	[ -n "$password" ] && cmd_args="$cmd_args,password=$password"

	if [ -n "$roaming" ] && [ "$roaming" != "0" ]; then
		echo "qmicli fallback: roaming is enabled in UCI; relying on modem registration state"
	fi

	output="$(qmicli -d "$device" --device-open-proxy --wds-start-network="$cmd_args" --client-no-release-cid 2>&1)" || {
		echo "qmicli fallback start-network failed: $output"
		return 1
	}

	cid="$(printf '%s\n' "$output" | sed -n "s/.*CID: '\([0-9]\+\)'.*/\1/p" | tail -n1)"
	pdh="$(printf '%s\n' "$output" | sed -n "s/.*Packet data handle: '\([0-9]\+\)'.*/\1/p" | tail -n1)"

	if [ -z "$cid" ] || [ -z "$pdh" ]; then
		echo "qmicli fallback returned unexpected payload: $output"
		return 1
	fi

	echo "qmicli fallback obtained CID $cid and handle $pdh"
	printf '%s;%s\n' "$cid" "$pdh"
}

proto_qmi_init_config() {
	available=1
	no_device=1
	proto_config_add_string "device:device"
	proto_config_add_string apn
	proto_config_add_string v6apn
	proto_config_add_string auth
	proto_config_add_string username
	proto_config_add_string password
	proto_config_add_string pincode
	proto_config_add_int delay
	proto_config_add_string modes
	proto_config_add_string pdptype
	proto_config_add_int profile
	proto_config_add_int v6profile
	proto_config_add_string devpath
	proto_config_add_boolean dhcp
	proto_config_add_boolean dhcpv6
	proto_config_add_boolean sourcefilter
	proto_config_add_boolean delegate
	proto_config_add_boolean autoconnect
	proto_config_add_boolean roaming
	proto_config_add_int plmn
	proto_config_add_int timeout
	proto_config_add_int mtu
	proto_config_add_defaults
}

proto_qmi_setup() {
	local interface="$1"

	local connstat dataformat mcc mnc plmn_mode
	local cid_4 cid_6 pdh_4 pdh_6
	local dns1_4 dns2_4 dns1_6 dns2_6
	local gateway_4 gateway_6 ip_4 ip_6
	local ip_prefix_length subnet_4
	local profile_pdptype
	local current_settings_4 current_settings_6
	local uim_state_raw pin_status_raw card_application_state
	local pin1_status pin1_verify_tries
	local registration_state registration_soft_fail

	local delegate ip4table ip6table mtu sourcefilter $PROTO_DEFAULT_OPTIONS
	json_get_vars delegate ip4table ip6table mtu sourcefilter $PROTO_DEFAULT_OPTIONS

	local apn auth delay device modes password pdptype pincode username v6apn
	json_get_vars apn auth delay device modes password pdptype pincode username v6apn

	local profile v6profile devpath dhcp dhcpv6 autoconnect roaming plmn timeout
	json_get_vars profile v6profile devpath dhcp dhcpv6 autoconnect roaming plmn timeout

	[ "$timeout" = "" ] && timeout="30"

	[ "$metric" = "" ] && metric="0"

	[ -n "$ctl_device" ] && device=$ctl_device

	if [ -n "$devpath" ]; then
		local usbmisc_or_wwan_path
		for usbmisc_or_wwan_path in \
		    "$devpath"/usbmisc/cdc-wdm* \
		    "$devpath"/*/usbmisc/cdc-wdm* \
		    "$devpath"/*/wwan[0-9]*/wwan[0-9]*qmi* \
		    "$devpath"/*/*/wwan[0-9]*/wwan[0-9]*qmi*; do
			[ ! -e "$usbmisc_or_wwan_path" ] && continue
			device="/dev/${usbmisc_or_wwan_path##*/}"
			break
		done
	fi

	[ -n "$device" ] || {
		echo "No control device specified"
		proto_notify_error "$interface" NO_DEVICE
		proto_set_available "$interface" 0
		return 1
	}

	[ -n "$delay" ] && sleep "$delay"

	device="$(readlink -f "$device")"
	[ -c "$device" ] || {
		echo "The specified control device does not exist"
		proto_notify_error "$interface" NO_DEVICE
		proto_set_available "$interface" 0
		return 1
	}

	devname="$(basename "$device")"
	devpath="$(readlink -f /sys/class/usbmisc/$devname/device/)"
	ifname="$(ls "$devpath"/net)"
	[ -n "$ifname" ] || {
		echo "The interface could not be found."
		proto_notify_error "$interface" NO_IFACE
		proto_set_available "$interface" 0
		return 1
	}

	[ -n "$mtu" ] && {
		echo "Setting MTU to $mtu"
		/sbin/ip link set dev "$ifname" mtu "$mtu"
	}

	echo "Waiting for SIM initialization"
	local uninitialized_timeout=0
	uqmi -d "$device" -t 3000 --get-pin-status > /dev/null 2>&1
	while uqmi -s -d "$device" -t 1000 --get-pin-status | grep '"UIM uninitialized"' > /dev/null; do
		[ -e "$device" ] || return 1
		if [ "$uninitialized_timeout" -lt "$timeout" ] || [ "$timeout" = "0" ]; then
			uninitialized_timeout=$((uninitialized_timeout + 1))
			sleep 1
		else
			echo "SIM not initialized"
			proto_notify_error "$interface" SIM_NOT_INITIALIZED
			proto_block_restart "$interface"
			return 1
		fi
	done

	local uim_state_timeout=0
	while true; do
		uim_state_raw="$(uqmi -s -d "$device" -t 2000 --uim-get-sim-state 2>/dev/null)"
		card_application_state="$(qmi_json_get "$uim_state_raw" '@.card_application_state')"

		if [ -z "$card_application_state" ]; then
			echo "uqmi --uim-get-sim-state returned unexpected payload: ${uim_state_raw:-<empty>}"
		fi

		if [ -z "$card_application_state" ] || [ "$card_application_state" = "illegal" ]; then
			echo "SIM in illegal state - Power-cycling SIM"
			uqmi -d "$device" -t 1000 --uim-power-off --uim-slot 1
			sleep 3
			uqmi -d "$device" -t 1000 --uim-power-on --uim-slot 1

			if [ "$uim_state_timeout" -lt "$timeout" ] || [ "$timeout" = "0" ]; then
				uim_state_timeout=$((uim_state_timeout + 1))
				sleep 5
				continue
			fi

			proto_notify_error "$interface" SIM_ILLEGAL_STATE
			proto_block_restart "$interface"
			return 1
		else
			break
		fi
	done

	if uqmi -s -d "$device" -t 1000 --uim-get-sim-state | grep -q '"Not supported"\|"Invalid QMI command"' &&
	   uqmi -s -d "$device" -t 1000 --get-pin-status | grep -q '"Not supported"\|"Invalid QMI command"' ; then
		[ -n "$pincode" ] && {
			uqmi -s -d "$device" -t 1000 --verify-pin1 "$pincode" > /dev/null || uqmi -s -d "$device" -t 1000 --uim-verify-pin1 "$pincode" > /dev/null || {
				echo "Unable to verify PIN"
				proto_notify_error "$interface" PIN_FAILED
				proto_block_restart "$interface"
				return 1
			}
		}
	else
		pin_status_raw="$(uqmi -s -d "$device" -t 1000 --get-pin-status 2>/dev/null)"
		pin1_status="$(qmi_json_get "$pin_status_raw" '@.pin1_status')"
		pin1_verify_tries="$(qmi_json_get "$pin_status_raw" '@.pin1_verify_tries')"
		if [ -z "$pin1_status" ]; then
			uim_state_raw="$(uqmi -s -d "$device" -t 1000 --uim-get-sim-state 2>/dev/null)"
			pin1_status="$(qmi_json_get "$uim_state_raw" '@.pin1_status')"
			[ -z "$pin1_verify_tries" ] && pin1_verify_tries="$(qmi_json_get "$uim_state_raw" '@.pin1_verify_tries')"
		fi
		if [ -z "$pin1_status" ]; then
			echo "Unable to extract pin status (get-pin-status: ${pin_status_raw:-<empty>}; uim-get-sim-state: ${uim_state_raw:-<empty>})"
		fi

		case "$pin1_status" in
			disabled)
				echo "PIN verification is disabled"
				;;
			blocked)
				echo "SIM locked PUK required"
				proto_notify_error "$interface" PUK_NEEDED
				proto_block_restart "$interface"
				return 1
				;;
			not_verified)
				[ "$pin1_verify_tries" -lt "3" ] && {
					echo "PIN verify count value is $pin1_verify_tries this is below the limit of 3"
					proto_notify_error "$interface" PIN_TRIES_BELOW_LIMIT
					proto_block_restart "$interface"
					return 1
				}
				if [ -n "$pincode" ]; then
					uqmi -s -d "$device" -t 1000 --verify-pin1 "$pincode" > /dev/null 2>&1 || uqmi -s -d "$device" -t 1000 --uim-verify-pin1 "$pincode" > /dev/null 2>&1 || {
						echo "Unable to verify PIN"
						proto_notify_error "$interface" PIN_FAILED
						proto_block_restart "$interface"
						return 1
					}
				else
					echo "PIN not specified but required"
					proto_notify_error "$interface" PIN_NOT_SPECIFIED
					proto_block_restart "$interface"
					return 1
				fi
				;;
			verified)
				echo "PIN already verified"
				;;
			*)
				echo "PIN status failed (${pin1_status:-sim_not_present})"
				proto_notify_error "$interface" PIN_STATUS_FAILED
				proto_block_restart "$interface"
				return 1
			;;
		esac
	fi

	if [ -n "$plmn" ]; then
		json_load "$(uqmi -s -d "$device" -t 1000 --get-plmn)"
		json_get_var plmn_mode mode
		json_get_vars mcc mnc || {
			mcc=0
			mnc=0
		}

		if [ "$plmn" = "0" ]; then
			if [ "$plmn_mode" != "automatic" ]; then
				mcc=0
				mnc=0
				echo "Setting PLMN to auto"
			fi
		elif [ "$mcc" -ne "${plmn:0:3}" ] || [ "$mnc" -ne "${plmn:3}" ]; then
			mcc=${plmn:0:3}
			mnc=${plmn:3}
			echo "Setting PLMN to $plmn"
		else
			mcc=""
			mnc=""
		fi
	fi

	uqmi -s -d "$device" -t 1000 --stop-network 0xffffffff --autoconnect > /dev/null 2>&1
	uqmi -s -d "$device" -t 1000 --set-ip-family ipv6 --stop-network 0xffffffff --autoconnect > /dev/null 2>&1

	uqmi -s -d "$device" -t 1000 --set-device-operating-mode online > /dev/null 2>&1

	uqmi -s -d "$device" -t 1000 --set-data-format 802.3 > /dev/null 2>&1
	uqmi -s -d "$device" -t 1000 --wda-set-data-format 802.3 > /dev/null 2>&1
	json_load "$(uqmi -s -d "$device" -t 1000 --wda-get-data-format)"
	json_get_var dataformat link-layer-protocol

	if [ "$dataformat" = "raw-ip" ]; then
		[ -f /sys/class/net/$ifname/qmi/raw_ip ] || {
			echo "Device only supports raw-ip mode but is missing this required driver attribute: /sys/class/net/$ifname/qmi/raw_ip"
			return 1
		}

		echo "Device does not support 802.3 mode. Informing driver of raw-ip only for $ifname .."
		echo "Y" > /sys/class/net/$ifname/qmi/raw_ip
	fi

	uqmi -s -d "$device" -t 1000 --sync > /dev/null 2>&1

	if [ -n "$mcc" ] && [ -n "$mnc" ]; then
		uqmi -s -d "$device" -t 1000 --set-plmn --mcc "$mcc" --mnc "$mnc" > /dev/null 2>&1 || {
			echo "Unable to set PLMN"
			proto_notify_error "$interface" PLMN_FAILED
			proto_block_restart "$interface"
			return 1
		}
	fi

	[ -n "$modes" ] && {
		uqmi -s -d "$device" -t 1000 --set-network-modes "$modes" > /dev/null 2>&1
		sleep 3
		uqmi -s -d "$device" -t 30000 --network-scan > /dev/null 2>&1
	}

	serving_system="$(uqmi -s -d "$device" -t 1000 --get-serving-system 2>/dev/null)"
	registration_state="$(echo "$serving_system" | jsonfilter -e "@.registration" 2>/dev/null)"
	case "$registration_state" in
		registered)
			echo "Modem is already registered"
			;;
		searching)
			echo "Modem is already searching for a network"
			;;
		*)
			echo "Requesting network registration"
			uqmi -s -d "$device" -t 20000 --network-register > /dev/null 2>&1
			;;
	esac

	echo "Waiting for network registration"
	sleep 5
	local registration_timeout=0
	registration_soft_fail=""
	while true; do
		serving_system="$(uqmi -s -d "$device" -t 1000 --get-serving-system 2>/dev/null)"
		registration_state=$(echo "$serving_system" | jsonfilter -e "@.registration" 2>/dev/null)

		[ "$serving_system" = "\"Invalid QMI command\"" ] && break
		[ "$registration_state" = "registered" ] && break

		if [ "$registration_state" = "searching" ] || [ "$registration_state" = "not_registered" ] || [ -z "$registration_state" ] || [ "$registration_state" = "unknown" ]; then
			if [ "$registration_timeout" -lt "$timeout" ] || [ "$timeout" = "0" ]; then
				[ $((registration_timeout % 5)) -eq 0 ] && [ -n "$serving_system" ] && echo "Serving system payload while waiting: $serving_system"
				registration_timeout=$((registration_timeout + 1))
				sleep 1
				continue
			fi
			echo "Network registration did not settle before timeout; trying to start data session anyway"
			registration_soft_fail="timeout"
			break
		else
			echo "Network registration returned '$registration_state'; trying to start data session anyway"
			[ -n "$serving_system" ] && echo "Serving system payload: $serving_system"
			registration_soft_fail="$registration_state"
			break
		fi
	done

	echo "Starting network $interface"

	pdptype="$(echo "$pdptype" | awk '{print tolower($0)}')"
	[ "$pdptype" = "ip" ] || [ "$pdptype" = "ipv6" ] || [ "$pdptype" = "ipv4v6" ] || pdptype="ip"

	profile_pdptype="$pdptype"
	[ "$profile_pdptype" = "ip" ] && profile_pdptype="ipv4"
	uqmi -s -d "$device" -t 1000 --modify-profile "3gpp,1" --apn "$apn" --pdp-type "$profile_pdptype" > /dev/null 2>&1

	if [ "$pdptype" = "ip" ]; then
		[ -z "$autoconnect" ] && autoconnect=1
		[ "$autoconnect" = 0 ] && autoconnect=""
	else
		[ "$autoconnect" = 1 ] || autoconnect=""
	fi

	[ "$pdptype" = "ip" ] || [ "$pdptype" = "ipv4v6" ] && {
		local qmicli_fallback_4=""

		cid_4=$(uqmi -s -d "$device" -t 1000 --get-client-id wds)
		if ! [ "$cid_4" -eq "$cid_4" ] 2>/dev/null; then
			echo "Unable to obtain client ID"
			proto_notify_error "$interface" NO_CID
			return 1
		fi

		echo "Using IPv4 WDS client ID $cid_4"
		uqmi -s -d "$device" -t 1000 --set-client-id wds,"$cid_4" --set-ip-family ipv4 > /dev/null 2>&1

		pdh_4=$(uqmi -s -d "$device" -t 30000 --set-client-id wds,"$cid_4" \
			--start-network \
			${apn:+--apn $apn} \
			${profile:+--profile $profile} \
			${auth:+--auth-type $auth} \
			${username:+--username $username} \
			${password:+--password $password} \
			${autoconnect:+--autoconnect} \
			${roaming:+--set-network-roaming any})

		if ! [ "$pdh_4" -eq "$pdh_4" ] 2>/dev/null; then
			echo "uqmi IPv4 start-network failed (result: ${pdh_4:-<empty>}); trying qmicli fallback"
			uqmi -s -d "$device" -t 1000 --set-client-id wds,"$cid_4" --release-client-id wds > /dev/null 2>&1
			qmicli_fallback_4="$(qmi_qmicli_start_network "$device" "$apn" "ip" "$profile" "$auth" "$username" "$password" "$roaming")" || {
				echo "Unable to connect IPv4 via uqmi or qmicli fallback"
				proto_notify_error "$interface" CALL_FAILED
				return 1
			}
			cid_4="${qmicli_fallback_4%;*}"
			pdh_4="${qmicli_fallback_4#*;}"
		fi

		echo "IPv4 start-network returned handle $pdh_4"
		connstat=$(uqmi -s -d "$device" -t 1000 --set-client-id wds,"$cid_4" --get-data-status 2>/dev/null)
		current_settings_4="$(qmi_wait_for_ipv4_settings "$device" "$cid_4" 10 || true)"
		ip_4="$(qmi_json_get "$current_settings_4" '@.ipv4.ip')"
		gateway_4="$(qmi_json_get "$current_settings_4" '@.ipv4.gateway')"

		if [ "$connstat" != '"connected"' ]; then
			if [ -n "$ip_4" ] && [ -n "$gateway_4" ]; then
				echo "IPv4 data-status is ${connstat:-<empty>} but current-settings reports $ip_4 via $gateway_4; continuing"
			else
				echo "No IPv4 data link (data-status: ${connstat:-<empty>})"
				[ -n "$current_settings_4" ] && echo "IPv4 current-settings payload: $current_settings_4"
				uqmi -s -d "$device" -t 1000 --set-client-id wds,"$cid_4" --release-client-id wds > /dev/null 2>&1
				proto_notify_error "$interface" CALL_FAILED
				return 1
			fi
		fi

		[ -n "$registration_soft_fail" ] && {
			echo "IPv4 session is up despite registration state '${registration_soft_fail}'"
			registration_soft_fail=""
		}
	}

	[ "$pdptype" = "ipv6" ] || [ "$pdptype" = "ipv4v6" ] && {
		local qmicli_fallback_6=""

		cid_6=$(uqmi -s -d "$device" -t 1000 --get-client-id wds)
		if ! [ "$cid_6" -eq "$cid_6" ] 2>/dev/null; then
			echo "Unable to obtain client ID"
			proto_notify_error "$interface" NO_CID
			return 1
		fi

		echo "Using IPv6 WDS client ID $cid_6"
		uqmi -s -d "$device" -t 1000 --set-client-id wds,"$cid_6" --set-ip-family ipv6 > /dev/null 2>&1

		: "${v6apn:=${apn}}"
		: "${v6profile:=${profile}}"

		pdh_6=$(uqmi -s -d "$device" -t 30000 --set-client-id wds,"$cid_6" \
			--start-network \
			${v6apn:+--apn $v6apn} \
			${v6profile:+--profile $v6profile} \
			${auth:+--auth-type $auth} \
			${username:+--username $username} \
			${password:+--password $password} \
			${autoconnect:+--autoconnect} \
			${roaming:+--set-network-roaming any})

		if ! [ "$pdh_6" -eq "$pdh_6" ] 2>/dev/null; then
			echo "uqmi IPv6 start-network failed (result: ${pdh_6:-<empty>}); trying qmicli fallback"
			uqmi -s -d "$device" -t 1000 --set-client-id wds,"$cid_6" --release-client-id wds > /dev/null 2>&1
			qmicli_fallback_6="$(qmi_qmicli_start_network "$device" "$v6apn" "ipv6" "$v6profile" "$auth" "$username" "$password" "$roaming")" || {
				echo "Unable to connect IPv6 via uqmi or qmicli fallback"
				proto_notify_error "$interface" CALL_FAILED
				return 1
			}
			cid_6="${qmicli_fallback_6%;*}"
			pdh_6="${qmicli_fallback_6#*;}"
		fi

		echo "IPv6 start-network returned handle $pdh_6"
		connstat=$(uqmi -s -d "$device" -t 1000 --set-client-id wds,"$cid_6" --set-ip-family ipv6 --get-data-status 2>/dev/null)
		current_settings_6="$(qmi_wait_for_ipv6_settings "$device" "$cid_6" 10 || true)"
		ip_6="$(qmi_json_get "$current_settings_6" '@.ipv6.ip')"
		gateway_6="$(qmi_json_get "$current_settings_6" '@.ipv6.gateway')"

		if [ "$connstat" != '"connected"' ]; then
			if [ -n "$ip_6" ] && [ -n "$gateway_6" ]; then
				echo "IPv6 data-status is ${connstat:-<empty>} but current-settings reports $ip_6 via $gateway_6; continuing"
			else
				echo "No IPv6 data link (data-status: ${connstat:-<empty>})"
				[ -n "$current_settings_6" ] && echo "IPv6 current-settings payload: $current_settings_6"
				uqmi -s -d "$device" -t 1000 --set-client-id wds,"$cid_6" --release-client-id wds > /dev/null 2>&1
				proto_notify_error "$interface" CALL_FAILED
				return 1
			fi
		fi
	}

	echo "Setting up $ifname"
	proto_init_update "$ifname" 1
	proto_set_keep 1
	proto_add_data
	[ -n "$pdh_4" ] && {
		json_add_string "cid_4" "$cid_4"
		json_add_string "pdh_4" "$pdh_4"
	}
	[ -n "$pdh_6" ] && {
		json_add_string "cid_6" "$cid_6"
		json_add_string "pdh_6" "$pdh_6"
	}
	proto_close_data
	proto_send_update "$interface"

	local zone="$(fw3 -q network "$interface" 2>/dev/null)"

	[ -n "$pdh_6" ] && {
		if [ -z "$dhcpv6" ] || [ "$dhcpv6" = 0 ]; then
			[ -n "$current_settings_6" ] || current_settings_6="$(uqmi -s -d "$device" -t 1000 --set-client-id wds,"$cid_6" --get-current-settings)"
			json_load "$current_settings_6"
			json_select ipv6
			json_get_var ip_6 ip
			json_get_var gateway_6 gateway
			json_get_var dns1_6 dns1
			json_get_var dns2_6 dns2
			json_get_var ip_prefix_length ip-prefix-length

			proto_init_update "$ifname" 1
			proto_set_keep 1
			proto_add_ipv6_address "$ip_6" "128"
			proto_add_ipv6_prefix "${ip_6}/${ip_prefix_length}"
			proto_add_ipv6_route "$gateway_6" "128"
			[ "$defaultroute" = 0 ] || proto_add_ipv6_route "::0" 0 "$gateway_6" "" "" "${ip_6}/${ip_prefix_length}"
			[ "$peerdns" = 0 ] || {
				proto_add_dns_server "$dns1_6"
				proto_add_dns_server "$dns2_6"
			}
			[ -n "$zone" ] && {
				proto_add_data
				json_add_string zone "$zone"
				proto_close_data
			}
			proto_send_update "$interface"
		else
			json_init
			json_add_string name "${interface}_6"
			json_add_string ifname "@$interface"
			[ "$pdptype" = "ipv4v6" ] && json_add_string iface_464xlat "0"
			json_add_string proto "dhcpv6"
			[ -n "$ip6table" ] && json_add_string ip6table "$ip6table"
			proto_add_dynamic_defaults
			json_add_string extendprefix 1
			[ "$delegate" = "0" ] && json_add_boolean delegate "0"
			[ "$sourcefilter" = "0" ] && json_add_boolean sourcefilter "0"
			[ -n "$zone" ] && json_add_string zone "$zone"
			json_close_object
			ubus call network add_dynamic "$(json_dump)"
		fi
	}

	[ -n "$pdh_4" ] && {
		if [ "$dhcp" = 0 ]; then
			[ -n "$current_settings_4" ] || current_settings_4="$(uqmi -s -d "$device" -t 1000 --set-client-id wds,"$cid_4" --get-current-settings)"
			json_load "$current_settings_4"
			json_select ipv4
			json_get_var ip_4 ip
			json_get_var gateway_4 gateway
			json_get_var dns1_4 dns1
			json_get_var dns2_4 dns2
			json_get_var subnet_4 subnet

			proto_init_update "$ifname" 1
			proto_set_keep 1
			proto_add_ipv4_address "$ip_4" "$subnet_4"
			proto_add_ipv4_route "$gateway_4" "128"
			[ "$defaultroute" = 0 ] || proto_add_ipv4_route "0.0.0.0" 0 "$gateway_4"
			[ "$peerdns" = 0 ] || {
				proto_add_dns_server "$dns1_4"
				proto_add_dns_server "$dns2_4"
			}
			[ -n "$zone" ] && {
				proto_add_data
				json_add_string zone "$zone"
				proto_close_data
			}
			proto_send_update "$interface"
		else
			json_init
			json_add_string name "${interface}_4"
			json_add_string ifname "@$interface"
			json_add_string proto "dhcp"
			[ -n "$ip4table" ] && json_add_string ip4table "$ip4table"
			proto_add_dynamic_defaults
			[ -n "$zone" ] && json_add_string zone "$zone"
			json_close_object
			ubus call network add_dynamic "$(json_dump)"
		fi
	}
}

qmi_wds_stop() {
	local cid="$1"
	local pdh="$2"

	[ -n "$cid" ] || return

	uqmi -s -d "$device" -t 1000 --set-client-id wds,"$cid" \
		--stop-network 0xffffffff \
		--autoconnect > /dev/null 2>&1

	[ -n "$pdh" ] && {
		uqmi -s -d "$device" -t 1000 --set-client-id wds,"$cid" \
			--stop-network "$pdh" > /dev/null 2>&1
	}

	uqmi -s -d "$device" -t 1000 --set-client-id wds,"$cid" \
		--release-client-id wds > /dev/null 2>&1
}

proto_qmi_teardown() {
	local interface="$1"

	local device devpath cid_4 pdh_4 cid_6 pdh_6
	json_get_vars device devpath

	[ -n "$ctl_device" ] && device=$ctl_device

	if [ -n "$devpath" ]; then
		local usbmisc_or_wwan_path
		for usbmisc_or_wwan_path in \
		    "$devpath"/usbmisc/cdc-wdm* \
		    "$devpath"/*/usbmisc/cdc-wdm* \
		    "$devpath"/*/wwan[0-9]*/wwan[0-9]*qmi* \
		    "$devpath"/*/*/wwan[0-9]*/wwan[0-9]*qmi*; do
			device="/dev/${usbmisc_or_wwan_path##*/}"
		done
	fi

	echo "Stopping network $interface"

	json_load "$(ubus call network.interface.$interface status)"
	json_select data
	json_get_vars cid_4 pdh_4 cid_6 pdh_6

	qmi_wds_stop "$cid_4" "$pdh_4"
	qmi_wds_stop "$cid_6" "$pdh_6"

	proto_init_update "*" 0
	proto_send_update "$interface"
}

[ -n "$INCLUDE_ONLY" ] || {
	add_protocol qmi
}
