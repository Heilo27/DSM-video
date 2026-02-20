# Building SPK with Synology's Official Toolchain (Docker)

If manual SPK creation continues to fail with error 263, you may need to use Synology's official `pkgscripts-ng` toolchain. This requires Docker.

## Prerequisites

1. **Install Docker Desktop** for macOS: https://www.docker.com/products/docker-desktop

2. **Download Synology Toolkit**:
   - Visit: https://archive.synology.com/download/ToolChain/toolkit/7.2
   - Download: `base_env-7.2.txz` (base platform)

## Quick Docker Build (Alternative)

If you have Docker installed, you can use a Synology toolkit container:

```bash
# Pull Synology toolkit image (if available)
# Or use the base_env in a container

# Mount your project
docker run -it -v "/Users/home/Documents/DS Video:/workspace" \
  synology/toolkit:7.2 \
  /bin/bash

# Inside container, build SPK
cd /workspace
# Use pkgscripts-ng to build
```

## Manual Docker Setup

1. **Extract toolkit**:
   ```bash
   cd /tmp
   tar -xf base_env-7.2.txz
   ```

2. **Create Dockerfile**:
   ```dockerfile
   FROM ubuntu:20.04
   # Install dependencies and Synology toolkit
   ```

3. **Build and run**:
   ```bash
   docker build -t synology-builder .
   docker run -v "$(pwd):/workspace" synology-builder
   ```

## Current Status

The manual SPK creation should work, but if error 263 persists, the official toolchain may be required. The minimal test SPK (`test-minimal.spk`) can help isolate whether the issue is format or content.
