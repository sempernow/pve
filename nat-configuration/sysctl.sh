#!/usr/bin/env bash
# Okay to replace interface stanza: "post-up   echo 1 > /proc/sys/net/ipv4/ip_forward",
# with this sysctl setting, which *also* persists; survives reboot.
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.d/99-forwarding.conf
sysctl -p /etc/sysctl.d/99-forwarding.conf