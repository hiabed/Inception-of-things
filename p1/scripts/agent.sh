#!/bin/bash

NODE_IP="192.168.56.111"
SERVER_IP="192.168.56.110"
PRIVATE_IFACE=$(ip -o -4 addr show | grep "${NODE_IP}" | awk '{print $2}')
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

# Replace NAT default route with private network
ip route del default
ip route add default via ${GATEWAY} dev ${PRIVATE_IFACE}