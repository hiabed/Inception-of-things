#!/bin/bash

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log() { echo -e "${GREEN}[+] $1${NC}"; }
warn() { echo -e "${YELLOW}[~] $1${NC}"; }
err() { echo -e "${RED}[!] $1${NC}" >&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BONUS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
VALUES_FILE="${BONUS_DIR}/confs/values.yaml"
MANIFESTS_DIR="${BONUS_DIR}/confs/manifests"

REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME="$(eval echo "~${REAL_USER}")"
ARGOCD_PASSWORD_FILE="${REAL_HOME}/argocdpass"
GITLAB_ROOT_PASSWORD_FILE="${REAL_HOME}/gitlabrootpass"

GITLAB_NS="gitlab"
GITLAB_RELEASE="gitlab"
# Pin the chart for reproducible defenses; bump intentionally when upgrading GitLab.
GITLAB_HELM_CHART_VERSION="${GITLAB_HELM_CHART_VERSION:-8.8.1}"

ARGOCD_PF_PORT="${ARGOCD_PF_PORT:-8080}"
GITLAB_HTTP_PF_PORT="${GITLAB_HTTP_PF_PORT:-9080}"
APP_PF_PORT="${APP_PF_PORT:-8888}"

# In-cluster HTTP Git URL (Argo CD repo-server resolves Kubernetes DNS).
GITLAB_SVC="gitlab-webservice-default"
# Git over HTTP must go through Workhorse (commonly port 8181), not Rails/Puma.
GITLAB_HTTP_PORT="${GITLAB_HTTP_PORT:-8181}"
GIT_PROJECT_PATH="root/iot-gitops"
GIT_REPO_HTTP_INTERNAL="http://${GITLAB_SVC}.${GITLAB_NS}.svc.cluster.local:${GITLAB_HTTP_PORT}/${GIT_PROJECT_PATH}.git"

# ─── K3D CLUSTER ──────────────────────────────────────────────────────────────
# Same cluster name as Part 3 so you can reuse muscle memory; bonus adds GitLab in-cluster.
if k3d cluster list 2>/dev/null | grep -q "mycluster"; then
    warn "Cluster 'mycluster' already exists, skipping create."
else
    log "Creating k3d cluster (set K3D_CLUSTER_ARGS to customize, e.g. more agents/memory)..."
    # shellcheck disable=SC2086
    k3d cluster create mycluster ${K3D_CLUSTER_ARGS:-}
fi

# ─── KUBECONFIG ─────────────────────────────────────────────────────────────
# Mirror Part 3: write kubeconfig for the real user when setup is run under sudo.
log "Setting up kubeconfig for user '${REAL_USER}'..."
mkdir -p "${REAL_HOME}/.kube"
k3d kubeconfig get mycluster >"${REAL_HOME}/.kube/config"
chown "${REAL_USER}:${REAL_USER}" "${REAL_HOME}/.kube/config"
export KUBECONFIG="${REAL_HOME}/.kube/config"

# ─── NAMESPACES ───────────────────────────────────────────────────────────────
for ns in argocd dev "${GITLAB_NS}"; do
    if kubectl get namespace "${ns}" &>/dev/null; then
        warn "Namespace '${ns}' already exists, skipping."
    else
        log "Creating namespace '${ns}'..."
        kubectl create namespace "${ns}"
    fi
done

# ─── ARGO CD ──────────────────────────────────────────────────────────────────

ARGOCD_INSTALL_URL="https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml"
if kubectl get deployment argocd-server -n argocd &>/dev/null; then
    warn "Argo CD already present; reconciling with server-side apply (fixes oversized CRDs if a prior kubectl apply failed)..."
    kubectl apply -n argocd --server-side --force-conflicts -f "${ARGOCD_INSTALL_URL}"
    kubectl rollout restart deployment/argocd-applicationset-controller -n argocd 2>/dev/null || true
else
    log "Deploying Argo CD (upstream stable manifest, server-side apply)..."
    kubectl apply -n argocd --server-side --force-conflicts -f "${ARGOCD_INSTALL_URL}"
fi
log "Waiting for Argo CD API server Deployment..."
kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd

# ─── HELM REPO FOR GITLAB ─────────────────────────────────────────────────────
log "Configuring Helm repo for GitLab chart..."
helm repo add gitlab https://charts.gitlab.io/ 2>/dev/null || true
helm repo update gitlab

# ─── GITLAB (HELM) ───────────────────────────────────────────────────────────
if helm status "${GITLAB_RELEASE}" -n "${GITLAB_NS}" &>/dev/null; then
    warn "Helm release '${GITLAB_RELEASE}' already present in '${GITLAB_NS}', upgrading/reconciling..."
    # shellcheck disable=SC2086
    helm upgrade "${GITLAB_RELEASE}" gitlab/gitlab -n "${GITLAB_NS}" -f "${VALUES_FILE}" --version "${GITLAB_HELM_CHART_VERSION}" --timeout 60m --wait
else
    log "Installing GitLab via Helm (first boot is slow on small VMs; timeout is 60m)..."
    # shellcheck disable=SC2086
    helm install "${GITLAB_RELEASE}" gitlab/gitlab -n "${GITLAB_NS}" -f "${VALUES_FILE}" --version "${GITLAB_HELM_CHART_VERSION}" --timeout 60m --wait
fi

# ─── WAIT FOR CORE GITLAB WORKLOADS ─────────────────────────────────────────
log "Waiting for GitLab webservice Deployment (user-facing Git/HTTP)..."
kubectl rollout status "deployment/${GITLAB_SVC}" -n "${GITLAB_NS}" --timeout=600s

log "Waiting for GitLab toolbox Deployment (rails/admin tasks)..."
kubectl rollout status deployment/gitlab-toolbox -n "${GITLAB_NS}" --timeout=600s
log "Waiting extra time for GitLab internal services..."
sleep 120

# Detect Workhorse service port from the Service when possible.
DETECTED_GITLAB_HTTP_PORT="$(kubectl get svc "${GITLAB_SVC}" -n "${GITLAB_NS}" -o jsonpath='{range .spec.ports[*]}{.name}{":"}{.port}{"\n"}{end}' 2>/dev/null | awk -F: '$1 ~ /workhorse/ {print $2; exit}')"
if [[ -n "${DETECTED_GITLAB_HTTP_PORT}" ]]; then
    GITLAB_HTTP_PORT="${DETECTED_GITLAB_HTTP_PORT}"
fi
GIT_REPO_HTTP_INTERNAL="http://${GITLAB_SVC}.${GITLAB_NS}.svc.cluster.local:${GITLAB_HTTP_PORT}/${GIT_PROJECT_PATH}.git"
log "Using GitLab Workhorse HTTP port ${GITLAB_HTTP_PORT} for Git operations."

# ─── GITLAB INITIAL ROOT PASSWORD ─────────────────────────────────────────────
log "Locating GitLab initial root password Secret..."
ROOT_SECRET_NAME="$(kubectl get secrets -n "${GITLAB_NS}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | grep 'gitlab-initial-root-password' | head -n 1)"
if [[ -z "${ROOT_SECRET_NAME}" ]]; then
    err "Could not find a *gitlab-initial-root-password secret in namespace ${GITLAB_NS}."
    kubectl get secrets -n "${GITLAB_NS}" || true
    exit 1
fi

log "Reading initial root password into ${GITLAB_ROOT_PASSWORD_FILE} (chmod 600 recommended usage)."
kubectl -n "${GITLAB_NS}" get secret "${ROOT_SECRET_NAME}" -o jsonpath="{.data.password}" | base64 -d >"${GITLAB_ROOT_PASSWORD_FILE}"
chown "${REAL_USER}:${REAL_USER}" "${GITLAB_ROOT_PASSWORD_FILE}"
chmod 600 "${GITLAB_ROOT_PASSWORD_FILE}" || true
GITLAB_ROOT_PASSWORD="$(cat "${GITLAB_ROOT_PASSWORD_FILE}")"

# ─── CREATE GITLAB PROJECT (EMPTY REPO) ───────────────────────────────────────

log "Ensuring GitLab project '${GIT_PROJECT_PATH}' exists (idempotent)..."
set +e
kubectl exec -n "${GITLAB_NS}" deploy/gitlab-toolbox -- gitlab-rails runner "
u = User.find_by_username('root')
raise 'root user missing' unless u

namespace = u.namespace
raise 'root namespace missing' if namespace.nil?

unless Project.find_by_full_path('${GIT_PROJECT_PATH}') || Project.find_by(namespace_id: namespace.id, path: 'iot-gitops')
  Project.create!(
    name: 'iot-gitops',
    path: 'iot-gitops',
    creator: u,
        namespace: namespace,
    visibility_level: Gitlab::VisibilityLevel::INTERNAL
  )
end
" 2>&1
RAILS_RC=$?
set -e
if [[ "${RAILS_RC}" != "0" ]]; then
    warn "Rails project bootstrap returned ${RAILS_RC}."
    warn "If this is a newer GitLab version, create '${GIT_PROJECT_PATH}' manually in the UI, then push manifests (see bonus/reference-commands.txt)."
fi

# ─── PUSH MANIFESTS TO GITLAB OVER HTTP (FROM HOST) ──────────────────────────
log "Preparing a temporary git repo from ${MANIFESTS_DIR}..."
TMP_GIT="$(mktemp -d /tmp/iot-gitops-bootstrap.XXXXXX)"
chown -R "${REAL_USER}:${REAL_USER}" "${TMP_GIT}"
# Argo CD tracks --path manifests; keep the same layout in GitLab as in this repo.
mkdir -p "${TMP_GIT}/manifests"
cp -a "${MANIFESTS_DIR}/." "${TMP_GIT}/manifests/"
sudo -u "${REAL_USER}" git -C "${TMP_GIT}" init -b main
sudo -u "${REAL_USER}" git -C "${TMP_GIT}" config user.email "iot-bonus@local"
sudo -u "${REAL_USER}" git -C "${TMP_GIT}" config user.name "iot-bonus"
sudo -u "${REAL_USER}" git -C "${TMP_GIT}" add .
sudo -u "${REAL_USER}" git -C "${TMP_GIT}" commit -m "bootstrap: wil-playground manifests (v1)" || warn "No new commit (repo may already be bootstrapped)."

log "Starting temporary GitLab port-forward :${GITLAB_HTTP_PF_PORT} -> ${GITLAB_SVC}:${GITLAB_HTTP_PORT}..."
pkill -f "port-forward.*${GITLAB_SVC}.*${GITLAB_HTTP_PF_PORT}" 2>/dev/null || true
sleep 1
nohup sudo -u "${REAL_USER}" kubectl port-forward -n "${GITLAB_NS}" "svc/${GITLAB_SVC}" "${GITLAB_HTTP_PF_PORT}:${GITLAB_HTTP_PORT}" >/tmp/gitlab-http-pf.log 2>&1 </dev/null &
sleep 3

PASS_ENC="$(sudo -u "${REAL_USER}" python3 -c "import urllib.parse, pathlib; print(urllib.parse.quote(pathlib.Path('${GITLAB_ROOT_PASSWORD_FILE}').read_text().strip(), safe=''))")"
GIT_REMOTE_HOST="http://root:${PASS_ENC}@127.0.0.1:${GITLAB_HTTP_PF_PORT}/${GIT_PROJECT_PATH}.git"

log "Pushing manifests to GitLab (HTTP, branch main)..."
sudo -u "${REAL_USER}" git -C "${TMP_GIT}" remote remove origin 2>/dev/null || true
sudo -u "${REAL_USER}" git -C "${TMP_GIT}" remote add origin "${GIT_REMOTE_HOST}"
set +e
sudo -u "${REAL_USER}" git -C "${TMP_GIT}" push -u origin main
PUSH_RC=$?
set -e
if [[ "${PUSH_RC}" != "0" ]]; then
    warn "git push failed (${PUSH_RC}). If the project is missing, create it in GitLab UI and retry push using commands in bonus/reference-commands.txt."
fi

# ─── ARGO CD AUTH + REPO + APPLICATION ───────────────────────────────────────
log "Retrieving Argo CD admin password (initial secret)..."
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d >"${ARGOCD_PASSWORD_FILE}"
chown "${REAL_USER}:${REAL_USER}" "${ARGOCD_PASSWORD_FILE}"
chmod 600 "${ARGOCD_PASSWORD_FILE}" || true
ARGOCD_PASS="$(cat "${ARGOCD_PASSWORD_FILE}")"

log "Starting Argo CD port-forward on localhost:${ARGOCD_PF_PORT} (HTTPS -> local)..."
pkill -f "port-forward svc/argocd-server.*${ARGOCD_PF_PORT}" 2>/dev/null || true
sleep 1
nohup sudo -u "${REAL_USER}" kubectl port-forward svc/argocd-server -n argocd "${ARGOCD_PF_PORT}:443" >/tmp/argocd-pf.log 2>&1 </dev/null &
sleep 6

log "Logging into Argo CD CLI..."
sudo -u "${REAL_USER}" argocd login "localhost:${ARGOCD_PF_PORT}" --username admin --password "${ARGOCD_PASS}" --insecure

# If Part 3 already created the app pointing at GitHub, remove it so bonus can re-point to GitLab cleanly.
if sudo -u "${REAL_USER}" argocd app get wil-playground &>/dev/null; then
    log "Removing existing Argo CD Application 'wil-playground' (will recreate against GitLab)..."
    sudo -u "${REAL_USER}" argocd app delete wil-playground --yes || true
fi

# Remove stale repo registration if the URL was previously added with wrong creds.
sudo -u "${REAL_USER}" argocd repo rm "${GIT_REPO_HTTP_INTERNAL}" 2>/dev/null || true

log "Registering GitLab Git repo with Argo CD (repo-server runs inside the cluster and clones ${GIT_REPO_HTTP_INTERNAL})..."
sudo -u "${REAL_USER}" argocd repo add "${GIT_REPO_HTTP_INTERNAL}" --username root --password "${GITLAB_ROOT_PASSWORD}" --insecure-skip-server-verification

log "Creating Argo CD Application 'wil-playground' (automated sync, self-heal)..."
sudo -u "${REAL_USER}" argocd app create wil-playground \
    --repo "${GIT_REPO_HTTP_INTERNAL}" \
    --path manifests \
    --revision main \
    --dest-server https://kubernetes.default.svc \
    --dest-namespace dev \
    --sync-policy automated \
    --auto-prune \
    --self-heal

log "Waiting for Argo CD to sync wil-playground..."
sudo -u "${REAL_USER}" argocd app wait wil-playground --health --timeout 600 || warn "App did not become healthy in time (check: argocd app get wil-playground)."

log "Waiting for Kubernetes Deployment wil-playground in namespace dev..."
kubectl wait --for=condition=available --timeout=300s deployment/wil-playground -n dev

# ─── PORT FORWARD PLAYGROUND APP ────────────────────────────────────────────
log "Starting wil-playground port-forward on localhost:${APP_PF_PORT}..."
pkill -f "port-forward svc/wil-playground.*${APP_PF_PORT}" 2>/dev/null || true
sleep 1
nohup sudo -u "${REAL_USER}" kubectl port-forward svc/wil-playground -n dev "${APP_PF_PORT}:8888" >/tmp/wil-playground-pf.log 2>&1 </dev/null &
sleep 3

log "Smoke test: curl the playground app..."
curl -sS "http://localhost:${APP_PF_PORT}/" | head -c 200 || warn "curl failed (port-forward may still be warming up)."
echo ""

log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log "Bonus setup complete"
log "Argo CD UI : https://localhost:${ARGOCD_PF_PORT}  (admin / password in ${ARGOCD_PASSWORD_FILE})"
log "GitLab UI  : http://localhost:${GITLAB_HTTP_PF_PORT}  (root / password in ${GITLAB_ROOT_PASSWORD_FILE})"
log "App URL    : http://localhost:${APP_PF_PORT}/"
log "Git remote (in-cluster, for Argo CD): ${GIT_REPO_HTTP_INTERNAL}"
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log "Evaluator: bump image wil42/playground:v1 -> v2 by editing manifests/deployment.yaml in GitLab, commit to main; Argo CD auto-sync will roll the Deployment."
log "NOTE:If localhost:8888 stops responding later, restart the tunnel with:kubectl port-forward -n dev svc/wil-playground 8888:8888"
