# SPK Installation Troubleshooting

## "Incorrect Format" Error

If you get an "incorrect format" error when installing the SPK, try these steps:

### 1. Verify SPK Structure

The SPK should contain:
- `INFO` (package metadata)
- `package.tgz` (package contents: target/, var/)
- `scripts/` (lifecycle scripts)

Verify structure:
```bash
mkdir test && cd test
tar -xzf DSVideoServer-0.1.0-armv8.spk
ls -la
# Should show: INFO, package.tgz, scripts/
```

### 2. Check Architecture Match

Ensure the SPK architecture matches your NAS:
- **ARM64** (most Synology devices): Use `arm64` build
- **x86_64** (Intel-based): Use `amd64` build

Find your NAS architecture:
```bash
# On your Synology NAS, run:
uname -m
```

### 3. DSM Version Compatibility

The package requires DSM 7.2+. Check your DSM version:
- DSM → Control Panel → Info Center → DSM Version

### 4. Package Center Settings

Enable installation of unsigned packages:
1. Open **Package Center**
2. Click **Settings** (gear icon)
3. Under **General**, check:
   - ✅ "Allow installation of packages from Synology Inc. and trusted publishers"
   - Or: ✅ "Any publisher" (for unsigned packages)

### 5. Rebuild with Correct Architecture

If architecture mismatch:
```bash
# For ARM64 NAS (most common)
./spk/build-spk-macos.sh arm64

# For x86_64 NAS (Intel-based)
./spk/build-spk-macos.sh amd64
```

### 6. Verify INFO File Format

The INFO file should:
- Use Unix line endings (LF, not CRLF)
- Have no trailing newline
- Contain required fields

Check INFO file:
```bash
tar -xzf DSVideoServer-0.1.0-armv8.spk
file INFO  # Should show "ASCII text"
cat INFO  # Should show package metadata
```

### 7. Common Issues

**Issue**: "Invalid file format"
- **Solution**: Rebuild the SPK with the correct architecture

**Issue**: "Package not compatible"
- **Solution**: Check DSM version (requires 7.2+)

**Issue**: "Cannot install unsigned package"
- **Solution**: Enable unsigned package installation in Package Center settings

### 8. Manual Verification

Extract and verify SPK contents:
```bash
mkdir verify && cd verify
tar -xzf ../DSVideoServer-0.1.0-armv8.spk

# Check structure
ls -la
# Should show: INFO, package.tgz, scripts/

# Check INFO
cat INFO

# Check package contents
tar -tzf package.tgz | head -10
# Should show: target/, target/backend/, target/backend/dsvideo-backend, var/

# Check scripts
ls -la scripts/
# Should show: start-stop-status (executable)
```

### 9. Alternative: Use Synology Toolkit

If manual SPK creation doesn't work, use Synology's official toolkit:
1. Download `pkgscripts-ng` from [Synology Archive](https://archive.synology.com/download/ToolChain/toolkit/7.2)
2. Run in Docker/Linux environment
3. Use `PkgCreate.py` to build the SPK

### 10. Get Help

If issues persist:
- Check Synology Developer Guide: https://global.download.synology.com/download/Document/Software/DeveloperGuide/Os/DSM/All/enu/DSM_Developer_Guide_7_enu.pdf
- Synology Community Forums
- Verify your NAS model and architecture compatibility
