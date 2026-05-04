#!/usr/bin/env bash
set -euo pipefail

RELEASE_NAME="${1:-grafana}"
NAMESPACE="metrics"
VALUES_FILE="grafana-values.yaml"
HELM_REPO_NAME="grafana"
HELM_REPO_URL="https://grafana.github.io/helm-charts"

if ! command -v helm >/dev/null 2>&1; then
  echo "error: helm is required but not installed"
  exit 1
fi

if ! command -v kubectl >/dev/null 2>&1; then
  echo "error: kubectl is required but not installed"
  exit 1
fi

CURRENT_CONTEXT=$(kubectl config current-context)
echo "Using kubectl context: ${CURRENT_CONTEXT}"

echo "Adding Helm repo ${HELM_REPO_NAME}..."
helm repo add "${HELM_REPO_NAME}" "${HELM_REPO_URL}" >/dev/null 2>&1 || true
helm repo update

echo "Ensuring namespace '${NAMESPACE}' exists..."
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

echo "Creating/updating Grafana custom config ConfigMap..."
kubectl create configmap "${RELEASE_NAME}-custom-ini" -n "${NAMESPACE}" --from-file=grafana.ini --dry-run=client -o yaml | kubectl apply -f - >/dev/null

echo "Deploying Grafana release '${RELEASE_NAME}' into namespace '${NAMESPACE}'..."

ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:-}"

helm upgrade --install "${RELEASE_NAME}" "${HELM_REPO_NAME}/grafana" \
  --namespace "${NAMESPACE}" \
  --create-namespace \
  -f "${VALUES_FILE}" \
  ${ADMIN_PASSWORD:+--set adminPassword="${ADMIN_PASSWORD}"}

echo "Access Grafana via service in namespace '${NAMESPACE}'. Use 'kubectl get svc -n ${NAMESPACE}' or port-forward if needed."