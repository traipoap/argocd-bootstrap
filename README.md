# argocd-bootstrap

GitOps control plane for a k3s cluster. ArgoCD is the only deployer: cluster
state reconciles to this repo (auto-sync, prune, selfHeal on every app).

## Layout

| Path | What |
|---|---|
| `bootstrap/` | ArgoCD ApplicationSet definitions (synced by `root-bootstrap`) |
| `apps/<app>/` | Applications — kustomize (`base/` + `overlays/<env>/`) or a Helm chart with `overlays/<env>/values.yaml` |
| `clusters/staging/system/` | Cluster infra: argocd-image-updater, external-secrets (+ AWS SSM store), gateway (Istio / Gateway API), grafana, loki, prometheus, tempo, otel-collector, nfs-subdir-external-provisioner |
| `scripts/` | `etcd-backup.sh`, `promote-frontend.sh` |
| `01-init-cluster.bash` | `helm install argocd argo/argo-cd` (requires `KUBECONFIG`) |
| `02-bootstrap-cluster.bash` | `kubectl apply -f bootstrap/root-app.yaml` |
| `docker-compose.yaml` | Standalone local dev stack (GitLab, Jenkins, Grafana, etcd, …) — not part of the cluster |

## Delivery

```
git push → ApplicationSets generate Applications → ArgoCD syncs (prune + selfHeal)
```

| ApplicationSet | Generates |
|---|---|
| `business-applications` | Kustomize apps from `apps/*/overlays/*` (skips Helm-chart apps) |
| `business-helm-applications` | Helm charts from `apps/<app>/`, values from `apps/<app>/overlays/<env>/values.yaml` |
| `cluster-infrastructure` | `clusters/staging/system/*` (sync-wave -5, server-side apply) |

Consequences:

- Every `apps/*/overlays/<env>` directory becomes an Application automatically.
- Do not `kubectl apply`/`patch` app resources — selfHeal reverts them. Change Git.

## One-time: Image Updater secrets

The Argo CD Image Updater auto-bumps the `my-app` **staging** backend tag when a
new `ghcr.io/traipoap/backend` version is published, and commits it back here.
It needs these two secrets (names must match the config in
`clusters/staging/system/argocd-image-updater/`):

```sh
# GHCR pull credentials — only required if the packages are private
kubectl -n argocd create secret docker-registry github-credentials \
  --docker-server=ghcr.io --docker-username=<GHCR_USER> --docker-password=<GHCR_PAT>

# SSH private key used to push the tag write-back commits
kubectl -n argocd create secret generic ssh-git-creds \
  --from-file=sshPrivateKey=<path-to-private-key>
```

## Releasing `my-app`

1. CI pushes `ghcr.io/traipoap/{frontend,backend}:<tag>`.
2. Image Updater commits the new **backend** tag to
   `apps/my-app/overlays/staging/kustomization.yaml`.
   It never touches production and never touches the frontend (deliberate —
   see PROGRESSIVE-DELIVERY.md).
3. Frontend: set the new tag in `overlays/staging/frontend-green.yaml`
   (the release slot, starts at 0% traffic).
4. Verify, then promote — full runbook in
   `apps/my-app/overlays/staging/PROGRESSIVE-DELIVERY.md`:

   ```sh
   ./scripts/promote-frontend.sh canary 25    # ramp: 5 → 25 → 50 → 100
   ./scripts/promote-frontend.sh ship         # blue/green cutover (100% green)
   ./scripts/promote-frontend.sh rollback     # back to 100% blue
   ```

5. After it soaks in staging, promote to production: copy the verified tags
   into `overlays/production/` (kustomization `images:` + `frontend-blue.yaml`/
   `frontend-green.yaml`), then run the same cutover there.

Rules:

- `prod tag ≤ staging tag`, always. No production-only tags.
- Rollback is a commit (flip weights / restore tag) — never a live `kubectl apply`.

## Secrets

App secrets are fetched from AWS SSM by ExternalSecrets
(`clusters/staging/system/external-secrets*`); the SSM store credentials live in
`awssm-secret.yaml`. Secrets are created in-cluster by the ExternalSecret
controllers — no app-level secret values are checked in.

## Misc

- `ghcr-tags-check.py` — sanity-check published GHCR tags.
- `scripts/etcd-backup.sh` — etcd snapshot loop (also run by the docker-compose
  `etcd-backup` service).
