# Video Station Connection Issue

## Problem

The DS Video iOS app cannot connect to the original Video Station because:

1. **API Format Mismatch**: 
   - App uses: REST API (`/api/v1/auth/login`)
   - Video Station uses: Synology WebAPI (`/webapi/entry.cgi?api=SYNO.API.*`)

2. **Port/URL Configuration**:
   - App default: `http://localhost:8090`
   - Video Station: Usually `http://<NAS_IP>:5000` or `http://<NAS_IP>:9080`

## Solution Options

### Option 1: Find Video Station's Actual Port and API

First, let's determine Video Station's actual configuration:

**On your NAS (SSH):**
```bash
ssh ryan@192.168.50.146

# Check Video Station port
sudo synopkg status VideoStation
sudo netstat -tlnp | grep -i video

# Check Video Station web interface
sudo find /var/packages/VideoStation -name "*.conf" | xargs grep -i port
```

**Or check in DSM:**
1. Open **Package Center**
2. Find **Video Station**
3. Click **Open** (this will show the URL/port)

### Option 2: Use Network Capture to Find API

Use Charles Proxy to capture what the **official DS Video app** does:

1. Install the official DS Video app from App Store
2. Connect to Video Station
3. Capture the API calls
4. See what endpoints and format it uses

### Option 3: Create WebAPI Compatibility Layer

Update the iOS app to support Video Station's WebAPI format, or create a proxy/translator.

## Quick Test: Check Video Station Port

Try these URLs in a browser to find Video Station:

- `http://192.168.50.146:5000`
- `http://192.168.50.146:9080`
- `http://192.168.50.146:5001` (HTTPS)
- `http://192.168.50.146:5000/webapi/entry.cgi?api=SYNO.API.Info&version=1&method=query`

One of these should show Video Station's interface or API response.

## Next Steps

1. **Find Video Station's port** (see above)
2. **Capture API traffic** from official DS Video app
3. **Update iOS app** to support WebAPI format, or
4. **Create compatibility layer** in backend
