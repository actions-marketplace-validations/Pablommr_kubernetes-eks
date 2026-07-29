# kubernetes-eks

GitHub Action to apply Kubernetes manifest files in your [EKS](https://aws.amazon.com/pt/eks/) cluster.

Point to a file or directory, and this action will apply your manifests, monitor the rollout, and fail fast if something goes wrong — without waiting for the full timeout.

<br>

# Example

Keyless (recommended) — OIDC via [aws-actions/configure-aws-credentials](https://github.com/aws-actions/configure-aws-credentials), no long-lived secrets:
```yml
name: Deploy

on:
  push:
    branches: [ main ]

permissions:
  id-token: write
  contents: read

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4
      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v6
        with:
          role-to-assume: arn:aws:iam::111122223333:role/my-deploy-role
          aws-region: us-east-1
      - name: Deployment
        uses: Pablommr/kubernetes-eks@v2.2.0
        env:
          CLUSTER_NAME: my-eks-cluster
          KUBE_YAML: path_to_file/file.yml
```

Classic — static access key + base64 kubeconfig (still fully supported):
```yml
jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout 
        uses: actions/checkout@v4
      - name: Deployment
        uses: Pablommr/kubernetes-eks@v2.2.0
        env:
          AWS_ACCESS_KEY_ID: ${{ secrets.AWS_ACCESS_KEY_ID }}
          AWS_SECRET_ACCESS_KEY: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
          KUBECONFIG: ${{ secrets.KUBECONFIG }}
          KUBE_YAML: path_to_file/file.yml
```

<br>

# Usage

You need an AWS identity with permission to apply resources in your EKS cluster — either an IAM role assumed via OIDC (keyless, recommended) or an IAM user with static keys. For more information, see the [AWS documentation](https://docs.aws.amazon.com/eks/latest/userguide/add-user-role.html).

Set up the environment variables listed below and point to your manifest files via `KUBE_YAML` (individual files) or `FILES_PATH` (directory).

<br>

# ENV's

## Authentication

### AWS credentials — two ways

**Ambient credentials (keyless, recommended)** — leave `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` unset and the action uses whatever credentials are already available in the environment: the temporary credentials exported by `aws-actions/configure-aws-credentials` (OIDC), an instance role on a self-hosted runner, etc. Nothing is written to disk.

**Static keys** — set `AWS_ACCESS_KEY_ID` + `AWS_SECRET_ACCESS_KEY` (and optionally `AWS_SESSION_TOKEN` for temporary STS credentials). They are written to `~/.aws/credentials` under `AWS_PROFILE_NAME`, exactly as before.

In both cases the action validates the identity with `aws sts get-caller-identity` before applying anything, and logs the effective ARN for auditability.

### Cluster access — two ways

**`CLUSTER_NAME` (keyless, recommended)** — the kubeconfig is generated at runtime with `aws eks update-kubeconfig`. Requires the cluster region in `AWS_REGION` (or `AWS_DEFAULT_REGION`). No `KUBECONFIG` secret needed.

**`KUBECONFIG`** — base64-encoded kubeconfig file, as before. The profile name inside the kubeconfig must match `AWS_PROFILE_NAME`.

## Required

### `KUBE_YAML` or `FILES_PATH`

At least one of them must be set. Both can be used simultaneously.

**`KUBE_YAML`** — path to one or more individual manifest files, separated by commas.
```
KUBE_YAML: kubernetes/deployment.yml,artifacts/configmap.yaml
```

**`FILES_PATH`** — path to a directory. All `.yaml` and `.yml` files directly inside the directory will be applied. Use `SUBPATH: true` to include subdirectories.
```
FILES_PATH: kubernetes
```

<br>

## Optional

### `AWS_PROFILE_NAME`

AWS credentials profile name to be written to `~/.aws/credentials`. Defaults to `default`. Only used with static keys — ignored with ambient credentials.

### `AWS_SESSION_TOKEN`

Session token for temporary STS credentials, written to `~/.aws/credentials` alongside the keys. Only relevant with static keys — ambient credentials carry their own token.

### `AWS_REGION`

Cluster region, required when using `CLUSTER_NAME` (falls back to `AWS_DEFAULT_REGION`). Already exported automatically by `aws-actions/configure-aws-credentials`.

### `ENVSUBST`
`boolean` — default: `false`

When `true`, substitutes environment variables inside the manifest files before applying them. Variables must be declared with `$` prefix (e.g., `$IMAGE_TAG`). Useful for injecting dynamic values such as image tags at deploy time.

### `SUBPATH`
`boolean` — default: `false`

When `true` and using `FILES_PATH`, applies manifest files found in subdirectories as well. When `false`, only files at the top level of `FILES_PATH` are applied.

### `CONTINUE_IF_FAIL`
`boolean` — default: `false`

When `true`, the action continues processing remaining files even if one apply or rollout fails. The pipeline will still exit with an error code at the end if any failure occurred. When `false`, the action stops immediately on the first failure.

### `KUBE_ROLLOUT`
`boolean` — default: `true`

When `true`, the action watches the rollout status after each apply for resources that manage Pods (`Deployment`, `ReplicaSet`, `DaemonSet`, `Pod`). The rollout is monitored until it completes successfully, fails, or reaches `KUBE_ROLLOUT_TIMEOUT`.

If the resource was unchanged by the apply, a `kubectl rollout restart` is triggered automatically to ensure the latest configuration or image is rolled out.

### `KUBE_ROLLOUT_TIMEOUT`
`string` — default: `20m`

Maximum time to wait for a rollout to complete. Must be in time format: `60s`, `5m`, `1h`. Requires `KUBE_ROLLOUT: true`.

### `KUBE_STABILITY_WINDOW`
`integer` — default: `15`

Number of seconds to wait after the rollout reports success before doing a final pod health check. This catches the case where an application crashes shortly after startup: Kubernetes considers the pod "ready" as soon as the container starts, before it has a chance to fail. Set a value higher than your application's startup time to ensure the check is meaningful. Requires `KUBE_ROLLOUT: true`.

<br>

# Rollout behaviour

When `KUBE_ROLLOUT` is enabled, the action handles two important scenarios:

### Workflow cancellation

The rollout monitor runs in the background, allowing the action to respond to cancellation signals from the GitHub Actions UI at any point during the rollout. Cancelling the workflow will stop the rollout immediately instead of leaving the step hanging.

### CrashLoopBackOff detection during rollout

The action polls the pod status every 3 seconds while waiting for the rollout. If any pod enters one of the following states, the pipeline fails immediately without waiting for the full timeout:

| State | Cause |
|---|---|
| `CrashLoopBackOff` | Container is crashing repeatedly on startup |
| `OOMKilled` | Container was terminated due to memory limit |
| `ImagePullBackOff` | Docker image could not be pulled |
| `ErrImagePull` | Error while pulling the Docker image |

### Post-rollout stability check

Kubernetes marks a pod as "ready" as soon as the container process starts — before the application has time to crash. In this scenario, the rollout finishes successfully while pods silently start crashing in the background.

After `kubectl rollout status` reports success, the action waits `KUBE_STABILITY_WINDOW` seconds (default: 15) and re-checks all pods. If any pod is in a failed state at that point, the pipeline fails. Set `KUBE_STABILITY_WINDOW` to a value greater than your application's startup time to ensure the check is meaningful.

<br>

# Application order

Manifests are applied in the following order to respect Kubernetes resource dependencies:

1. **Namespace** — must exist before any other resource.
2. **All other resource types** (ConfigMap, Service, Ingress, etc.) — applied without rollout monitoring.
3. **Pod-managing resources** (Deployment, ReplicaSet, DaemonSet, Pod) — applied with rollout monitoring when `KUBE_ROLLOUT: true`.
4. **ScaledObject** (KEDA) — applied last, as it references a Deployment that must already exist.

<br>

# Use case

Let's suppose you need to apply three artifacts in your EKS: one Deployment, one Service, and one ConfigMap. All your Kubernetes manifests are inside the `kubernetes` folder:

```
├── README.md
├── app
|  └── files
├── kubernetes
│   ├── deployment.yaml
│   ├── envs
│   │   ├── prod
│   │   │   └── configmap.yaml
│   │   └── staging
│   │       └── configmap.yaml
│   └── service.yaml
└── another_files
```

You want to:
- Apply `deployment.yaml` and `service.yaml` from the `kubernetes` folder (not subdirectories).
- Apply only the prod `configmap.yaml` individually.
- Substitute the image tag dynamically using `ENVSUBST`.

In `deployment.yaml`, declare the image tag as a placeholder:

```yaml
image: nginx:$IMAGE_TAG
```

Then configure your pipeline:

```yml
name: Build

on:
  push:
    branches: [ main ]

  workflow_dispatch:

env:
  AWS_PROFILE_NAME: default
  AWS_ACCESS_KEY_ID: ${{ secrets.AWS_ACCESS_KEY_ID }}
  AWS_SECRET_ACCESS_KEY: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
  KUBECONFIG: ${{ secrets.KUBECONFIG }}

jobs:
  deploy:
    runs-on: ubuntu-latest
    needs: build_and_push
    steps:
      - name: Checkout 
        uses: actions/checkout@v4
      - name: Deploy
        uses: Pablommr/kubernetes-eks@v2.1.2
        env:
          FILES_PATH: kubernetes
          KUBE_YAML: kubernetes/envs/prod/configmap.yaml
          SUBPATH: false
          ENVSUBST: true
          KUBE_ROLLOUT: true
          KUBE_ROLLOUT_TIMEOUT: 10m
          IMAGE_TAG: 1.21.6
```

With `FILES_PATH: kubernetes` and `SUBPATH: false`, only `deployment.yaml` and `service.yaml` are applied from the directory. The prod ConfigMap is applied separately via `KUBE_YAML`. The `$IMAGE_TAG` placeholder in `deployment.yaml` is replaced with `1.21.6` before applying.

<br>

# Change Log

## v2.2.0

- Keyless authentication: `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` are now optional — when unset, the action uses ambient credentials (e.g. OIDC temporary credentials exported by `aws-actions/configure-aws-credentials`, or an instance role). Nothing is written to disk in this mode.
- Runtime kubeconfig: new `CLUSTER_NAME` env generates the kubeconfig via `aws eks update-kubeconfig` (requires `AWS_REGION`/`AWS_DEFAULT_REGION`), removing the need for a base64 `KUBECONFIG` secret.
- `AWS_SESSION_TOKEN` support when writing static credentials, enabling temporary STS keys in the classic mode.
- Fail-fast identity check: `aws sts get-caller-identity` runs before any apply and the effective ARN is logged for auditability.
- Fully backward compatible: existing setups (keys + `KUBECONFIG`) behave exactly as before.

## v2.1.2

- Rollout cancellation: the pipeline now responds immediately to workflow cancellation from the GitHub Actions UI during a rollout, instead of waiting for the current step to finish.
- CrashLoopBackOff fail fast: if any pod enters a failed state (`CrashLoopBackOff`, `OOMKilled`, `ImagePullBackOff`, `ErrImagePull`) during a rollout, the pipeline fails immediately without waiting for the timeout.

## v2.1.1

- Add to broke pipeline in case of rollout failed

## v2.1.0

- Add KUBE_ROLLOUT_TIMEOUT option
- Alignment output logs
- Fix KUBE_YAML files

## v2.0.2

- Fix files validation in SUBPATH

## v2.0.1

- Fix to get resource name
- Add yq in background

## v2.0.0

- Added possibilitie to add path (env FILES_PATH) to apply multiple files
- Added env SUBPATH to apply files in supath
- Added env CONTINUE_IF_FAIL to continue applying files in fail case
- Added output on github action page

## v1.2.0

- Changed strategy to use an image that has already been built with dependencies in public registry [kubernetes-eks](https://hub.docker.com/r/pablommr/kubernetes-eks), decreasing action execution time

## v1.1.0

- Added otpion to KUBE_ROLLOUT follow the rollout status in Action page
- Fix metacharacter replacement in ENVSUBST

## v1.0.0
- Project started