#!/bin/bash

# Install dependencies
# apt-get update -y
# apt-get install -y curl

# Install K3s in server mode
# No K3S_URL → server mode → creates cluster
# --write-kubeconfig-mode 644 → kubectl works without sudo
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--write-kubeconfig-mode 644 --node-ip=192.168.56.110 --flannel-iface=enp0s8" sh -

# Wait for K3s to be ready
kubectl wait --for=condition=Ready node/mhassanis --timeout=60s

# Save the node token from /var/lib/rancher/k3s/server/node-token to a shared location so the agent can use it to join
cp /var/lib/rancher/k3s/server/node-token /vagrant/node-token

ip route del default # Remove the default route to avoid conflicts with the host's network
ip route add default via 192.168.56.1 dev enp0s8 # Add a new default route through the host's gateway to ensure connectivity to the server
