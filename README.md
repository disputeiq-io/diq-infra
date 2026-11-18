# diq-infra

Local development infrastructure, `kind` cluster definitions, and Keycloak realm configuration for **DisputeIQ**.

## Local Backing Services

```powershell
docker compose -f .\docker\docker-compose.dev.yml up -d
```

## Kind Cluster (Phase 1+)

```powershell
kind create cluster --config .\kind\kind-cluster.yaml
```
