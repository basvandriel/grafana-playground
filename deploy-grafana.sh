#!/usr/bin/env bash
# deploy-grafana.sh — Idempotent deploy script for self-hosted Grafana.
#
# Usage:
#   ./deploy-grafana.sh [RELEASE_NAME]
#
# Arguments:
#   RELEASE_NAME  Helm release name (default: grafana)
#
# Environment variables (can be set in .env):
#   GRAFANA_ADMIN_PASSWORD  Initial admin password (optional; Grafana generates one if omitted)
#   GIT_SYNC_TOKEN          GitHub PAT used by Grafana to clone/poll the Git Sync repository
#   GRAFANA_TOKEN           (optional) Pre-existing Grafana service account token for gcx.
#                           If unset, a temporary token is derived automatically from the
#                           admin secret that Helm stores in the cluster.
#
# What this script does:
#   1. Loads .env if present
#   2. Ensures the Helm repo is added and up to date
#   3. Creates the target namespace idempotently
#   4. Creates/updates a ConfigMap from grafana.ini (custom Grafana config with feature toggles)
#   5. Runs `helm upgrade --install` with grafana-values.yaml
#   6. Waits for the deployment rollout to finish
#   7. If gcx is installed and credentials are available, opens a temporary port-forward and
#      pushes the Git Sync repository definition from git-sync/ via gcx
#
# Why a custom grafana.ini ConfigMap instead of Helm values?
#   The chart always mounts its own generated configmap at /etc/grafana/grafana.ini.
#   To avoid a collision we mount our ini at /etc/grafana/custom.ini and point
#   GF_PATHS_CONFIG to that path (see grafana-values.yaml extraConfigmapMounts + env).
#
# Why gcx for Git Sync instead of Helm extraObjects?
#   Grafana's provisioning resources (provisioning.grafana.app/v0alpha1) are served by
#   Grafana's own internal API, not by Kubernetes. They are not CRDs. Helm (and kubectl)
#   cannot create them directly — only the Grafana API can. gcx is a thin CLI wrapper
#   around that API. The port-forward below is how we reach it from inside the cluster.
set -euo pipefail

# Always run from the repo root so relative paths (grafana.ini, git-sync/, etc.) resolve correctly.
ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT_DIR"

# Load local credentials/config if present. .env is git-ignored; see .env.example.
if [[ -f .env ]]; then
  # shellcheck disable=SC1091
  source .env
fi

RELEASE_NAME="${1:-grafana}"
NAMESPACE="metrics"
VALUES_FILE="grafana-values.yaml"
HELM_REPO_NAME="grafana"
HELM_REPO_URL="https://grafana.github.io/helm-charts"

# --- Preflight checks --------------------------------------------------------

if ! command -v helm >/dev/null 2>&1; then
  echo "error: helm is required but not installed"
  exit 1
fi

if ! command -v kubectl >/dev/null 2>&1; then
  echo "error: kubectl is required but not installed"
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq is required but not installed"
  exit 1
fi

CURRENT_CONTEXT=$(kubectl config current-context)
echo "Using kubectl context: ${CURRENT_CONTEXT}"

# --- Helm repo ---------------------------------------------------------------

echo "Adding Helm repo ${HELM_REPO_NAME}..."
# `|| true` so re-running after the repo already exists does not fail.
helm repo add "${HELM_REPO_NAME}" "${HELM_REPO_URL}" >/dev/null 2>&1 || true
helm repo update

# --- Namespace ---------------------------------------------------------------

echo "Ensuring namespace '${NAMESPACE}' exists..."
# dry-run + apply pattern makes this idempotent (no error if namespace already exists).
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

# --- grafana.ini ConfigMap ---------------------------------------------------
# The chart mounts this at /etc/grafana/custom.ini (see grafana-values.yaml).
# It enables the feature toggles required for Git Sync:
#   [feature_toggles] provisioning = true, kubernetesDashboards = true

echo "Creating/updating Grafana custom config ConfigMap..."
kubectl create configmap "${RELEASE_NAME}-custom-ini" -n "${NAMESPACE}" \
  --from-file=grafana.ini \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

# --- Helm deploy -------------------------------------------------------------

echo "Deploying Grafana release '${RELEASE_NAME}' into namespace '${NAMESPACE}'..."

ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:-}"

# `helm upgrade --install` is idempotent: installs on first run, upgrades on subsequent runs.
helm upgrade --install "${RELEASE_NAME}" "${HELM_REPO_NAME}/grafana" \
  --namespace "${NAMESPACE}" \
  --create-namespace \
  -f "${VALUES_FILE}" \
  ${ADMIN_PASSWORD:+--set adminPassword="${ADMIN_PASSWORD}"}

# Wait until the new pod(s) are fully ready before attempting the Git Sync push.
echo "Waiting for Grafana rollout to complete..."
kubectl rollout status deployment/"${RELEASE_NAME}" -n "${NAMESPACE}" --timeout=120s

# --- Git Sync config (gcx) ---------------------------------------------------
# Grafana's Git Sync repositories are defined as provisioning.grafana.app/v0alpha1
# resources and managed through Grafana's own API — not Kubernetes CRDs. This means
# Helm cannot apply them via extraObjects. Instead we use gcx (Grafana's CLI) to push
# the definitions from git-sync/repository.yaml after every deploy.
#
# Skipped gracefully if gcx is not installed or GIT_SYNC_TOKEN is missing, so the
# script remains usable in environments where Git Sync is not needed.
# Run ./push-git-sync.sh for a standalone push against a running instance.

if command -v gcx >/dev/null 2>&1 && [[ -n "${GIT_SYNC_TOKEN:-}" ]]; then
  echo "Pushing Git Sync config via gcx..."

  # Open a temporary port-forward so gcx can reach the in-cluster Grafana API.
  # We use a non-standard local port (13000) to avoid colliding with any existing
  # port-forward on 3000 (e.g. from port-forward-grafana.sh).
  LOCAL_PORT=13000
  kubectl port-forward -n "${NAMESPACE}" svc/"${RELEASE_NAME}" "${LOCAL_PORT}":80 >/dev/null 2>&1 &
  PF_PID=$!

  TEMP_SA_ID=""
  ADMIN_PASS=""

  # cleanup() kills the port-forward and removes the temporary service account (if
  # one was created). Attached to both the EXIT trap and the normal success path so
  # resources are always released, even when the script fails mid-way.
  cleanup() {
    if [[ -n "${TEMP_SA_ID}" ]]; then
      curl -sf -X DELETE "http://localhost:${LOCAL_PORT}/api/serviceaccounts/${TEMP_SA_ID}" \
        -u "admin:${ADMIN_PASS}" >/dev/null || true
    fi
    kill "${PF_PID}" 2>/dev/null || true
  }
  trap cleanup EXIT

  # Brief pause for the port-forward tunnel to establish before gcx connects.
  sleep 2

  # Obtain a Grafana API token for gcx.
  # If GRAFANA_TOKEN is already set in .env, use it directly.
  # Otherwise, derive one automatically: retrieve the admin password from the Secret
  # that Helm always creates, use it to create a temporary service account + token
  # via the Grafana REST API, then delete the service account after the push.
  DEPLOY_TOKEN="${GRAFANA_TOKEN:-}"
  if [[ -z "${DEPLOY_TOKEN}" ]]; then
    ADMIN_PASS=$(kubectl get secret "${RELEASE_NAME}" -n "${NAMESPACE}" \
      -o jsonpath="{.data.admin-password}" | base64 --decode)

    # Use a timestamped name so parallel deploys don't collide.
    SA_NAME="gcx-deploy-$(date +%s)"

    TEMP_SA_ID=$(curl -sf -X POST "http://localhost:${LOCAL_PORT}/api/serviceaccounts" \
      -H "Content-Type: application/json" \
      -u "admin:${ADMIN_PASS}" \
      -d "{\"name\":\"${SA_NAME}\",\"role\":\"Admin\"}" | jq -r '.id')

    DEPLOY_TOKEN=$(curl -sf -X POST "http://localhost:${LOCAL_PORT}/api/serviceaccounts/${TEMP_SA_ID}/tokens" \
      -H "Content-Type: application/json" \
      -u "admin:${ADMIN_PASS}" \
      -d '{"name":"gcx-deploy-token"}' | jq -r '.key')
  fi

  # --yes skips interactive prompts, making gcx login safe for automation.
  # Uses a fixed context name so repeated deploys overwrite the same entry
  # rather than accumulating stale contexts in ~/.config/gcx/config.yaml.
  gcx login deploy-local --server "http://localhost:${LOCAL_PORT}" --token "${DEPLOY_TOKEN}" --yes

  # Grafana only allows one repository type at a time: if an instance-scoped
  # repository exists, it blocks creation of any folder-scoped repository (422).
  # Delete any stale repositories that aren't the one we're about to push before
  # pushing, so we always converge to exactly the definition in git-sync/.
  REPOS_URL="http://localhost:${LOCAL_PORT}/apis/provisioning.grafana.app/v0alpha1/namespaces/default/repositories"
  EXISTING_REPOS=$(curl -sf "${REPOS_URL}" -H "Authorization: Bearer ${DEPLOY_TOKEN}" | jq -r '.items[].metadata.name')
  for REPO_NAME in ${EXISTING_REPOS}; do
    if [[ "${REPO_NAME}" != "grafana-playground" ]]; then
      echo "Removing stale repository: ${REPO_NAME}"
      curl -sf -X DELETE "${REPOS_URL}/${REPO_NAME}" \
        -H "Authorization: Bearer ${DEPLOY_TOKEN}" >/dev/null
      # Finalizers (cleanup, remove-orphan-resources) make deletion async.
      # Poll until the resource disappears before trying to push.
      echo -n "Waiting for ${REPO_NAME} to be fully deleted..."
      for _ in $(seq 1 30); do
        STILL_EXISTS=$(curl -sf "${REPOS_URL}" -H "Authorization: Bearer ${DEPLOY_TOKEN}" \
          | jq -r --arg n "${REPO_NAME}" '.items[] | select(.metadata.name==$n) | .metadata.name')
        if [[ -z "${STILL_EXISTS}" ]]; then
          echo " done"
          break
        fi
        echo -n "."
        sleep 2
      done
    fi
  done

  gcx resources push --path git-sync/

  trap - EXIT
  cleanup
  echo "Git Sync config pushed successfully."
else
  echo "Skipping Git Sync push (gcx not found or GIT_SYNC_TOKEN not set)."
  echo "Run ./push-git-sync.sh manually to configure Git Sync."
fi

echo "Access Grafana via service in namespace '${NAMESPACE}'. Use 'kubectl get svc -n ${NAMESPACE}' or port-forward if needed."