# Installing DSVideoServer SPK via SSH

If Package Center doesn't allow unsigned packages, you can install via SSH:

## Method 1: SSH Installation (Recommended)

1. **Upload the SPK to your NAS:**
   ```bash
   # From your Mac terminal
   scp build/spk/DSVideoServer-0.1.0-x64.spk ryan@192.168.50.146:/tmp/
   ```

2. **SSH into your NAS:**
   ```bash
   ssh ryan@192.168.50.146
   ```

3. **Install the package:**
   ```bash
   sudo synopkg install /tmp/DSVideoServer-0.1.0-x64.spk
   ```

4. **Check installation status:**
   ```bash
   sudo synopkg status DSVideoServer
   ```

5. **Start the package:**
   ```bash
   sudo synopkg start DSVideoServer
   ```

## Method 2: Package Center Settings

The setting location varies by DSM version:

### DSM 7.x:
1. Open **Package Center**
2. Click **Settings** (gear icon in top right)
3. Go to **General** tab
4. Look for **Trust Level** or **Package Source**
5. Select **Any publisher** or **Synology Inc. and trusted publishers**

### If the setting is missing:
- Some DSM versions don't show this option
- Use SSH installation (Method 1) instead

## Method 3: Manual File Upload + SSH Install

1. **Upload via File Station:**
   - Open File Station in DSM web interface
   - Navigate to `/tmp/` or create a folder
   - Upload `DSVideoServer-0.1.0-x64.spk`

2. **SSH and install:**
   ```bash
   ssh ryan@192.168.50.146
   sudo synopkg install /tmp/DSVideoServer-0.1.0-x64.spk
   sudo synopkg start DSVideoServer
   ```

## Troubleshooting

If installation fails, check logs:
```bash
sudo cat /var/log/packages/DSVideoServer.log
```

Or check package status:
```bash
sudo synopkg list | grep DSVideoServer
```
