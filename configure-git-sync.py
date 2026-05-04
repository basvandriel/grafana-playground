"""
configure-git-sync.py — Configure the Git Sync repository in a running Grafana instance.

Run this once after a fresh install, or whenever the repository settings change.
The configuration persists in Grafana's internal storage and survives pod restarts
and future Helm deploys — you do not need to re-run this on every deploy.

Usage:
    uv run configure-git-sync.py

Prerequisites:
    - kubectl on PATH
    - GIT_SYNC_TOKEN: GitHub PAT with repo access (set in .env or environment)
"""

import base64
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

from dotenv import load_dotenv

RELEASE_NAME = "grafana"
NAMESPACE = "metrics"
LOCAL_PORT = 13000
REPO_NAME = "grafana-playground"
REPOS_PATH = "/apis/provisioning.grafana.app/v0alpha1/namespaces/default/repositories"


# ---------------------------------------------------------------------------
# kubectl helpers
# ---------------------------------------------------------------------------


def kubectl(*args: str) -> str:
    result = subprocess.run(["kubectl", *args], capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(f"kubectl {' '.join(args)} failed:\n{result.stderr.strip()}")
    return result.stdout.strip()


def get_admin_password() -> str:
    raw = kubectl(
        "get",
        "secret",
        RELEASE_NAME,
        "-n",
        NAMESPACE,
        "-o",
        "jsonpath={.data.admin-password}",
    )
    return base64.b64decode(raw).decode()


def start_port_forward() -> subprocess.Popen:
    return subprocess.Popen(
        [
            "kubectl",
            "port-forward",
            "-n",
            NAMESPACE,
            f"svc/{RELEASE_NAME}",
            f"{LOCAL_PORT}:80",
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


# ---------------------------------------------------------------------------
# Grafana API helpers
# ---------------------------------------------------------------------------


def grafana_request(
    method: str, path: str, admin_pass: str, body: dict | None = None
) -> dict:
    url = f"http://localhost:{LOCAL_PORT}{path}"
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    creds = base64.b64encode(f"admin:{admin_pass}".encode()).decode()
    req.add_header("Authorization", f"Basic {creds}")
    if data:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as e:
        body_text = e.read().decode()
        raise RuntimeError(f"HTTP {e.code} {method} {path}: {body_text}") from e


def wait_for_grafana(retries: int = 15) -> None:
    print("Waiting for Grafana to be reachable...", end="", flush=True)
    for _ in range(retries):
        try:
            urllib.request.urlopen(
                f"http://localhost:{LOCAL_PORT}/api/health", timeout=2
            )
            print(" ready")
            return
        except Exception:
            print(".", end="", flush=True)
            time.sleep(1)
    raise RuntimeError(f"Grafana did not become reachable on port {LOCAL_PORT}")


def delete_all_repos(admin_pass: str) -> None:
    """Delete all existing repositories so we always do a fresh CREATE.

    Grafana only stores a new encrypted secret on POST, not on PUT/PATCH,
    so we must delete-then-recreate to ensure the token is always fresh.
    """
    repos = grafana_request("GET", REPOS_PATH, admin_pass)
    for item in repos.get("items", []):
        name = item["metadata"]["name"]
        print(f"Removing existing repository: {name}")
        grafana_request("DELETE", f"{REPOS_PATH}/{name}", admin_pass)
        print(f"  Waiting for {name} to be deleted...", end="", flush=True)
        for _ in range(30):
            time.sleep(2)
            remaining = grafana_request("GET", REPOS_PATH, admin_pass)
            names = [i["metadata"]["name"] for i in remaining.get("items", [])]
            if name not in names:
                print(" done")
                break
            print(".", end="", flush=True)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def main() -> None:
    root = Path(__file__).parent
    load_dotenv(root / ".env")

    token = os.environ.get("GIT_SYNC_TOKEN", "")
    if not token:
        print(
            "error: GIT_SYNC_TOKEN is not set. Set it in .env or environment.",
            file=sys.stderr,
        )
        sys.exit(1)

    if (
        subprocess.run(
            ["kubectl", "version", "--client"], capture_output=True
        ).returncode
        != 0
    ):
        print("error: kubectl is not installed or not on PATH", file=sys.stderr)
        sys.exit(1)

    print("Opening port-forward to Grafana...")
    pf = start_port_forward()
    try:
        wait_for_grafana()
        admin_pass = get_admin_password()

        delete_all_repos(admin_pass)

        print("Creating Git Sync repository...")
        body = {
            "apiVersion": "provisioning.grafana.app/v0alpha1",
            "kind": "Repository",
            "metadata": {"name": REPO_NAME},
            "spec": {
                "title": REPO_NAME,
                "type": "github",
                "github": {
                    "url": "https://github.com/basvandriel/grafana-playground",
                    "branch": "main",
                    "path": "grafana/",
                    "generateDashboardPreviews": False,
                },
                "sync": {"enabled": True, "target": "folder", "intervalSeconds": 60},
                "workflows": ["write", "branch"],
            },
            # InlineSecureValue: "create" stores the token value on POST/PUT
            "secure": {"token": {"create": token}},
        }
        resp = grafana_request("POST", REPOS_PATH, admin_pass, body)
        secret_name = resp["secure"]["token"]["name"]
        print(f"Repository created. Secret: {secret_name}")

        print("Waiting for health check...", end="", flush=True)
        for _ in range(12):
            time.sleep(5)
            status = grafana_request("GET", f"{REPOS_PATH}/{REPO_NAME}", admin_pass)
            if status["status"]["health"].get("healthy"):
                print(" healthy!")
                print("Done. Grafana will begin syncing dashboards from GitHub.")
                return
            print(".", end="", flush=True)

        print()
        health = status["status"]["health"]
        print(f"warning: health check timed out. Status: {health}", file=sys.stderr)
        sys.exit(1)

    finally:
        pf.terminate()


if __name__ == "__main__":
    main()
