#!/usr/bin/env bash
# push-git-sync.sh — Standalone script to push the Git Sync repository definition to Grafana.
#
# Use this for ad-hoc updates (e.g. changing the branch or path in repository.yaml)
# without triggering a full Helm redeploy. deploy-grafana.sh calls this logic
# automatically via an inline port-forward, so you typically only need this script
# when Grafana is already running and you just want to update the Git Sync config.
#
# Usage:
#   ./push-git-sync.sh
#
# Prerequisites:
#   - gcx CLI installed (https://grafana.com/docs/grafana/latest/cli/gcx/)
#   - GRAFANA_URL pointing to an accessible Grafana instance
#   - GRAFANA_TOKEN: a Grafana service account token with Admin role
#   - GIT_SYNC_TOKEN: a GitHub PAT with read access to the repository
#
# Why gcx instead of kubectl?
#   Grafana's Git Sync resources (provisioning.grafana.app/v0alpha1 Repository) are
#   served by Grafana's own internal API — not Kubernetes. kubectl cannot create them.
#   gcx is the supported CLI wrapper for that API.
set -euo pipefail

# Always run from the repo root so git-sync/ resolves correctly.
ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT_DIR"

# Load local credentials. .env is git-ignored; see .env.example.
if [[ -f .env ]]; then
  # shellcheck disable=SC1091
  source .env
fi

# --- Preflight checks --------------------------------------------------------

if ! command -v gcx >/dev/null 2>&1; then
  echo "error: gcx is not installed. Install it first from https://github.com/grafana/gcx or Grafana docs."
  exit 1
fi

if [[ -z "${GRAFANA_URL:-}" ]]; then
  echo "error: GRAFANA_URL is not set. Set it in .env or environment."
  exit 1
fi

if [[ -z "${GRAFANA_TOKEN:-}" ]]; then
  echo "error: GRAFANA_TOKEN is not set. Set it in .env or environment."
  exit 1
fi

if [[ -z "${GIT_SYNC_TOKEN:-}" ]]; then
  echo "error: GIT_SYNC_TOKEN is not set. Set it in .env or environment."
  exit 1
fi

# --- Push --------------------------------------------------------------------

echo "Using Grafana URL: ${GRAFANA_URL}"

# Configure gcx to talk to the target Grafana instance, then push.
# `gcx config set` is idempotent — it overwrites any existing context with this name.
gcx config set --name default --url "${GRAFANA_URL}" --token "${GRAFANA_TOKEN}"
gcx config use default

echo "Pushing Git Sync resources from git-sync/ ..."
# Pushes all resource files in the git-sync/ directory.
# Currently: git-sync/repository.yaml (Repository resource for this repo).
gcx resources push --path git-sync

echo "Done. Verify with: gcx resources get repositories"