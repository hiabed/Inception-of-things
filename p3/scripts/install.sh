#!/bin/bash
set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[+] $1${NC}"; }
warn() { echo -e "${YELLOW}[~] $1${NC}"; }

# ─── DOCKER ───────────────────────────────────────────────────────────────────
if command -v docker &>/dev/null; then
    warn "Docker already installed: $(docker --version)"
else
    log "Installing Docker..."
    curl -fsSL https://get.docker.com | sh
    sudo usermod -aG docker $USER
    sudo systemctl enable --now docker
    log "Docker installed."
fi

# ─── KUBECTL ──────────────────────────────────────────────────────────────────
if command -v kubectl &>/dev/null; then
    warn "kubectl already installed: $(kubectl version --client --short 2>/dev/null)"
else
    log "Installing kubectl..."
    curl -LO "https://dl.k8s.io/release/$(curl -sL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
    chmod +x kubectl
    sudo mv kubectl /usr/local/bin/
    log "kubectl installed."
fi

# ─── K3D ──────────────────────────────────────────────────────────────────────
if command -v k3d &>/dev/null; then
    warn "k3d already installed: $(k3d version | head -1)"
else
    log "Installing k3d..."
    curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
    log "k3d installed."
fi

# ─── ARGOCD CLI ───────────────────────────────────────────────────────────────
if command -v argocd &>/dev/null; then
    warn "ArgoCD CLI already installed: $(argocd version --client --short 2>/dev/null)"
else
    log "Installing ArgoCD CLI..."
    curl -sSL -o argocd https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
    chmod +x argocd
    sudo mv argocd /usr/local/bin/
    log "ArgoCD CLI installed."
fi

log "All tools installed successfully."
