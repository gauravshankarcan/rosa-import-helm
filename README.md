# Import ROSA HCP into Red Hat Advanced Cluster Management (ACM)

This guide explains how to import an **existing** ROSA Hosted Control Plane (HCP) cluster into an ACM hub so it appears under **Infrastructure → Clusters**.

Import is done with a **Helm chart** that renders ACM YAML manifests (`ManagedCluster`, `auto-import-secret`, optional `KlusterletAddonConfig`). No shell automation scripts are required beyond normal `oc` / `helm` commands.

| Artifact | Path |
|---|---|
| Helm chart | [`charts/rosa-acm-import/`](charts/rosa-acm-import/) |
| Default values | [`charts/rosa-acm-import/values.yaml`](charts/rosa-acm-import/values.yaml) |
| Example values | [`charts/rosa-acm-import/values.example.yaml`](charts/rosa-acm-import/values.example.yaml) |
| Templates (YAML) | [`charts/rosa-acm-import/templates/`](charts/rosa-acm-import/templates/) |

Official references:

- [Importing a managed cluster (ACM)](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.14/html/clusters/cluster-import)
- [Cloud Experts: ROSA + ACM](https://cloud.redhat.com/experts/rosa/acm/)

---

## Architecture

```
┌─────────────────────────────┐         auto-import          ┌─────────────────────────────┐
│  ACM hub                    │  ──────────────────────────► │  ROSA HCP (managed)         │
│  (e.g. workshop central)    │     installs klusterlet      │  e.g. terranova-rosa-gs      │
│                             │ ◄──────────────────────────  │                             │
│  Helm release applies:      │     JOINED / AVAILABLE       │  open-cluster-management-*  │
│  • ManagedCluster           │                              │  agent pods                 │
│  • Namespace/<clusterName>  │                              │                             │
│  • Secret/auto-import-secret│                              │                             │
│  • KlusterletAddonConfig    │                              │                             │
└─────────────────────────────┘                              └─────────────────────────────┘
```

- Helm runs against the **hub** kubeconfig (not ROSA).
- The chart’s `auto-import-secret` carries a short-lived ROSA **token + server** (or kubeconfig).
- ACM’s import controller uses that secret once, deploys the klusterlet to ROSA, then typically **deletes** the secret.

**Name rule:** `clusterName` must equal the hub namespace used for import artifacts (DNS-1035: lowercase, digits, hyphens). Prefer the ROSA cluster name (e.g. `terranova-rosa-gs`).

---

## Prerequisites

| Requirement | Notes |
|---|---|
| ACM hub Ready | `MultiClusterHub` Running; `local-cluster` JOINED/AVAILABLE |
| ROSA cluster Ready | From this repo: `terraform apply` completed |
| Network | Hub must reach the ROSA **API** (public HCP OK; private needs VPN/bastion) |
| Tools | `oc`, `helm` ≥ 3.x; optional `terraform` / `rosa` for discovering URLs |
| Hub credentials | e.g. `OCP_CENTRAL_*` in `env` |
| ROSA admin | `admin` + password from `terraform.tfvars` |

This repo’s typical values:

| Item | How to get it |
|---|---|
| Hub API | `OCP_CENTRAL_SERVER` in `env` |
| ROSA name | `terraform output -raw cluster_name` |
| ROSA API | `terraform output -raw cluster_api_url` |

---

## Chart layout (YAML folder)

```text
charts/rosa-acm-import/
├── Chart.yaml
├── values.yaml                 # defaults (no secrets)
├── values.example.yaml         # filled example — copy to values-secret.yaml
├── .helmignore
├── README.md
└── templates/
    ├── _helpers.tpl            # clusterName / labels / validation
    ├── namespace.yaml           # Namespace = clusterName
    ├── managedcluster.yaml     # cluster-scoped ManagedCluster
    ├── auto-import-secret.yaml # token+server OR kubeconfig
    └── klusterlet-addon-config.yaml
```

| Template | API object | Scope |
|---|---|---|
| `namespace.yaml` | `Namespace` | namespaced |
| `managedcluster.yaml` | `ManagedCluster` | **cluster-scoped** |
| `auto-import-secret.yaml` | `Secret` named `auto-import-secret` | in `clusterName` ns |
| `klusterlet-addon-config.yaml` | `KlusterletAddonConfig` | in `clusterName` ns (if addons.enabled) |

---

## Values reference

| Key | Default | Description |
|---|---|---|
| `clusterName` | `""` (**required**) | ACM ManagedCluster name / namespace |
| `labels.cloud` | `Amazon` | ManagedCluster label |
| `labels.vendor` | `OpenShift` | ManagedCluster label |
| `clusterSet` | `default` | `cluster.open-cluster-management.io/clusterset` |
| `managedCluster.hubAcceptsClient` | `true` | Accept klusterlet CSR |
| `managedCluster.leaseDurationSeconds` | `60` | Heartbeat lease |
| `import.autoImportRetry` | `"5"` | Import retries |
| `import.token` | `""` | ROSA bearer token (`oc whoami -t`) |
| `import.server` | `""` | ROSA API URL (`oc whoami --show-server`) |
| `import.kubeconfig` | `""` | Alternate: full kubeconfig YAML (mutually exclusive with token/server) |
| `addons.enabled` | `true` | Create KlusterletAddonConfig |
| `addons.applicationManager` | `true` | App lifecycle addon |
| `addons.policyController` | `true` | Policy addon |
| `addons.searchCollector` | `true` | Search addon |
| `addons.certPolicyController` | `true` | Cert policy addon |
| `namespace.create` | `true` | Create Namespace/`clusterName` |

Validation (in `_helpers.tpl`):

- `clusterName` is required  
- Exactly one of: (`import.token` + `import.server`) **or** `import.kubeconfig`

---

## Procedure

### 1. Confirm ACM hub is Ready

```bash
# Hub login (example from env)
set -a && source ./env && set +a
HUB_API="${OCP_CENTRAL_SERVER#"${OCP_CENTRAL_SERVER%%[![:space:]]*}"}"  # trim leading whitespace/tabs
oc login "$HUB_API" -u "$OCP_CENTRAL_USERNAME" -p "$OCP_CENTRAL_PASSWORD" --insecure-skip-tls-verify=true

oc get mch -A
# expect MultiClusterHub ... Running

oc get managedcluster
# expect local-cluster JOINED=True AVAILABLE=True
```

If ACM is not installed, install **Advanced Cluster Management for Kubernetes** from OperatorHub, create a `MultiClusterHub`, and wait until it is `Running` before continuing.

### 2. Collect ROSA API credentials

Log into the **ROSA** cluster (not the hub) and capture token + server for the chart:

```bash
cd /path/to/rosa-terra

ROSA_API="$(terraform output -raw cluster_api_url)"
CLUSTER_NAME="$(terraform output -raw cluster_name)"
ROSA_USER=admin
ROSA_PASS='<admin_password from terraform.tfvars>'

oc login "$ROSA_API" -u "$ROSA_USER" -p "$ROSA_PASS" --insecure-skip-tls-verify=true

export ROSA_TOKEN="$(oc whoami -t)"
export ROSA_SERVER="$(oc whoami --show-server)"
export CLUSTER_NAME

echo "CLUSTER_NAME=$CLUSTER_NAME"
echo "ROSA_SERVER=$ROSA_SERVER"
# do not paste the token into tickets / chat logs
```

Without Terraform:

```bash
CLUSTER_NAME=terranova-rosa-gs
ROSA_API=$(rosa describe cluster -c "$CLUSTER_NAME" -o json | jq -r .api.url)
oc login "$ROSA_API" -u admin -p '...' --insecure-skip-tls-verify=true
```

**Kubeconfig alternative** (instead of token/server):

```bash
oc config view --raw --minify > /tmp/${CLUSTER_NAME}.kubeconfig
chmod 600 /tmp/${CLUSTER_NAME}.kubeconfig
```

### 3. Prepare Helm values

```bash
cp charts/rosa-acm-import/values.example.yaml charts/rosa-acm-import/values-secret.yaml
# values-secret.yaml is gitignored — fill clusterName; token/server can be --set instead
```

Minimal `values-secret.yaml`:

```yaml
clusterName: terranova-rosa-gs

labels:
  cloud: Amazon
  vendor: OpenShift
  environment: lab

clusterSet: default

addons:
  enabled: true

# Prefer passing token/server on the CLI (below) rather than writing them to disk.
import:
  autoImportRetry: "5"
```

### 4. Preview rendered YAML (optional)

Switch kubeconfig / context back to the **hub**, then dry-run:

```bash
oc login "$HUB_API" -u "$OCP_CENTRAL_USERNAME" -p "$OCP_CENTRAL_PASSWORD" --insecure-skip-tls-verify=true

helm template rosa-import ./charts/rosa-acm-import \
  -n "${CLUSTER_NAME}" \
  -f charts/rosa-acm-import/values-secret.yaml \
  --set clusterName="${CLUSTER_NAME}" \
  --set import.token="${ROSA_TOKEN}" \
  --set import.server="${ROSA_SERVER}"
```

You should see Namespace, ManagedCluster, Secret/`auto-import-secret`, and KlusterletAddonConfig.

### 5. Install / upgrade the chart on the hub

```bash
helm upgrade --install rosa-import ./charts/rosa-acm-import \
  -n "${CLUSTER_NAME}" \
  --create-namespace \
  -f charts/rosa-acm-import/values-secret.yaml \
  --set clusterName="${CLUSTER_NAME}" \
  --set import.token="${ROSA_TOKEN}" \
  --set import.server="${ROSA_SERVER}"
```

Kubeconfig method:

```bash
helm upgrade --install rosa-import ./charts/rosa-acm-import \
  -n "${CLUSTER_NAME}" \
  --create-namespace \
  -f charts/rosa-acm-import/values-secret.yaml \
  --set clusterName="${CLUSTER_NAME}" \
  --set-file import.kubeconfig="/tmp/${CLUSTER_NAME}.kubeconfig"
```

Disable add-ons:

```bash
helm upgrade --install rosa-import ./charts/rosa-acm-import \
  -n "${CLUSTER_NAME}" --create-namespace \
  -f charts/rosa-acm-import/values-secret.yaml \
  --set clusterName="${CLUSTER_NAME}" \
  --set import.token="${ROSA_TOKEN}" \
  --set import.server="${ROSA_SERVER}" \
  --set addons.enabled=false
```

### 6. Wait until the managed cluster is Ready

```bash
oc get managedcluster "${CLUSTER_NAME}" -w
# JOINED=True  AVAILABLE=True
```

Or poll conditions:

```bash
oc get managedcluster "${CLUSTER_NAME}" -o jsonpath='{.status.conditions[?(@.type=="ManagedClusterJoined")].status}{" "}{.status.conditions[?(@.type=="ManagedClusterConditionAvailable")].status}{"\n"}'
```

Add-ons:

```bash
oc get managedclusteraddon -n "${CLUSTER_NAME}"
```

### 7. Verify agents on ROSA

```bash
oc login "$ROSA_API" -u "$ROSA_USER" -p "$ROSA_PASS" --insecure-skip-tls-verify=true

oc get pods -n open-cluster-management-agent
oc get pods -n open-cluster-management-agent-addon
# klusterlet / addon pods Running
```

ACM console: **Infrastructure → Clusters** → `${CLUSTER_NAME}` → **Ready**.

---

## Success checklist

| Check | Expected |
|---|---|
| Helm release on hub | `helm list -n ${CLUSTER_NAME}` shows `rosa-import` |
| `ManagedCluster` JOINED | `True` |
| `ManagedCluster` AVAILABLE | `True` |
| Klusterlet on ROSA | Pods Running in `open-cluster-management-agent` |
| `auto-import-secret` | Often **gone** after success (ACM deletes it — expected) |

---

## Console import (alternate)

If you prefer the UI instead of Helm:

1. Hub console → **All Clusters** → **Infrastructure** → **Clusters** → **Import cluster**
2. Cluster name = ROSA name (`terranova-rosa-gs`)
3. Paste server + token from step 2 (or upload kubeconfig)
4. Enable Application / Policy / Search as needed
5. Wait for **Ready**

The Helm chart is preferred for repeatable GitOps-style imports.

---

## Update / re-import

Token expired or import stuck:

1. Log into ROSA again and refresh `ROSA_TOKEN` / `ROSA_SERVER`
2. Re-run `helm upgrade --install ...` with the new `--set import.token=...`
3. Watch `oc get managedcluster ${CLUSTER_NAME} -w`

Change add-ons or labels: edit `values-secret.yaml` and `helm upgrade` again.

---

## Detach (uninstall)

Detaching removes ACM management only; it does **not** destroy the ROSA cluster or this Terraform stack.

```bash
oc login "$HUB_API" -u "$OCP_CENTRAL_USERNAME" -p "$OCP_CENTRAL_PASSWORD" --insecure-skip-tls-verify=true

helm uninstall rosa-import -n "${CLUSTER_NAME}"

# ManagedCluster is cluster-scoped; ensure it is removed
oc delete managedcluster "${CLUSTER_NAME}" --ignore-not-found

# Optional: remove empty namespace
oc delete namespace "${CLUSTER_NAME}" --ignore-not-found
```

---

## Troubleshooting

| Symptom | What to do |
|---|---|
| Helm fails: `clusterName is required` | `--set clusterName=...` or set in values file |
| Helm fails: token/server OR kubeconfig required | Pass `--set import.token` + `import.server`, or `--set-file import.kubeconfig` |
| `AVAILABLE=Unknown` / not JOINED | Hub→ROSA API reachability; refresh token; `helm upgrade` again |
| 401 on import | ROSA password/token wrong or expired |
| Klusterlet ImagePullBackOff | Image pull secret / registry access on ROSA |
| Secret missing after import | Normal — ACM deletes `auto-import-secret` after success |
| Helm shows secret drift | Expected if ACM deleted the secret; re-import only if cluster left Available |

Hub debug:

```bash
oc describe managedcluster "${CLUSTER_NAME}"
oc get events -n "${CLUSTER_NAME}" --sort-by='.lastTimestamp' | tail -40
oc get manifestwork -n "${CLUSTER_NAME}"
```

ROSA debug:

```bash
oc get pods -n open-cluster-management-agent -o wide
oc logs -n open-cluster-management-agent deploy/klusterlet --tail=100
```

---

## How this fits the Terraform repo

| Concern | Where |
|---|---|
| Create ROSA HCP + Karpenter | `main.tf`, `modules/karpenter`, [`tutorials.md`](tutorials.md) |
| Import ROSA into ACM | **This guide** + [`charts/rosa-acm-import`](charts/rosa-acm-import/) |
| Destroy ROSA | Detach from ACM first, then `terraform destroy` |

Suggested order:

1. `terraform apply` (ROSA Ready + Karpenter NodePools)  
2. Helm import into ACM (this document)  
3. Policies / applications from the hub  

---

## Quick reference

```bash
# --- on ROSA ---
oc login "$ROSA_API" -u admin -p '...' --insecure-skip-tls-verify=true
ROSA_TOKEN=$(oc whoami -t)
ROSA_SERVER=$(oc whoami --show-server)
CLUSTER_NAME=$(terraform output -raw cluster_name)

# --- on ACM hub ---
oc login "$HUB_API" -u admin -p '...' --insecure-skip-tls-verify=true

helm upgrade --install rosa-import ./charts/rosa-acm-import \
  -n "${CLUSTER_NAME}" --create-namespace \
  -f charts/rosa-acm-import/values.example.yaml \
  --set clusterName="${CLUSTER_NAME}" \
  --set import.token="${ROSA_TOKEN}" \
  --set import.server="${ROSA_SERVER}"

oc get managedcluster "${CLUSTER_NAME}" -w
```
