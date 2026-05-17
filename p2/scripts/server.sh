#!/bin/bash

NODE_IP="192.168.56.110"
GATEWAY="192.168.56.1"
PRIVATE_IFACE=$(ip -o -4 addr show | grep "${NODE_IP}" | awk '{print $2}')

# Install K3s in server mode
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--write-kubeconfig-mode 644 --node-ip=${NODE_IP} --flannel-iface=${PRIVATE_IFACE}" sh -

# Wait until the Kubernetes API is ready
until kubectl get nodes >/dev/null 2>&1; do
  sleep 2
done

# Apply all app manifests
kubectl apply -f /vagrant/confs/

sleep 10 # wait a bit for the pods to start before checking their status with until loop.

# Wait for ALL pods across all namespaces to be running
until kubectl get pods -A | grep -v "Running" | grep -v "Completed" | grep -v "NAME" | wc -l | grep -q "^0$"; do
  sleep 5
done

# Set private network as default route
ip route del default dev eth0
ip route add default via ${GATEWAY} dev ${PRIVATE_IFACE}
