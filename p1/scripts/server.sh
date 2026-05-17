#!/bin/bash

NODE_IP="192.168.56.110"
PRIVATE_IFACE=$(ip -o -4 addr show | grep "${NODE_IP}" | awk '{print $2}')
GATEWAY="192.168.56.1"

# Install K3s in server mode
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--write-kubeconfig-mode 644 --node-ip=${NODE_IP} --flannel-iface=${PRIVATE_IFACE}" sh -

# Wait for K3s API to be ready
until kubectl get nodes >/dev/null 2>&1; do
  sleep 2
done

# Share token with agent via shared folder
cp /var/lib/rancher/k3s/server/node-token /vagrant/node-token

# Set private network as default route
ip route del default dev eth0
ip route add default via ${GATEWAY} dev ${PRIVATE_IFACE}