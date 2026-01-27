# Copilot Instructions for Monolithic Repository

This document provides project-specific instructions to help Copilot understand the codebase and produce higher quality suggestions.

## Project Overview

Monolithic is a Docker container for LanCache.net that provides a single caching solution for game content at LAN parties. It uses nginx as a reverse proxy cache to store and serve game downloads from various content delivery networks.

## Project Structure

```
monolithic/
├── .circleci/              # CircleCI CI/CD configuration
├── overlay/                # Files copied into the Docker image
│   ├── etc/nginx/          # nginx configuration files
│   │   ├── conf.d/         # Additional nginx configuration
│   │   ├── sites-available/ # nginx site configurations
│   │   ├── stream-available/ # nginx stream configurations
│   │   └── nginx.conf      # Main nginx configuration
│   ├── hooks/              # Entrypoint hooks run during container startup
│   │   ├── entrypoint-pre.d/ # Pre-entrypoint scripts
│   │   └── supervisord-pre.d/ # Pre-supervisord scripts
│   └── scripts/            # Runtime scripts for cache management
├── Dockerfile              # Docker image definition
├── goss.yaml               # GOSS container testing configuration
├── build-locally.sh        # Local Docker build script
└── run-tests.sh            # Test runner script
```

## Build and Test Commands

### Building the Docker Image

```bash
# Build locally (includes building dependent images)
./build-locally.sh

# Direct build (requires base images to exist)
docker build -t lancachenet/monolithic:latest .
```

### Running Tests

```bash
# Run the GOSS test suite
./run-tests.sh
```

Tests use [GOSS](https://github.com/aelsabbahy/goss) for container validation. The test configuration is in `goss.yaml` and validates:
- Required files exist (`/data/logs/access.log`, `/data/logs/error.log`)
- Port 80 is listening
- The cache test script exits successfully
- nginx and supervisord processes are running
- The heartbeat endpoint returns HTTP 204

## Technology Stack

- **Container Runtime**: Docker
- **Base Image**: `lancachenet/ubuntu-nginx:latest`
- **Web Server**: nginx (configured for caching)
- **Process Manager**: supervisord
- **Testing**: GOSS (container testing framework)
- **CI/CD**: CircleCI
- **Shell Scripts**: Bash (POSIX-compatible)

## Coding Conventions

### Shell Scripts

- Use `#!/bin/bash` shebang
- Use `set -e` for error handling where appropriate
- Follow existing patterns for logging and output
- Scripts in `overlay/scripts/` should be executable (`chmod 755`)
- Use meaningful variable names
- Quote variables to prevent word splitting

### nginx Configuration

- Follow existing configuration patterns in `overlay/etc/nginx/`
- Use clear comments to explain complex directives
- Maintain consistency with the caching configuration

### Dockerfile

- Minimize layers where possible
- Use appropriate labels for versioning and metadata
- Group related RUN commands with `&&` and `;`
- Document environment variables in the ENV directive

### Testing

- Add GOSS tests for new functionality in `goss.yaml`
- Test files should validate expected state, not implementation details
- Use the cache test script pattern for integration testing

## Environment Variables

Key environment variables configured in the Dockerfile:

| Variable | Default | Description |
|----------|---------|-------------|
| `CACHE_MODE` | `monolithic` | Caching mode |
| `CACHE_INDEX_SIZE` | `500m` | Cache index size |
| `CACHE_DISK_SIZE` | `1000g` | Maximum cache disk size |
| `MIN_FREE_DISK` | `10g` | Minimum free disk space |
| `CACHE_MAX_AGE` | `3560d` | Maximum cache age |
| `CACHE_SLICE_SIZE` | `1m` | Slice size for large files |
| `UPSTREAM_DNS` | `8.8.8.8 8.8.4.4` | Upstream DNS servers |
| `NGINX_WORKER_PROCESSES` | `auto` | Number of nginx workers |

## Important Notes

- The container exposes ports 80, 443, and 8080
- Cache data is stored in `/data/cache`
- Logs are stored in `/data/logs`
- Cache domain configurations are cloned from the [uklans/cache-domains](https://github.com/uklans/cache-domains) repository
- Documentation is available at [lancache.net](http://lancache.net)
