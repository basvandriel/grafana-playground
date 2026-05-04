#!/usr/bin/env bash
set -euo pipefail

RELEASE_NAME="${1:-grafana}"
NAMESPACE="${2:-metrics}"
LOCAL_PORT="${3:-3000}"

if ! command -v kubectl >/dev/null 2>&1; then
  echo "error: kubectl is required but not installed"
  exit 1
fi

SERVICE_NAME=$(kubectl get svc -n "${NAMESPACE}" -l "app.kubernetes.io/instance=${RELEASE_NAME}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

if [[ -z "${SERVICE_NAME}" ]]; then
  echo "Could not find a service for release '${RELEASE_NAME}' in namespace '${NAMESPACE}'."
  echo "Attempting to use service name '${RELEASE_NAME}' instead."
  SERVICE_NAME="${RELEASE_NAME}"
fi

SERVICE_PORT=$(kubectl get svc -n "${NAMESPACE}" "${SERVICE_NAME}" -o jsonpath='{.spec.ports[0].port}')

if [[ -z "${SERVICE_PORT}" ]]; then
  echo "Could not determine the service port for '${SERVICE_NAME}' in namespace '${NAMESPACE}'."
  exit 1
fi

echo "Port forwarding Grafana service '${SERVICE_NAME}' in namespace '${NAMESPACE}' to http://localhost:${LOCAL_PORT} (service port ${SERVICE_PORT})"

echo "Use Ctrl+C to stop forwarding."
kubectl port-forward svc/${SERVICE_NAME} -n "${NAMESPACE}" "${LOCAL_PORT}:${SERVICE_PORT}"