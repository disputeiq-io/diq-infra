# diq-infra

Local development infrastructure, `kind` cluster definitions, Keycloak realm configuration, and turnkey local stack startup scripts for **DisputeIQ**.

## Option 1: One-Command Local Startup (No Docker Required)

Starts `diq-tenant-service` (`8081`), `diq-dispute-service` (`8082`), `diq-gateway` (`8080`), `diq-network-simulator` (`8087`) using the `local` Spring profile (in-memory PostgreSQL-compatible H2 + local dev bearer tokens), and `diq-web` (`5173`):

```powershell
Set-Location D:\Projects\disputeiq\diq-infra
.\scripts\start-local.ps1
```

Stop everything:

```powershell
.\scripts\stop-local.ps1
```

## Option 2: Full Backing Stack (PostgreSQL 16 + pgvector, Redis, Kafka, Schema Registry)

Starts PostgreSQL (`pgvector/pgvector:pg16` on host port **`5433`** to avoid conflicting with any native Windows PostgreSQL on `5432`), Redis (`6379`), Apache Kafka + Zookeeper (`9092`), and Schema Registry (`8090`), then runs the microservices against PostgreSQL with full Row-Level Security (`V003__enable_postgres_rls.sql`):

```powershell
Set-Location D:\Projects\disputeiq\diq-infra
.\scripts\start-local.ps1 -WithDocker
```

To also start Keycloak OIDC on port `8180` (optional profile):

```powershell
docker compose -f .\docker\docker-compose.dev.yml --profile keycloak up -d
```

Stop everything:

```powershell
.\scripts\stop-local.ps1 -WithDocker
```

## Kind Cluster (Kubernetes + Istio Ambient)

```powershell
kind create cluster --config .\kind\kind-cluster.yaml
```
