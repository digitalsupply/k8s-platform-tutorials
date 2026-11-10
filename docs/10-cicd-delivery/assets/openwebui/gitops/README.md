# Open WebUI GitOps

Kustomize manifests consumed by Argo CD. This repository is the **single source of
truth** for what runs in the `open-webui` namespace.

## Layout

```
base/                  # environment-agnostic manifests
overlays/prod/         # production overlay (what Argo CD points at)
```

## Promotion flow

1. A push to `digitalsupply/openwebui` triggers a Tekton `PipelineRun`.
2. The pipeline builds the image and pushes it to Harbor.
3. The `update-gitops-image` task rewrites `newTag:` in `overlays/prod/kustomization.yaml`
   and commits + pushes back to this repository.
4. Argo CD (auto-sync + self-heal) detects the new commit and rolls it out.

Because the tag is rewritten here, **the cluster never accepts a direct `kubectl apply`
of a changed image** — every rollout is a Git commit, so the running version is always
reproducible from Git history.

## Manual sync

```bash
# preview what would be applied
kubectl kustomize overlays/prod

# force Argo CD to re-sync
argocd app sync open-webui --grpc-web
```