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

require() {
  for cmd in "$@"; do
    command -v "${cmd}" >/dev/null 2>&1 || { echo "error: ${cmd} is required but not installed"; exit 1; }
  done
}
require helm kubectl

# --- Preflight checks --------------------------------------------------------

CURRENT_CONTEXT=$(kubectl config current-context)
echo "Using kubectl context: ${CURRENT_CONTEXT}"

# --- Helm repo ---------------------------------------------------------------

echo "Adding Helm repo ${HELM_REPO_NAME}..."
# `|| true` so re-running after the repo already exists does not fail.
helm repo add "${HELM_REPO_NAME}" "${HELM_REPO_URL}" >/dev/null 2>&1 || true
helm repo update "${HELM_REPO_NAME}"

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

echo "Waiting for Grafana rollout to complete..."
kubectl rollout status deployment/"${RELEASE_NAME}" -n "${NAMESPACE}" --timeout=120s

echo "Grafana deployed. Run ./configure-git-sync.sh to set up Git Sync (first install or after changing git-sync/repository.yaml)."