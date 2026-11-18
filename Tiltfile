# DisputeIQ Local Inner-Loop Tiltfile
# Brings up backing services via Docker Compose; Kubernetes manifests will be wired in Phase 1+.

docker_compose('./docker/docker-compose.dev.yml')

local_resource(
    'check-jdk21-and-gradle',
    cmd='powershell -NoProfile -Command "& \'../diq-standards/scripts/ensure-toolchain.ps1\'"',
    labels=['toolchain'],
)
