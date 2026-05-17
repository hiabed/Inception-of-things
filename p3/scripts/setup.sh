#!/bin/bash

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[+] $1${NC}"; }
warn() { echo -e "${YELLOW}[~] $1${NC}"; }

GITHUB_REPO="https://github.com/IsmailElhassouni/ielhasso-iot"
REAL_USER=${SUDO_USER:-$USER}
REAL_HOME=$(eval echo ~$REAL_USER)
ARGOCD_PASSWORD_FILE="$REAL_HOME/argocdpass"

# ─── K3D CLUSTER ──────────────────────────────────────────────────────────────
if k3d cluster list | grep -q "mycluster"; then
    warn "Cluster 'mycluster' already exists, skipping."
else
    log "Creating k3d cluster..."
    k3d cluster create mycluster
fi

# ─── FIX KUBECONFIG FOR REAL USER ─────────────────────────────────────────────
log "Setting up kubeconfig for user '$REAL_USER'..."
mkdir -p $REAL_HOME/.kube
k3d kubeconfig get mycluster > $REAL_HOME/.kube/config
chown $REAL_USER:$REAL_USER $REAL_HOME/.kube/config
export KUBECONFIG=$REAL_HOME/.kube/config

# ─── NAMESPACES ───────────────────────────────────────────────────────────────
for ns in argocd dev; do
    if kubectl get namespace $ns &>/dev/null; then
        warn "Namespace '$ns' already exists, skipping."
    else
        log "Creating namespace '$ns'..."
        kubectl create namespace $ns
    fi
done

# ─── DEPLOY ARGOCD ────────────────────────────────────────────────────────────
if kubectl get deployment argocd-server -n argocd &>/dev/null; then
    warn "ArgoCD already deployed, skipping."
else
    log "Deploying ArgoCD..."
    kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml || true
    log "Waiting for ArgoCD server to be ready (this may take a few minutes)..."
    kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd
fi

# ─── GET ARGOCD PASSWORD ──────────────────────────────────────────────────────
log "Retrieving ArgoCD admin password..."
kubectl -n argocd get secret argocd-initial-admin-secret \
    -o jsonpath="{.data.password}" | base64 -d > $ARGOCD_PASSWORD_FILE
chown $REAL_USER:$REAL_USER $ARGOCD_PASSWORD_FILE
ARGOCD_PASS=$(cat $ARGOCD_PASSWORD_FILE)
log "Password saved to $ARGOCD_PASSWORD_FILE"

# ─── PORT FORWARD ARGOCD ──────────────────────────────────────────────────────
log "Starting ArgoCD port-forward on localhost:8080..."
pkill -f "port-forward svc/argocd-server" 2>/dev/null || true
sleep 2
sudo -u $REAL_USER kubectl port-forward svc/argocd-server -n argocd 8080:443 &>/dev/null &
sleep 8

# ─── LOGIN TO ARGOCD ──────────────────────────────────────────────────────────
log "Logging into ArgoCD..."
sudo -u $REAL_USER argocd login localhost:8080 \
    --username admin \
    --password "$ARGOCD_PASS" \
    --insecure

# ─── CREATE ARGOCD APP ────────────────────────────────────────────────────────
if sudo -u $REAL_USER argocd app get wil-playground &>/dev/null; then
    warn "ArgoCD app 'wil-playground' already exists, skipping."
else
    log "Creating ArgoCD app..."
    sudo -u $REAL_USER argocd app create wil-playground \
        --repo $GITHUB_REPO \
        --path . \
        --dest-server https://kubernetes.default.svc \
        --dest-namespace dev \
        --sync-policy automated
fi

# ─── WAIT FOR APP POD ─────────────────────────────────────────────────────────
log "Waiting for app pod to be ready in 'dev' namespace..."
kubectl wait --for=condition=available --timeout=120s deployment/wil-playground -n dev
sleep 10

# ─── PORT FORWARD APP ─────────────────────────────────────────────────────────
log "Starting app port-forward on localhost:8888..."
pkill -f "port-forward svc/wil-playground" 2>/dev/null || true
sleep 2
sudo -u $REAL_USER kubectl port-forward svc/wil-playground -n dev 8888:8888 &>/dev/null &
sleep 5

# ─── VERIFY ───────────────────────────────────────────────────────────────────
log "Verifying app..."
curl -s http://localhost:8888/
echo ""

log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log "Setup complete!"
log "ArgoCD UI : https://localhost:8080"
log "Username  : admin"
log "Password  : $ARGOCD_PASS"
log "App URL   : http://localhost:8888/"
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
