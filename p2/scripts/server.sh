#!/bin/bash

# --write-kubeconfig-mode 644 → kubectl works without sudo
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--write-kubeconfig-mode 644 --node-ip=192.168.56.110" sh -

# Wait for K3s to be fully ready
sleep 10

# Apply all app configurations from the confs folder
kubectl apply -f /vagrant/confs/