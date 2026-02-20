# Fixing Error 263: "failed to sort spks"

Error 263 typically means Synology can't parse the SPK metadata. Try these steps in order:

## Step 1: Clean Up Residual Data

Previous installation attempts may have left corrupted data. Clean it up:

```bash
# SSH into your NAS
ssh ryan@192.168.50.146

# Run cleanup (or copy cleanup-nas.sh and run it)
sudo rm -rf /var/packages/DSVideoServer
sudo rm -rf /volume1/@appdata/DSVideoServer
sudo rm -f /var/log/packages/DSVideoServer.log

# Check all volumes
for vol in /volume*; do
    sudo rm -rf "${vol}/@appdata/DSVideoServer" 2>/dev/null
done
```

## Step 2: Verify SPK Structure

The SPK should have this exact structure:
- `INFO` (file, at root)
- `package.tgz` (file, at root)  
- `scripts/` (directory, at root)

Verify:
```bash
# On your Mac
cd "/Users/home/Documents/DS Video"
mkdir test && cd test
tar -xzf ../build/spk/DSVideoServer-0.1.0-x64.spk
ls -la
# Should show: INFO, package.tgz, scripts/
```

## Step 3: Check INFO File Format

The INFO file must:
- Use Unix line endings (LF, not CRLF)
- Have no trailing newline
- Have `arch="x86_64"` (not "noarch")
- Have `os_min_ver="7.2-00000"` or higher

Verify:
```bash
# Extract and check
tar -xzf build/spk/DSVideoServer-0.1.0-x64.spk
cat INFO
# Should show arch="x86_64" for your DS923+
```

## Step 4: Rebuild with Docker

The Docker build ensures Linux-compatible format:

```bash
cd "/Users/home/Documents/DS Video"
./spk/build-spk-docker.sh amd64
```

## Step 5: Upload and Install

1. **Upload via File Station** (web interface):
   - Go to File Station
   - Upload `build/spk/DSVideoServer-0.1.0-x64.spk` to `/tmp/`

2. **Install via Package Center**:
   - Open Package Center → Manual Install
   - Select the uploaded SPK

3. **Or via SSH**:
   ```bash
   scp build/spk/DSVideoServer-0.1.0-x64.spk ryan@192.168.50.146:/tmp/
   ssh ryan@192.168.50.146
   sudo synopkg install /tmp/DSVideoServer-0.1.0-x64.spk
   ```

## Step 6: Check DSM Logs

If it still fails, check detailed logs:

```bash
ssh ryan@192.168.50.146
sudo tail -f /var/log/synopkg.log
# Then try installing and watch for errors
```

## Common Causes

1. **Residual data** from previous attempts → Clean up (Step 1)
2. **Wrong architecture** in INFO → Should be `x86_64` for DS923+
3. **INFO file format** → Unix line endings, no trailing newline
4. **Package structure** → Must have INFO, package.tgz, scripts/ at root

## Still Failing?

If error 263 persists after all steps:
- The SPK format may need Synology's official `pkgscripts-ng` tool
- Consider using a different installation method (manual file placement)
- Check if your DSM version supports third-party packages
