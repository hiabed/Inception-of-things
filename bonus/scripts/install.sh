#!/bin/bash

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[+] $1${NC}"; }
warn() { echo -e "${YELLOW}[~] $1${NC}"; }

# ─── DOCKER ───────────────────────────────────────────────────────────────────
# Part 3 already relies on Docker for k3d nodes; install Docker Engine if absent.
if command -v docker &>/dev/null; then
    warn "Docker already installed: $(docker --version)"
else
    log "Installing Docker..."
    curl -fsSL https://get.docker.com | sh
    sudo usermod -aG docker "${SUDO_USER:-$USER}"
    sudo systemctl enable --now docker
    log "Docker installed (log out/in if docker group was added)."
fi

# ─── KUBECTL ──────────────────────────────────────────────────────────────────
if command -v kubectl &>/dev/null; then
    warn "kubectl already installed: $(kubectl version --client -o yaml 2>/dev/null | head -n 1 || true)"
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

# ─── HELM (required for GitLab chart) ─────────────────────────────────────────
if command -v helm &>/dev/null; then
    warn "Helm already installed: $(helm version --short 2>/dev/null || helm version)"
else
    log "Installing Helm 3..."
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
    log "Helm installed."
fi

# ─── ARGO CD CLI ──────────────────────────────────────────────────────────────
if command -v argocd &>/dev/null; then
    warn "Argo CD CLI already installed: $(argocd version --client --short 2>/dev/null || true)"
else
    log "Installing Argo CD CLI..."
    curl -sSL -o argocd https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
    chmod +x argocd
    sudo mv argocd /usr/local/bin/
    log "Argo CD CLI installed."
fi

# ─── GIT (bootstrap pushes manifests into local GitLab) ───────────────────────
if command -v git &>/dev/null; then
    warn "git already installed: $(git --version)"
else
    log "Installing git..."
    if command -v apt-get &>/dev/null; then
        sudo apt-get update -qq && sudo apt-get install -y git
    elif command -v dnf &>/dev/null; then
        sudo dnf install -y git
    elif command -v yum &>/dev/null; then
        sudo yum install -y git
    else
        echo "Please install git manually." >&2
        exit 1
    fi
    log "git installed."
fi

log "All bonus tools installed successfully."
