#!/bin/sh
#
# Make all Wifi networks configured on an OpenWRT router switchable
# through a MQTT command topic and publish number of connected clients
# and their mac addresses for each network; available Wifi switches
# are published using home-assistant's MQTT auto-discovery feature.
# https://github.com/lrswss/openwrt-mqtt-wifi-switch
#
# (c) 2021 Lars Wessels <software@bytebox.org>
#
# Permission is hereby granted, free of charge, to any person obtaining
# a copy of this software and associated documentation files (the
# "Software"), to deal in the Software without restriction, including
# without limitation the rights to use, copy, modify, merge, publish,
# distribute, sublicense, and/or sell copies of the Software, and to
# permit persons to whom the Software is furnished to do so, subject
# to the following conditions:
#
# The above copyright notice and this permission notice shall be included
# in all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
# OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND  NONINFRINGEMENT. IN NO EVENT SHALL
# THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR
# OTHER LIABILITY,# WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE,
# ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
# OTHER DEALINGS IN THE SOFTWARE.
#

# we need a network-config/mac-address/ssid mapping since iface wlanX might
# be assigned differently if either Wifi network is temporarily disabled
WIFI_NETWORKS="network_config_1;00:11:22:33:44:55;ssid_1 network_config_2;00:12:34:56:78:90;ssid_2"

DEVICE_NAME=$(uci get system.@system[0].hostname)
MQTT_BASE_TOPIC="wifi/$DEVICE_NAME/ssid"
MQTT_SERVER="mqtt.local"
CHECK_INTERVAL_SECS=60
MQTT_UPDATE_INTERVAL_SECS=300
LOCK=/var/run/mqtt-wifi-switch.lock


# called on HUP, INT and TERM signal
# remove lock file to terminate mqtt_switch() background jobs
cleanup() {
	rm -f $LOCK
	exit 0
}


# mqtt handler started in background to enable/disabled a Wifi access point
# first argument network config name, second ssid to be used as port of the mqtt topic
mqtt_switch() {
	local NET_CONFIG=$1
	local SSID=$2
	local WIFI_ID
	local MSG

	WIFI_ID=$(uci show wireless | grep $NET_CONFIG | cut -f1-2 -d'.')
	mosquitto_pub -r -h $MQTT_SERVER -t "$MQTT_BASE_TOPIC/$SSID/LWT" -m 'online'
	while (true)
	do
		mosquitto_sub -W 10 -h $MQTT_SERVER -t "$MQTT_BASE_TOPIC/$SSID/command" | while read MSG
		do
			MSG=$(echo $MSG | tr /A-Z/ /a-z/)
			if [ "$MSG" = "on" ]; then
				uci set ${WIFI_ID}.disabled=0
				mosquitto_pub -h $MQTT_SERVER -t "$MQTT_BASE_TOPIC/$SSID/state" \
					-m "{ \"status\": \"on\", \"clients\": 0 }"
			elif [ "$MSG" = "off" ]; then
				uci set ${WIFI_ID}.disabled=1
				mosquitto_pub -h $MQTT_SERVER -t "$MQTT_BASE_TOPIC/$SSID/state" \
					-m "{ \"status\": \"off\", \"clients\": 0 }"
			fi
			if [ "$MSG" = "on" ] || [ "$MSG" = "off" ]; then
				uci commit wireless
				/sbin/wifi reload
				sleep 10  # need to wait for Wifi radios to reload
				mosquitto_pub -h $MQTT_SERVER -t "$MQTT_BASE_TOPIC/ctrl" -m 'refresh'
			fi
		done
		if [ ! -f $LOCK ]; then
			# mark switch as offline and delete its auto-discovery settings
			mosquitto_pub -h $MQTT_SERVER -t "$MQTT_BASE_TOPIC/ctrl" -m 'exit'
			mosquitto_pub -r -h $MQTT_SERVER -t "$MQTT_BASE_TOPIC/$SSID/LWT" -m 'offline'
 			mosquitto_pub -r -h $MQTT_SERVER -t "homeassistant/switch/$DEVICE_NAME/$SSID/config" -m ''
			exit 0
		fi
	done
}


# start mqtt_switch() background job for each Wifi access point and
# publish a discovery message for home-assitant for switch auto-configuration
MAIN_IF=$(ifconfig eth0 | grep HWaddr | awk '{ print $5 }')
for NET in $WIFI_NETWORKS; do
	CONFIG=$(echo $NET | cut -f1 -d';')
	SSID=$(echo $NET | cut -f3 -d';')

	# auto-discovery for home-assistant
	mosquitto_pub -r -h $MQTT_SERVER -t "homeassistant/switch/$DEVICE_NAME/$SSID/config" \
	   -m "{ \"name\": \"wifi access point $SSID\", \"state_topic\": \"$MQTT_BASE_TOPIC/$SSID/state\", \
		\"state_off\": \"off\", \"state_on\": \"on\", \"value_template\": \"{{ value_json.status }}\", \
		\"availability_topic\": \"$MQTT_BASE_TOPIC/$SSID/LWT\", \"payload_available\": \"online\", \
		\"payload_not_available\": \"offline\", \"command_topic\": \"$MQTT_BASE_TOPIC/$SSID/command\", \
		\"device\": { \"name\": \"OpenWRT Router\", \"connections\": [[\"mac\", \"$MAIN_IF\"]] }, \
		\"unique_id\": \"switch-access-point-$SSID\", \"icon\": \"mdi:access-point\" }"
	mqtt_switch $CONFIG $SSID &
done
trap cleanup TERM INT HUP


# continously monitor the availability of all configured Wifi access points
# and publish their status along with number of currently connected clients
echo $$ > $LOCK
while (true)
do
	NOW=$(date +%s)
	NET_COUNT=0
	for NET in $WIFI_NETWORKS; do
		MAC=$(echo $NET | cut -f2 -d';')
		SSID=$(echo $NET | cut -f3 -d';')
		IFACE=$(ifconfig | grep $MAC | awk '{ print $1 }')
		LAST_UPDATE=$(eval echo \${LAST_UPDATE_${NET_COUNT}})
		LAST_STATUS=$(eval echo \${LAST_STATUS_${NET_COUNT}})

		if [ -n "$IFACE" ]; then
			ASSOC_LIST=$(iwinfo $IFACE assoclist | grep SNR | awk '{ print $1 }')
                        FREQ=$(iwinfo $IFACE info | grep 'Channel:' | awk '{ print $5 }')
			if [ -n "$(echo $FREQ | grep '2.4')" ]; then
				FREQ="2.4GHz"
			else
				FREQ="5GHz"
			fi
			COUNT=0
			if [ -n "$ASSOC_LIST" ]; then
				STATE_JSON="{ \"status\": \"on\", \"assoclist\" : { \"$FREQ\": [ "
				for MAC in $ASSOC_LIST
				do
					STATE_JSON="$STATE_JSON \"$MAC\","
					COUNT=$((COUNT+1))
				done
				STATE_JSON=$(echo $STATE_JSON | sed 's/.$/ ] },/')
				STATE_JSON="$STATE_JSON \"clients\": $COUNT }"
			else
				STATE_JSON="{ \"status\": \"on\", \"assoclist\" : { \"$FREQ\": [ ] }, \"clients\": 0 }"
			fi
			
			# simple shells like ash doesn't support arrays...
			LAST_COUNT=$(eval echo \${LAST_COUNT_${NET_COUNT}})
			if [ "$LAST_STATUS" != "online" ] || [ -z "$LAST_COUNT" ] || [ $LAST_COUNT != $COUNT ] || [ $((NOW-LAST_UPDATE)) -ge $MQTT_UPDATE_INTERVAL_SECS ]; then
				mosquitto_pub -h $MQTT_SERVER -t "$MQTT_BASE_TOPIC/$SSID/state" -m "$STATE_JSON"
				eval "LAST_COUNT_${NET_COUNT}=$COUNT"
				eval "LAST_UPDATE_${NET_COUNT}=$(date +%s)"
                                eval "LAST_STATUS_${NET_COUNT}=\"online\""
			fi
		else
			if  [ "$LAST_STATUS" != "offline" ] || [ $((NOW-LAST_UPDATE)) -ge $MQTT_UPDATE_INTERVAL_SECS ]; then
				mosquitto_pub -h $MQTT_SERVER -t "$MQTT_BASE_TOPIC/$SSID/state" \
					-m "{ \"status\": \"off\", \"clients\": 0 }"
				eval "LAST_UPDATE_${NET_COUNT}=$(date +%s)"
                                eval "LAST_STATUS_${NET_COUNT}=\"offline\""
			fi
		fi	
		NET_COUNT=$((NET_COUNT+1))
	done

	# wait for message from mqtt_switch() to trigger
	# intermediate status update or continue after timeout
	mosquitto_sub -W $CHECK_INTERVAL_SECS -C 1 -h $MQTT_SERVER -t "$MQTT_BASE_TOPIC/ctrl" >/dev/null

	[ ! -f $LOCK ] && exit 0
done
