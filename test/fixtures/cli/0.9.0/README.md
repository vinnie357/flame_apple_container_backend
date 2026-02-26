# CLI 0.9.0 Response Fixtures

Captured from `container CLI version 0.9.0 (build: release, commit: 3e49dce)`.

Each `.json` file contains `{"stdout": ..., "exit_code": ...}` representing
the `{output, exit_code}` tuple returned by `System.cmd/3`.

## Commands available in 0.9.0

### Container lifecycle
- `container run` — Run a container
- `container stop` — Stop containers
- `container kill` — Kill or signal containers
- `container create` — Create a container (without starting)
- `container start` — Start a created container
- `container delete` / `rm` — Delete containers
- `container prune` — Remove stopped containers

### Container inspection
- `container inspect` — JSON details about containers
- `container list` / `ls` — List running containers
- `container stats` — Resource usage statistics
- `container logs` — Fetch container logs
- `container exec` — Run command in running container

### Image operations
- `container image build` — Build from Dockerfile
- `container image ls` — List images
- `container image rm` — Remove images
- `container image inspect` — Inspect image details
- `container image pull` — Pull image from registry
- `container image push` — Push image to registry
- `container image tag` — Tag an image
- `container image prune` — Remove unused images

### DNS
- `container system dns list` — List local DNS domains
- `container system dns create` — Create DNS domain (requires admin)
- `container system dns delete` — Delete DNS domain (requires admin)

### Network
- `container network create` / `list` / `inspect` / `delete` / `prune`

### Volume
- `container volume create` / `list` / `inspect` / `delete` / `prune`

### System
- `container system df` — Disk usage
- `container system status` — Service status
- `container system version` — Version info
- `container system start` / `stop` — Manage services

## Commands NOT in 0.9.0

- `container system dns default get` — Does not exist
- `container update` — Plugin not found
