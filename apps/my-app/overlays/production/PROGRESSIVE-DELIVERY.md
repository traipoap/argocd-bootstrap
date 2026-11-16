# Progressive Delivery — `my-app` staging (blue/green + canary)

Traffic splitting for the **frontend** is implemented with **Gateway API
`HTTPRoute` weighted `backendRefs`** (served by the Istio gateway
`app-gateway` in `istio-system`). No extra operators/CRDs are required, and
everything stays in Git — which matters because ArgoCD runs with
`selfHeal: true`, so any out-of-band `kubectl patch` on the route is reverted.

## Topology

```
                 ┌────────────────────────────┐
 http://k3s-     │ HTTPRoute app-httproute    │
 origin.traipoap │  /   → blue-svc (weight X) │
 com ───────────▶│        green-svc (weight Y)│
                 └────────────────────────────┘
                 │X%                │Y%
                 ▼                  ▼
        frontend-blue         frontend-green      (colors = k8s labels,
        frontend-blue-svc     frontend-green-svc   one Deploy+Svc each)
                 └──────────────┴──▶ backend-svc (shared, rolling restart)
```

- `frontend-blue` — always runs the **last promoted release** (invariant).
- `frontend-green` — the **release slot**: points at the new version at 0%
  traffic, then gets promoted.
- `backend` — **not** split. It holds state (SQLite `users.db` on a
  `ReadWriteOnce` PVC): two backend versions cannot safely share the same
  database file, so it keeps a standard rolling restart.
  If you later want progressive delivery on the backend too, the blocker to
  solve first is moving off SQLite to a shared DB (e.g. Postgres).

Baseline (idle) state in Git: `blue=100 / green=0`.

## Files

| File | Role |
|---|---|
| `frontend-blue.yaml` | Deployment + Service, `color: blue`, pinned to the last good tag |
| `frontend-green.yaml` | Deployment + Service, `color: green`, the release slot |
| `patch-httproute.yaml` | Full HTTPRoute; `/` rule carries the `blue`/`green` weights |
| `scripts/promote-frontend.sh` | Edits the weights + `git commit` (you push) |
| `kustomization.yaml` | Frontend removed from `images:` on purpose (see note below) |

> **Why frontend is out of Argo CD Image Updater:** the kustomize `images:`
> transformer matches by image *name*, so it would bump both colors at once —
> destroying the "blue stays on the last good release" invariant. Releasing
> the frontend is now an explicit two-step (green tag → promotion), which is
> exactly what blue/green/canary requires. The backend is still auto-bumped.

## Releasing with CANARY

1. **Stage the new version** — set the tag in `frontend-green.yaml`
   (e.g. `0.0.77`), commit + push. ArgoCD rolls out green at **0%** traffic.
2. **Smoke-test green** (optional, no public traffic needed):
   ```sh
   kubectl -n staging run curl-tmp --rm -it --image=curlimages/curl -- \
     curl -s -o /dev/null -w '%{http_code}\n' frontend-green-svc:80/
   ```
3. **Ramp**, soaking at each step (watch Grafana: 5xx ratio, p95 latency,
   per-pod metrics — both colors are Prometheus-scraped and labelled by pod):
   ```sh
   ./scripts/promote-frontend.sh canary 5
   ./scripts/promote-frontend.sh canary 25
   ./scripts/promote-frontend.sh canary 50
   ./scripts/promote-frontend.sh ship        # 100% green
   ```
   Each command edits the weights, commits; **you push**, ArgoCD syncs.
4. **Seal the cutover** (so the invariant holds for the next release):
   set the tag in `frontend-blue.yaml` to the new version, set the weights
   back to baseline (`blue=100 / green=0`) and push. Green now idles at 0%
   as the slot for the *next* release.

## Releasing with BLUE/GREEN (fast cutover)

Steps 1–2 above, then one atomic flip instead of a ramp:

```sh
./scripts/promote-frontend.sh ship        # blue 100→0, green 0→100
```

Verify at 100%, then seal (step 4 of the canary flow).

## Rollback

At any point during a release — **no redeploy needed**, blue still runs the
last good version:

```sh
./scripts/promote-frontend.sh rollback    # back to blue=100 / green=0
```

## Verification cheatsheet

```sh
kubectl -n staging get pods -l app=frontend -o wide          # both colors Ready
kubectl -n staging get httproute app-httproute -o yaml | sed -n '/backendRefs/,/weight/p'
kubectl -n staging logs deploy/frontend-green --tail=50
curl -s -o /dev/null -w '%{http_code}\n' http://k3s-origin.traipoap.com/
# per-color traffic during a canary:
kubectl -n staging top pods -l app=frontend
```

## Caveats & fallbacks

- **Backend updates land alongside frontend releases** (image-updater bumps
  the backend automatically). During a frontend canary the backend may
  already be the new version — keep API changes backward-compatible, or move
  backend releases to their own explicit step.
- **Weight support:** Istio's Gateway API implementation supports weighted
  `backendRefs`. If a future Istio version/CRD mishandles `weight: 0`, the
  fallback is to run green at `weight: 1` while staging, or switch the split
  to an Istio `VirtualService` (the mesh is already installed).
- **Automation follow-up (optional):** a CI job can automate the release by
  (a) writing the new tag into `frontend-green.yaml`, (b) running
  `promote-frontend.sh` with a soak loop + metric checks, (c) sealing.
  Flagger can replace the manual ramp if you want policy-driven promotion —
  it supports the same Gateway API HTTPRoute split.
