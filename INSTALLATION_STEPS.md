# DS Video Server - Installation Steps

Since SPK format is causing Error 263, we'll install manually.

## Step 1: Upload Binary to NAS

**Option A: File Station (Easiest)**
1. Open DSM web interface
2. Go to **File Station**
3. Navigate to `/tmp/`
4. Click **Upload**
5. Select: `build/spk/DSVideoServer/target/backend/dsvideo-backend`
6. Rename to: `dsvideo-backend` (if needed)

**Option B: SCP (Command Line)**
```bash
scp "/Users/home/Documents/DS Video/build/spk/DSVideoServer/target/backend/dsvideo-backend" \
    ryan@192.168.50.146:/tmp/dsvideo-backend
```

## Step 2: Upload Installation Script

Upload `install-on-nas.sh` to your NAS:
```bash
scp install-on-nas.sh ryan@192.168.50.146:/tmp/
```

Or via File Station: Upload `install-on-nas.sh` to `/tmp/`

## Step 3: Run Installation on NAS

SSH into your NAS and run:
```bash
ssh ryan@192.168.50.146
chmod +x /tmp/install-on-nas.sh
sudo /tmp/install-on-nas.sh
```

## Step 4: Verify Installation

```bash
# Check if service is running
sudo /var/packages/DSVideoServer/scripts/start-stop-status status

# Check logs
tail -f /var/log/packages/DSVideoServer.log

# Test backend
curl http://192.168.50.146:8080/api/v1/admin/status
```

## Step 5: Configure iOS App

In the iOS app, set base URL to: `http://192.168.50.146:8080`

## Service Management

```bash
# Start
sudo /var/packages/DSVideoServer/scripts/start-stop-status start

# Stop
sudo /var/packages/DSVideoServer/scripts/start-stop-status stop

# Status
sudo /var/packages/DSVideoServer/scripts/start-stop-status status

# View logs
tail -f /var/log/packages/DSVideoServer.log
```
