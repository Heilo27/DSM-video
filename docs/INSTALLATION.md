# Manual Installation (Alternative to SPK)

If SPK installation continues to fail with Error 263, you can install the backend manually:

## Step 1: Upload Binary to NAS

```bash
# Upload the compiled binary
scp "/Users/home/Documents/DS Video/build/spk/DSVideoServer/target/backend/dsvideo-backend" \
    ryan@192.168.50.146:/tmp/
```

## Step 2: SSH and Set Up Service

```bash
ssh ryan@192.168.50.146

# Create package directory structure
sudo mkdir -p /var/packages/DSVideoServer/target/backend
sudo mkdir -p /var/packages/DSVideoServer/var
sudo mkdir -p /var/packages/DSVideoServer/scripts

# Copy binary
sudo cp /tmp/dsvideo-backend /var/packages/DSVideoServer/target/backend/
sudo chmod +x /var/packages/DSVideoServer/target/backend/dsvideo-backend

# Copy start script
sudo cp /Users/home/Documents/DS\ Video/spk/DSVideoServer/scripts/start-stop-status \
    /var/packages/DSVideoServer/scripts/
sudo chmod +x /var/packages/DSVideoServer/scripts/start-stop-status

# Set environment variables
export DSVIDEO_PORT=8080
export DSVIDEO_BASE_URL="http://192.168.50.146:8080"
export DSVIDEO_DB_PATH="/var/packages/DSVideoServer/var/dsvideo.db"
export DSVIDEO_MOVIES_PATH="/volume1/video/Movies"
export DSVIDEO_TV_PATH="/volume1/video/TV"
export DSVIDEO_HOME_PATH="/volume1/video/Home"

# Start manually
sudo /var/packages/DSVideoServer/scripts/start-stop-status start
```

## Step 3: Create Systemd Service (Optional)

For automatic startup, create a systemd service:

```bash
sudo nano /etc/systemd/system/dsvideo-server.service
```

Add:
```ini
[Unit]
Description=DS Video Server
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/var/packages/DSVideoServer
Environment="DSVIDEO_PORT=8080"
Environment="DSVIDEO_BASE_URL=http://192.168.50.146:8080"
Environment="DSVIDEO_DB_PATH=/var/packages/DSVideoServer/var/dsvideo.db"
Environment="DSVIDEO_MOVIES_PATH=/volume1/video/Movies"
Environment="DSVIDEO_TV_PATH=/volume1/video/TV"
Environment="DSVIDEO_HOME_PATH=/volume1/video/Home"
ExecStart=/var/packages/DSVideoServer/target/backend/dsvideo-backend
Restart=always

[Install]
WantedBy=multi-user.target
```

Then:
```bash
sudo systemctl daemon-reload
sudo systemctl enable dsvideo-server
sudo systemctl start dsvideo-server
sudo systemctl status dsvideo-server
```
