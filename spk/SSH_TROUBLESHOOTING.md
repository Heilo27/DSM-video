# SSH Troubleshooting for SPK Installation

## Error: "subsystem request failed on channel 0"

This SSH error can occur for several reasons. Here are solutions:

## Solution 1: Use File Station (Web Interface) - EASIEST

Instead of using SCP, upload via the web interface:

1. **Open DSM** in your web browser (http://192.168.50.146)
2. **Open File Station** (file manager icon)
3. **Navigate to `/tmp/` folder** (or create it if it doesn't exist)
4. **Click "Upload"** button (top toolbar)
5. **Select the SPK file** from your Mac:
   - `/Users/home/Documents/DS Video/build/spk/DSVideoServer-0.1.0-x64.spk`
6. **Wait for upload to complete**

Then install via Package Center or SSH.

## Solution 2: Fix SSH Connection

### Check SSH Service on NAS

1. **DSM → Control Panel → Terminal & SNMP**
2. **Enable SSH service** (if not already enabled)
3. **Set port** (default is 22)
4. **Apply** and wait a few seconds

### Test Basic SSH Connection

```bash
# Test if SSH works at all
ssh ryan@192.168.50.146

# If that works, try SCP again
scp "/Users/home/Documents/DS Video/build/spk/DSVideoServer-0.1.0-x64.spk" ryan@192.168.50.146:/tmp/
```

### Use SFTP Instead of SCP

Sometimes SFTP works when SCP doesn't:

```bash
# Using sftp
sftp ryan@192.168.50.146
put "/Users/home/Documents/DS Video/build/spk/DSVideoServer-0.1.0-x64.spk" /tmp/
exit
```

## Solution 3: Install via Package Center (After Upload)

Once the file is uploaded via File Station:

1. **Open Package Center**
2. **Click "Manual Install"**
3. **Browse to `/tmp/DSVideoServer-0.1.0-x64.spk`**
4. **Install** (acknowledge any warnings)

## Solution 4: Use Finder/SMB Share

1. **Enable SMB** on your NAS (Control Panel → File Services → SMB)
2. **Connect from Finder**:
   - Press `Cmd+K`
   - Enter: `smb://192.168.50.146`
   - Connect with your credentials
3. **Navigate to `/tmp/`** (or any shared folder)
4. **Drag and drop** the SPK file

## Solution 5: Fix SSH Subsystem

If SSH is enabled but still failing, try:

```bash
# Connect with verbose output to see the error
ssh -v ryan@192.168.50.146

# Or try forcing a specific SSH version
ssh -o PreferredAuthentications=password ryan@192.168.50.146
```

## Recommended Approach

**For now, use File Station (Solution 1)** - it's the most reliable method and doesn't require SSH to work perfectly.

After uploading via File Station, you can:
- Install via Package Center (easiest)
- Or SSH in and use `synopkg install` (if SSH works for commands)
