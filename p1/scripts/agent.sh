#!/bin/bash

NODE_IP="192.168.56.111"
SERVER_IP="192.168.56.110"
PRIVATE_IFACE="$(ip -o -4 addr show | grep "${NODE_IP}" | awk '{print $2}')" # Get the interface name associated with the NODE_IP
# ip -o -4 It lists all network interfaces with their IPv4 addresses, one per line -> We grep for the line containing our NODE_IP -> use awk to extract the second field, which is the interface name.
GATEWAY="192.168.56.1"

# Wait for server token
until [ -s /vagrant/node-token ]; do
  sleep 2
done

# Join the cluster
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="agent --node-ip=${NODE_IP} --flannel-iface=${PRIVATE_IFACE}" K3S_URL="https://${SERVER_IP}:6443" K3S_TOKEN=$(cat /vagrant/node-token) sh -

# Wait for agent to be fully active before changing routes
until systemctl is-active --quiet k3s-agent; do
  sleep 2
done

# Set private network as default route
ip route del default dev eth0
ip route add default via ${GATEWAY} dev ${PRIVATE_IFACE}