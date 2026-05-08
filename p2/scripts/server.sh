#!/bin/bash

NODE_IP="192.168.56.110"
HOST_GATEWAY="192.168.56.1"
PRIVATE_IFACE="enp0s8"

# 1) Install K3s on the VM
# --write-kubeconfig-mode 644 lets kubectl work without sudo.
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--write-kubeconfig-mode 644 --node-ip=${NODE_IP} --flannel-iface=${PRIVATE_IFACE}" sh -

# 2) Wait until the Kubernetes API answers
until kubectl get nodes >/dev/null 2>&1; do
  sleep 2
done

# 3) Apply all manifests (apps + ingress)
kubectl apply -f /vagrant/confs/

# 4) Wait for Traefik ingress controller to exist, then become ready
until kubectl -n kube-system get deployment traefik >/dev/null 2>&1; do
  sleep 2
done
kubectl -n kube-system wait --for=condition=Available deployment/traefik --timeout=300s

# 5) Set the VM default route through the host-only interface
ip route replace default via "${HOST_GATEWAY}" dev "${PRIVATE_IFACE}"
