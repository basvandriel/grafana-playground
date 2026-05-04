We have a global Grafana instance at https://basvandriel.grafana.net/.
How do we use GitOps for it?

## Central Grafana GitOps deployment repo

Yes, one central deployment repo is the right pattern for this.

### How multiple dashboards fit into one central repo

1. Each tool or team owns its own dashboard definitions in its own repository.
   - Example: `usage-tracker/` repo contains a dashboard JSON or a dashboard template for the usage tracker.
   - Example: `payment-service/` repo contains a dashboard for payment metrics.

2. The central Grafana infra repo is the deployment repo.
   - It contains provisioning config and the final dashboard files that Grafana will load.
   - Example structure:
     - `provisioning/dashboards/grafana-dashboard.yaml`
     - `dashboards/usage-tracker/usage-tracker-dashboard.json`
     - `dashboards/payment-service/payment-service-dashboard.json`
     - `dashboards/common/` (optional shared dashboards)

3. Use a sync/aggregation step to collect dashboard files from multiple repos.
   - This can be a CI job or GitHub Action that:
     1. clones the tool repos
     2. copies or generates their dashboard JSON into the central repo
     3. commits/pushes or deploys the aggregated config

4. Grafana provisioning reads the aggregated dashboard folder.
   - Grafana `provisioning/dashboards` can point to the shared `dashboards/` path.
   - All dashboards in that path are loaded into the central Grafana instance.

### Does the usage tracker repo need to care about Grafana deployment?

No, it should not.

- The usage tracker repo should focus on metrics instrumentation and dashboard content.
- Deployment and provisioning belong in the central Grafana infra repo.
- The tracker repo can optionally publish a dashboard JSON artifact or raw files that the central repo consumes.

### Separation of responsibilities

- `usage-tracker` repo:
  - owns the metric names
  - owns the dashboard JSON or templated dashboard source
  - does not need Grafana deployment config

- central Grafana repo:
  - owns Grafana provisioning rules
  - owns the aggregation of dashboards from many tools
  - owns environment-specific deployment details

### Practical workflow

1. Tool repo changes dashboard definition or metric names.
2. A pipeline syncs that dashboard file into the central Grafana repo.
3. The central repo is the one GitOps system used for the Grafana instance.
4. Grafana loads the combined dashboards from the central repo.

### Example repo layout

Central repo:
- `provisioning/dashboards/grafana-dashboard.yaml`
- `dashboards/usage-tracker/usage-tracker.json`
- `dashboards/tool-a/tool-a.json`
- `dashboards/tool-b/tool-b.json`

Usage tracker repo:
- `grafana/usage-tracker-dashboard.json`
- `src/metrics/`

## Deploying dashboards from the central repo

If this repo holds only dashboards, the deployment step is what pushes them into your main Grafana instance.

### Option 1: Grafana provisioning (self-hosted or containerized Grafana)

- Keep this repo as the source of truth for dashboard JSON files.
- Add a provisioning configuration in Grafana that points to the repo-mounted dashboard directory.
- Example provisioning file:
  ```yaml
  apiVersion: 1
  providers:
    - name: 'central-dashboards'
      orgId: 1
      folder: ''
      type: file
      disableDeletion: false
      options:
        path: /var/lib/grafana/dashboards
  ```
- In deployment, mount the repo contents to `/var/lib/grafana/dashboards` inside Grafana.
- On startup or config reload, Grafana imports every dashboard JSON from that path.

### Option 2: CI/CD pushes dashboards using Grafana HTTP API

This is the best fit when the repo is only dashboards and the Grafana instance is managed separately.

- A pipeline reads `dashboards/*.json` from this repo.
- For each dashboard, call Grafana API:
  - `POST /api/dashboards/db`
  - payload includes `dashboard`, `folderUid`, and `overwrite: true`
- This deploys dashboards directly into the running Grafana instance.

Example GitHub Actions-style flow:
- On push to `main`:
  1. checkout repo
  2. run a script that loops through `dashboards/**/*.json`
  3. for each file, call Grafana API with the dashboard payload

### What your repo contains

- `dashboards/` with one JSON per dashboard or per tool.
- optionally a dashboard metadata file or folder mapping if you want structured grouping.
- no Grafana server config if you use API deployment.

### What the main Grafana instance needs

- Grafana URL and admin/API token
- correct dashboard UIDs and folder targets
- a deployment pipeline that knows how to apply this repo

### Example deployment result

- `dashboards/usage-tracker/usage-tracker.json` becomes a dashboard in Grafana
- `dashboards/tool-a/tool-a.json` becomes another dashboard
- Grafana displays all dashboards in the central instance

### Sample dashboards in this repo

This repo now includes two sample dashboards under `grafana/`:
- `grafana/department-metrics.json`
- `grafana/usage-tracker.json`

These are static example dashboards designed to show how Git Sync can import dashboard files from a repository. Replace the text panels with actual metric queries once your data source is configured.

## Using Git Sync with this repo

For a self-hosted Grafana deployment, the recommended approach is to enable Git Sync and connect this repository directly.

1. Deploy Grafana with `deploy-grafana.sh`.
2. In Grafana, go to Administration → General → Provisioning.
3. Add a Git Sync repository using this repo's GitHub URL.
4. Set the path to `grafana/` and the branch to `main`.
5. Grafana will synchronize `grafana/department-metrics.json` and `grafana/usage-tracker.json`.

This repo also includes Git Sync resources in `git-sync/`, so the Git Sync setup can be managed as code.

- `git-sync/repository.yaml` defines the Git Sync repository resource.
- `push-git-sync.sh` helps push the Git Sync resource to Grafana using `gcx`.
- `.env.example` shows the required connection values.

The `grafana-values.yaml` file now uses a standalone `grafana.ini` file for feature toggles, and the deployment script creates a ConfigMap to mount it into Grafana.

> In short: the repo contains the dashboards, and a deployment pipeline pushes them to Grafana, either through provisioning (if you can mount the repo into Grafana) or via the Grafana API (more common for central managed instances).