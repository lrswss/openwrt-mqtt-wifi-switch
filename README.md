# Make OpenWRT Wifi networks switchable with MQTT

Shell script written for OpenWRT routers to make Wifi networks switchable
through a MQTT command topic. It also continuously publishes the number of
connected clients and their mac addresses for each Wifi network. For an
easy intergration into home-assistant all available Wifi network switches
are published using the MQTT auto-discovery feature.

## Installation

Configure `WIFI_NETWORKS`, `DEVICE_NAME`, `MQTT_SERVER` and `MQTT_BASE_TOPIC`
according to your setup and install the `mosquitto-client-nossl` package with
`opkg` on your OpenWRT router. Copy the script `mqtt-wifi-switch.sh` to `/bin`
and the init script `mqtt-wifi-switch.init` to `/etc/init.d/mqtt-wifi-switch`
on your router and start the service with `/etc/init.d/mqtt-wifi-switch enable`
and `/etc/init.d/mqtt-wifi-switch start`. For each configured Wifi network you
should now see a new switch entity in your home-assistant instance (make sure
MQTT discovery is turned on). The number of currently connected clients to
a Wifi network is published with the attribute `clients` and their mac
addresses with `assoclist` as part of the SSIDs corresponding `state` topic.

## Security considerations

You might have noticed that all MQTT communications are neither secured with
username/password or encrypted. This rather insecure setup is suitable for
my setup (seperate and firewalled network for all IoT devices) but your millage
may vary. Feel free to add either MQTT authentication or TLS encryption.

## Contributing

Pull requests are welcome! For major changes, please open an issue first
to discuss what you would like to change.

## License

Copyright (c) 2021 Lars Wessels  
This software was published under the MIT license.  
Please check the [license file](LICENSE).
