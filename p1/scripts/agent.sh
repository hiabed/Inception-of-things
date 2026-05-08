#!/bin/bash

# Install dependencies
# apt-get update -y
# apt-get install -y curl

# Wait for the server to be ready and token to be available

while [ ! -f /vagrant/node-token ]; do # while the node token file does not exist, wait and check again
    echo "==================> Waiting for the server to be ready and node token to be available..."
    sleep 2
done

# store the token in a variable to use it for joining the cluster
TOKEN=$(cat /vagrant/node-token)

# # Join the K3s server as an agent
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--node-ip=192.168.56.111 --flannel-iface=enp0s8"  K3S_URL=https://192.168.56.110:6443 K3S_TOKEN=$TOKEN sh -
# The K3s server needs port 6443 to be accessible by all nodes in the cluster, so we use the server's IP address and the token to join the cluster as an agent.

ip route del default # Remove the default route to avoid conflicts with the host's network
ip route add default via 192.168.56.1 dev enp0s8 # Add a new default route through the host's gateway to ensure connectivity to the server