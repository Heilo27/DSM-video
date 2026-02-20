# Synology NAS Architecture Guide

## Finding Your NAS Architecture

The "invalid file format" error is often caused by an architecture mismatch. You need to build the SPK for your specific NAS architecture.

### Method 1: Check via DSM Web Interface

1. Open **DSM** (Synology web interface)
2. Go to **Control Panel** → **Info Center**
3. Look for **CPU Architecture** or **Platform**
4. Common values:
   - `x86_64` or `amd64` → Intel-based NAS
   - `armv8` or `aarch64` or `arm64` → ARM-based NAS

### Method 2: Check via SSH

SSH into your NAS and run:
```bash
uname -m
```

Common outputs:
- `x86_64` → Use: `./spk/build-spk-macos.sh amd64`
- `aarch64` or `armv8` → Use: `./spk/build-spk-macos.sh arm64`

### Method 3: Check Your NAS Model

Look up your Synology NAS model to determine architecture:

**ARM-based (most common):**
- DS220j, DS218, DS218play, DS218+
- DS720+, DS920+, DS1520+
- Most newer consumer models

**x86_64/Intel-based:**
- DS1819+, DS2419+
- DS1621xs+, DS3622xs+
- Enterprise models

### Building the Correct SPK

Once you know your architecture:

```bash
# For ARM-based NAS (most common)
./spk/build-spk-macos.sh arm64

# For Intel-based NAS
./spk/build-spk-macos.sh amd64
```

### Verifying the SPK

After building, verify it matches your NAS:

```bash
# Check what architecture the binary is built for
./spk/diagnose-spk.sh
```

Look for the "Binary type" line - it should match your NAS:
- ARM NAS: `ELF 64-bit LSB executable, ARM aarch64`
- Intel NAS: `ELF 64-bit LSB executable, x86-64`

### Common Issues

**"Invalid file format" on ARM NAS:**
- You built for `amd64` → Rebuild with `arm64`

**"Invalid file format" on Intel NAS:**
- You built for `arm64` → Rebuild with `amd64`

**Still getting errors after architecture match:**
- Check DSM version (requires 7.2+)
- Enable unsigned package installation in Package Center settings
- Verify the SPK structure with `./spk/validate-spk.sh`
