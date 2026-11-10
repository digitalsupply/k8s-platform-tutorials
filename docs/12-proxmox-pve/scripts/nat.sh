#!/bin/bash
# 开启转发
echo 1 > /proc/sys/net/ipv4/ip_forward
iptables -t nat -A POSTROUTING -s 10.0.0.0/24 -o vmbr0 -j MASQUERADE
iptables -t nat -A POSTROUTING -s 172.16.0.0/16 -o vmbr0 -j MASQUERADE

