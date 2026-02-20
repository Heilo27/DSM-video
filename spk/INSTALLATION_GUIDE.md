# DS Video Server - Installation Guide

## Problem: Package Center File Browser Limitation

Package Center's "Manual Install" only allows browsing files on your local computer, not on the NAS. This guide provides alternative installation methods.

## Solution 1: SSH Installation (Recommended)

Use SSH to upload and install the package directly on the NAS.

### Quick Install Script

Run this from your Mac:

```bash
cd "/Users/home/Documents/DS Video"
./spk/install-via-ssh.sh
```

This script will:
1. Upload the SPK to your NAS
2. Install it via SSH
3. Start the service

### Manual SSH Installation

If you prefer to do it manually:

```bash
# Step 1: Upload SPK
scp "/Users/home/Documents/DS Video/build/spk/DSVideoServer-0.1.0-x64.spk" \
    ryan@192.168.50.146:/tmp/

# Step 2: SSH into NAS
ssh ryan@192.168.50.146

# Step 3: Clean up any previous installation (if needed)
sudo rm -rf /var/packages/DSVideoServer
sudo rm -rf /volume1/@appdata/DSVideoServer
sudo rm -f /var/log/packages/DSVideoServer.log

# Step 4: Install package
sudo synopkg install /tmp/DSVideoServer-0.1.0-x64.spk

# Step 5: Start service
sudo synopkg start DSVideoServer

# Step 6: Check status
sudo synopkg status DSVideoServer

# Step 7: View logs
tail -f /var/log/packages/DSVideoServer.log
```

## Solution 2: File Station Upload + SSH Install

1. **Upload via File Station**:
   - Open DSM → File Station
   - Navigate to `/tmp/`
   - Upload `DSVideoServer-0.1.0-x64.spk`

2. **Install via SSH**:
   ```bash
   ssh ryan@192.168.50.146
   sudo synopkg install /tmp/DSVideoServer-0.1.0-x64.spk
   sudo synopkg start DSVideoServer
   ```

## Solution 3: Docker Alternative

If SPK installation continues to fail, consider running the backend in Docker:

### Install Docker on NAS
1. Open Package Center
2. Install "Docker" package

### Create Docker Container
```bash
# On your Mac, build Docker image
cd "/Users/home/Documents/DS Video/backend"
docker build -t dsvideo-backend .

# Save image
docker save dsvideo-backend | gzip > dsvideo-backend.tar.gz

# Upload to NAS
scp dsvideo-backend.tar.gz ryan@192.168.50.146:/tmp/

# On NAS, load and run
ssh ryan@192.168.50.146
docker load < /tmp/dsvideo-backend.tar.gz
docker run -d \
  --name dsvideo-backend \
  -p 8080:8080 \
  -v /volume1/video:/data/video \
  -v /volume1/@appdata/DSVideoServer:/data/db \
  dsvideo-backend
```

## Troubleshooting

### Error 263: "failed to sort spks"

This usually means:
1. **Residual data** from previous attempts → Clean up (see above)
2. **Package format issue** → Rebuild with Docker: `./spk/build-spk-docker.sh amd64`
3. **Architecture mismatch** → Verify your NAS is x86_64 (DS923+ is correct)

### Check Installation Logs

```bash
ssh ryan@192.168.50.146
sudo tail -50 /var/log/synopkg.log
```

### Verify Package Structure

```bash
# On your Mac
cd "/Users/home/Documents/DS Video"
mkdir test && cd test
tar -xzf ../build/spk/DSVideoServer-0.1.0-x64.spk
ls -la
# Should show: INFO, package.tgz, scripts/
```

## Service Management

Once installed, manage the service with:

```bash
ssh ryan@192.168.50.146

# Start
sudo synopkg start DSVideoServer

# Stop
sudo synopkg stop DSVideoServer

# Status
sudo synopkg status DSVideoServer

# Restart
sudo synopkg stop DSVideoServer && sudo synopkg start DSVideoServer

# View logs
tail -f /var/log/packages/DSVideoServer.log
```

## Accessing the Service

After installation, the backend should be available at:
- **URL**: `http://192.168.50.146:8080`
- **API**: `http://192.168.50.146:8080/api/`

Test it:
```bash
curl http://192.168.50.146:8080/api/health
```
