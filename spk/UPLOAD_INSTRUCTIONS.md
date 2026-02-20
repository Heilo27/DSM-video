# Uploading SPK to Synology NAS

## Method 1: SCP (Command Line) - Recommended

### From macOS Terminal:

```bash
# Navigate to the project directory
cd "/Users/home/Documents/DS Video"

# Upload the SPK file (replace YOUR_NAS_IP with your actual NAS IP address)
scp "build/spk/DSVideoServer-0.1.0-x64.spk" admin@YOUR_NAS_IP:/tmp/
```

**Example:**
```bash
scp "build/spk/DSVideoServer-0.1.0-x64.spk" admin@192.168.1.100:/tmp/
```

**Note:** The path has spaces, so use quotes around the full path if needed:
```bash
scp "/Users/home/Documents/DS Video/build/spk/DSVideoServer-0.1.0-x64.spk" admin@YOUR_NAS_IP:/tmp/
```

## Method 2: File Station (Web Interface)

1. Open **File Station** in DSM
2. Navigate to `/tmp/` folder
3. Click **Upload** button
4. Select `DSVideoServer-0.1.0-x64.spk` from your Mac
5. Wait for upload to complete

## Method 3: Drag and Drop via Finder

1. Enable **SMB** or **AFP** sharing on your NAS
2. Connect to your NAS from Finder:
   - Press `Cmd+K` in Finder
   - Enter: `smb://YOUR_NAS_IP` or `afp://YOUR_NAS_IP`
   - Connect with your admin credentials
3. Navigate to `/tmp/` folder
4. Drag and drop the SPK file

## Method 4: Using Full Absolute Path

If relative paths don't work, use the full absolute path:

```bash
scp "/Users/home/Documents/DS Video/build/spk/DSVideoServer-0.1.0-x64.spk" admin@YOUR_NAS_IP:/tmp/
```

## Troubleshooting

**"No such file or directory" error:**
- Make sure you're in the correct directory: `cd "/Users/home/Documents/DS Video"`
- Use quotes around paths with spaces
- Check the file exists: `ls -lh build/spk/DSVideoServer-0.1.0-x64.spk`

**"Permission denied" error:**
- Make sure SSH is enabled on your NAS
- Use `admin` user or a user with SSH access
- Check your NAS IP address is correct

**"Connection refused" error:**
- Enable SSH: Control Panel → Terminal & SNMP → Enable SSH service
- Check your NAS IP address
- Make sure you're on the same network

## After Upload

Once uploaded, SSH into your NAS and install:

```bash
ssh admin@YOUR_NAS_IP
sudo synopkg install /tmp/DSVideoServer-0.1.0-x64.spk
```
