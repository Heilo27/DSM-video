# Manual Video Station Examination on NAS

Since SSH authentication needs to be configured, here are manual commands to run on your NAS.

## SSH into Your NAS

```bash
ssh ryan@192.168.50.146
```

(You may need to set up SSH keys or use password authentication)

## Once Connected, Run These Commands

### 1. Check Video Station Installation

```bash
# Check if Video Station is installed
sudo synopkg status VideoStation

# Check installation path
ls -la /var/packages/VideoStation/
```

### 2. Find API/Web Files

```bash
# Find PHP files (likely contain API endpoints)
sudo find /var/packages/VideoStation/ -name "*.php" | head -30

# Find Python files
sudo find /var/packages/VideoStation/ -name "*.py" | head -30

# Find JavaScript files
sudo find /var/packages/VideoStation/ -name "*.js" | head -30
```

### 3. Search for API Endpoints

```bash
# Search for Video Station API references
sudo grep -r "SYNO.API.VideoStation" /var/packages/VideoStation/ 2>/dev/null | head -20

# Search for webapi references
sudo grep -r "webapi" /var/packages/VideoStation/ 2>/dev/null | head -20

# Search for /api/ endpoints
sudo grep -r "/api/" /var/packages/VideoStation/ 2>/dev/null | head -20
```

### 4. Examine UI Directory

```bash
# List UI directory (from INFO: dsmuidir="ui")
sudo ls -la /var/packages/VideoStation/ui/

# Find PHP files in UI (likely API handlers)
sudo find /var/packages/VideoStation/ui/ -name "*.php" | head -20
```

### 5. Check Configuration Files

```bash
# Find configuration files
sudo find /var/packages/VideoStation/ -name "*.conf" -o -name "*.json" -o -name "*.xml" | head -20
```

### 6. Copy Files for Analysis (Optional)

If you want to copy files to your Mac for analysis:

```bash
# On NAS, create a tar archive
sudo tar -czf /tmp/videostation-files.tar.gz \
  /var/packages/VideoStation/ui/ \
  /var/packages/VideoStation/target/etc/ 2>/dev/null

# Make it readable
sudo chmod 644 /tmp/videostation-files.tar.gz
```

Then on your Mac:

```bash
# Download the archive
scp ryan@192.168.50.146:/tmp/videostation-files.tar.gz ~/Downloads/

# Extract
cd ~/Downloads
tar -xzf videostation-files.tar.gz
```

## What to Look For

1. **API Endpoint Definitions**
   - Look for files that define `SYNO.API.VideoStation.*` endpoints
   - Check for route definitions or API handlers

2. **Request/Response Formats**
   - Look for JSON structures
   - Check for data models

3. **Authentication**
   - Look for login/session handling
   - Check for token management

4. **Database Schema**
   - Look for SQL files or database initialization scripts
   - Check for schema definitions

## Alternative: Use Network Capture

Instead of examining files, you can capture API traffic:

1. Set up Charles Proxy (see `tools/QUICK_START.md`)
2. Run DS Video iOS app
3. Capture API calls
4. Analyze the captured traffic

This is often easier and more accurate than reverse engineering code.
