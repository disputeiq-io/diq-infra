# diq-infra

Infrastructure-as-Code, local Kubernetes (`kind`), backing Docker Compose services,
Keycloak realm definitions, and Tilt inner-loop orchestration for DisputeIQ.

- Never commit real credentials; local files use non-production passwords marked `_local_`.
- PostgreSQL `init.sql` configures `diq_app` with `NOBYPASSRLS` so RLS isolation works locally.
