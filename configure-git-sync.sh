#!/usr/bin/env bash
# configure-git-sync.sh — Push the Git Sync repository definition to a running Grafana instance.
#
# Run this once after a fresh install, or whenever git-sync/repository.yaml changes.
# The configuration persists in Grafana's internal storage and survives pod restarts
# and future Helm deploys — you do not need to re-run this on every deploy.
#
# Usage:
#   ./configure-git-sync.sh
#
# Prerequisites:
#   - gcx CLI installed (https://grafana.com/docs/grafana/latest/cli/gcx/)
#   - kubectl configured with access to the cluster
#   - GIT_SYNC_TOKEN: GitHub PAT with read access to the repository (set in .env)
#
# Token derivation:
#   A temporary Grafana service account is created automatically using the admin
#   password from the Helm-managed Kubernetes Secret. No manual token setup needed.
#
# Why gcx instead of kubectl?
#   Grafana's Git Sync resources (provisioning.grafana.app/v0alpha1 Repository) are
#   served by Grafana's own internal API — not Kubernetes CRDs. kubectl cannot create
#   them. gcx is the supported CLI wrapper for that API.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT_DIR"

if [[ -f .env ]]; then
  # shellcheck disable=SC1091
  source .env
fi

RELEASE_NAME="grafana"
NAMESPACE="metrics"
LOCAL_PORT=13000
GIT_SYNC_REPO_NAME=$(grep -m1 'name:' git-sync/repository.yaml | awk '{print $2}')

# --- Preflight checks --------------------------------------------------------

for cmd in gcx kubectl jq curl; do
  command -v "${cmd}" >/dev/null 2>&1 || { echo "error: ${cmd} is required but not installed"; exit 1; }
done

if [[ -z "${GIT_SYNC_TOKEN:-}" ]]; then
  echo "error: GIT_SYNC_TOKEN is not set. Set it in .env or environment."
  exit 1
fi

# --- Helpers -----------------------------------------------------------------

wait_for_port() {
  local port="$1" retries="${2:-15}"
  for _ in $(seq 1 "${retries}"); do
    if curl -sf "http://localhost:${port}/api/health" >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  echo "error: Grafana did not become reachable on port ${port} in time"
  return 1
}

# Removes any existing repository that isn't the one we're about to push.
# Grafana rejects a folder-scoped repo if an instance-scoped one exists (422).
# Deletion is async due to finalizers, so we poll until it's gone.
delete_stale_repos() {
  local url="$1" token="$2" keep="$3"
  local names name still
  names=$(curl -sf "${url}" -H "Authorization: Bearer ${token}" | jq -r '.items[].metadata.name')
  for name in ${names}; do
    [[ "${name}" == "${keep}" ]] && continue
    echo "Removing stale repository: ${name}"
    curl -sf -X DELETE "${url}/${name}" -H "Authorization: Bearer ${token}" >/dev/null
    echo -n "Waiting for ${name} to be fully deleted..."
    for _ in $(seq 1 30); do
      still=$(curl -sf "${url}" -H "Authorization: Bearer ${token}" \
        | jq -r --arg n "${name}" '.items[] | select(.metadata.name==$n) | .metadata.name')
      [[ -z "${still}" ]] && { echo " done"; break; }
      echo -n "."; sleep 2
    done
  done
}

# --- Port-forward ------------------------------------------------------------

echo "Opening port-forward to Grafana..."
kubectl port-forward -n "${NAMESPACE}" svc/"${RELEASE_NAME}" "${LOCAL_PORT}":80 >/dev/null 2>&1 &
PF_PID=$!

TEMP_SA_ID=""
ADMIN_PASS=""

cleanup() {
  [[ -n "${TEMP_SA_ID}" ]] && \
    curl -sf -X DELETE "http://localhost:${LOCAL_PORT}/api/serviceaccounts/${TEMP_SA_ID}" \
      -u "admin:${ADMIN_PASS}" >/dev/null || true
  kill "${PF_PID}" 2>/dev/null || true
}
trap cleanup EXIT

wait_for_port "${LOCAL_PORT}"

# --- Token derivation --------------------------------------------------------
# Derive a temporary Admin token from the Helm-managed admin secret.
# The service account is deleted automatically in cleanup().

ADMIN_PASS=$(kubectl get secret "${RELEASE_NAME}" -n "${NAMESPACE}" \
  -o jsonpath="{.data.admin-password}" | base64 --decode)

SA_NAME="gcx-configure-$(date +%s)"

TEMP_SA_ID=$(curl -sf -X POST "http://localhost:${LOCAL_PORT}/api/serviceaccounts" \
  -H "Content-Type: application/json" \
  -u "admin:${ADMIN_PASS}" \
  -d "{\"name\":\"${SA_NAME}\",\"role\":\"Admin\"}" | jq -r '.id')
[[ -z "${TEMP_SA_ID}" || "${TEMP_SA_ID}" == "null" ]] && { echo "error: failed to create service account"; exit 1; }

TOKEN=$(curl -sf -X POST "http://localhost:${LOCAL_PORT}/api/serviceaccounts/${TEMP_SA_ID}/tokens" \
  -H "Content-Type: application/json" \
  -u "admin:${ADMIN_PASS}" \
  -d '{"name":"gcx-configure-token"}' | jq -r '.key')
[[ -z "${TOKEN}" || "${TOKEN}" == "null" ]] && { echo "error: failed to obtain token"; exit 1; }

# --- Push --------------------------------------------------------------------

gcx login configure-local --server "http://localhost:${LOCAL_PORT}" --token "${TOKEN}" --yes

REPOS_URL="http://localhost:${LOCAL_PORT}/apis/provisioning.grafana.app/v0alpha1/namespaces/default/repositories"
delete_stale_repos "${REPOS_URL}" "${TOKEN}" "${GIT_SYNC_REPO_NAME}"

echo "Pushing Git Sync config..."
gcx resources push --path git-sync/

trap - EXIT
cleanup
echo "Done. Grafana will begin syncing dashboards from GitHub."
