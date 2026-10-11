#!/bin/bash

cp /data/on_boot.d/customipv6.conf /run/dnsmasq.dhcp.conf.d/customipv6.conf
killall -HUP dnsmasq
