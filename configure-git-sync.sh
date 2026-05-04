#!/usr/bin/env bash
# configure-git-sync.sh — Configure the Git Sync repository in a running Grafana instance.
#
# Run this once after a fresh install, or whenever the repository settings change.
# The configuration persists in Grafana's internal storage and survives pod restarts
# and future Helm deploys — you do not need to re-run this on every deploy.
#
# Usage:
#   ./configure-git-sync.sh
#
# Prerequisites:
#   - kubectl configured with access to the cluster
#   - python3 (for safe JSON construction)
#   - GIT_SYNC_TOKEN: GitHub PAT with repo access (set in .env)
#
# Token handling:
#   The admin password is read from the Helm-managed Kubernetes Secret automatically.
#   GIT_SYNC_TOKEN is passed via python3 argument to avoid any shell escaping issues.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT_DIR"

if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

RELEASE_NAME="grafana"
NAMESPACE="metrics"
LOCAL_PORT=13000

# --- Preflight checks --------------------------------------------------------

for cmd in kubectl python3 curl; do
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

# Delete all existing repositories (including grafana-playground) so we always
# do a fresh CREATE. This ensures the InlineSecureValue token is always stored
# fresh — Grafana only creates a new encrypted secret on POST, not on PUT/PATCH.
delete_all_repos() {
  local url="$1" auth_user="$2" auth_pass="$3"
  local names name still
  names=$(curl -sf "${url}" -u "${auth_user}:${auth_pass}" | python3 -c \
    "import json,sys; [print(i['metadata']['name']) for i in json.load(sys.stdin).get('items',[])]")
  for name in ${names}; do
    echo "Removing existing repository: ${name}"
    curl -sf -X DELETE "${url}/${name}" -u "${auth_user}:${auth_pass}" >/dev/null
    echo -n "Waiting for ${name} to be deleted..."
    for _ in $(seq 1 30); do
      still=$(curl -sf "${url}" -u "${auth_user}:${auth_pass}" | python3 -c \
        "import json,sys,sys; items=json.load(sys.stdin).get('items',[]); print(next((i['metadata']['name'] for i in items if i['metadata']['name']=='${name}'),''))")
      [[ -z "${still}" ]] && { echo " done"; break; }
      echo -n "."; sleep 2
    done
  done
}

# --- Port-forward ------------------------------------------------------------

echo "Opening port-forward to Grafana..."
kubectl port-forward -n "${NAMESPACE}" svc/"${RELEASE_NAME}" "${LOCAL_PORT}":80 >/dev/null 2>&1 &
PF_PID=$!

cleanup() {
  kill "${PF_PID}" 2>/dev/null || true
}
trap cleanup EXIT

wait_for_port "${LOCAL_PORT}"

# --- Credentials -------------------------------------------------------------

ADMIN_PASS=$(kubectl get secret "${RELEASE_NAME}" -n "${NAMESPACE}" \
  -o jsonpath="{.data.admin-password}" | base64 --decode)

REPOS_URL="http://localhost:${LOCAL_PORT}/apis/provisioning.grafana.app/v0alpha1/namespaces/default/repositories"

# --- Delete existing repos ---------------------------------------------------

delete_all_repos "${REPOS_URL}" "admin" "${ADMIN_PASS}"

# --- Create repository -------------------------------------------------------
# Use python3 to build the JSON body so the token value is never subject to
# shell escaping, glob expansion, or zsh pattern matching.

echo "Creating Git Sync repository..."
BODY=$(python3 - "${GIT_SYNC_TOKEN}" <<'PYEOF'
import json, sys
tok = sys.argv[1]
body = {
    "apiVersion": "provisioning.grafana.app/v0alpha1",
    "kind": "Repository",
    "metadata": {"name": "grafana-playground"},
    "spec": {
        "title": "grafana-playground",
        "type": "github",
        "github": {
            "url": "https://github.com/basvandriel/grafana-playground",
            "branch": "main",
            "path": "grafana/",
            "generateDashboardPreviews": False
        },
        "sync": {"enabled": True, "target": "folder", "intervalSeconds": 60},
        "workflows": ["write", "branch"]
    },
    "secure": {"token": {"create": tok}}
}
print(json.dumps(body))
PYEOF
)

RESPONSE=$(curl -sf -X POST "${REPOS_URL}" \
  -u "admin:${ADMIN_PASS}" \
  -H "Content-Type: application/json" \
  -d "${BODY}")

SECRET_NAME=$(echo "${RESPONSE}" | python3 -c \
  "import json,sys; print(json.load(sys.stdin)['secure']['token']['name'])")
echo "Repository created. Secret: ${SECRET_NAME}"

# --- Verify health -----------------------------------------------------------

echo -n "Waiting for health check..."
for _ in $(seq 1 12); do
  sleep 5
  HEALTHY=$(curl -sf "${REPOS_URL}/grafana-playground" \
    -u "admin:${ADMIN_PASS}" | python3 -c \
    "import json,sys; print(json.load(sys.stdin)['status']['health'].get('healthy',''))")
  if [[ "${HEALTHY}" == "True" || "${HEALTHY}" == "true" ]]; then
    echo " healthy!"
    trap - EXIT
    cleanup
    echo "Done. Grafana will begin syncing dashboards from GitHub."
    exit 0
  fi
  echo -n "."
done

echo ""
echo "warning: Repository created but health check timed out. Check Grafana logs."
HEALTH=$(curl -sf "${REPOS_URL}/grafana-playground" \
  -u "admin:${ADMIN_PASS}" | python3 -c \
  "import json,sys; d=json.load(sys.stdin)['status']['health']; print(json.dumps(d))")
echo "Health status: ${HEALTH}"
