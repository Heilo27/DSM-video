#!/bin/bash
# Analyze captured network traffic to extract Video Station API information

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_DIR="$REPO_ROOT/docs/api-analysis"

if [ $# -eq 0 ]; then
    echo "Usage: $0 <capture-file.json|.har|.flow>"
    echo ""
    echo "Example:"
    echo "  $0 tools/captures/videostation-api-20260114-120000.json"
    exit 1
fi

CAPTURE_FILE="$1"

if [ ! -f "$CAPTURE_FILE" ]; then
    echo "❌ Capture file not found: $CAPTURE_FILE"
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

echo "═══════════════════════════════════════════════════════════════════════════════"
echo "Analyzing Network Capture"
echo "═══════════════════════════════════════════════════════════════════════════════"
echo ""
echo "📁 Capture file: $CAPTURE_FILE"
echo "📊 Output directory: $OUTPUT_DIR"
echo ""

# Determine file type and analyze
if [[ "$CAPTURE_FILE" == *.json ]]; then
    echo "🔍 Analyzing Charles Proxy JSON export..."
    python3 << 'PYTHON'
import json
import sys
import os
from urllib.parse import urlparse, parse_qs

capture_file = sys.argv[1]
output_dir = sys.argv[2]

with open(capture_file, 'r') as f:
    data = json.load(f)

endpoints = {}
requests = []

# Extract requests
if 'sessions' in data:
    sessions = data['sessions']
elif isinstance(data, list):
    sessions = data
else:
    sessions = [data]

for session in sessions:
    if 'request' in session and 'response' in session:
        req = session['request']
        resp = session['response']
        
        url = req.get('url', '')
        method = req.get('method', 'GET')
        parsed = urlparse(url)
        
        # Extract API information
        endpoint = parsed.path
        query_params = parse_qs(parsed.query)
        
        # Check if it's a Video Station API call
        if '192.168.50.146' in url or 'videostation' in url.lower() or '/webapi/' in url or '/api/' in url:
            key = f"{method} {endpoint}"
            
            if key not in endpoints:
                endpoints[key] = {
                    'method': method,
                    'path': endpoint,
                    'base_url': f"{parsed.scheme}://{parsed.netloc}",
                    'query_params': {},
                    'headers': req.get('headers', {}),
                    'examples': []
                }
            
            # Add query params
            for k, v in query_params.items():
                if k not in endpoints[key]['query_params']:
                    endpoints[key]['query_params'][k] = v[0] if v else ''
            
            # Add example
            example = {
                'url': url,
                'request_headers': req.get('headers', {}),
                'request_body': req.get('body', ''),
                'response_status': resp.get('status', 0),
                'response_headers': resp.get('headers', {}),
                'response_body': resp.get('body', '')
            }
            endpoints[key]['examples'].append(example)

# Generate report
report = f"""# Video Station API Analysis

Generated from: {os.path.basename(capture_file)}
Date: {os.path.getmtime(capture_file)}

## API Endpoints Found

"""

for key, endpoint in sorted(endpoints.items()):
    report += f"""
### {endpoint['method']} {endpoint['path']}

**Base URL**: {endpoint['base_url']}

**Query Parameters**:
"""
    for param, value in endpoint['query_params'].items():
        report += f"- `{param}`: {value}\n"
    
    if endpoint['examples']:
        example = endpoint['examples'][0]
        report += f"""
**Example Request**:
```
{example['method']} {example['url']}
```

**Example Response**:
```
Status: {example['response_status']}
```

"""
        if example['response_body']:
            try:
                body = json.loads(example['response_body'])
                report += f"```json\n{json.dumps(body, indent=2)}\n```\n"
            except:
                report += f"```\n{example['response_body'][:500]}\n```\n"

# Save report
output_file = os.path.join(output_dir, 'api-analysis.md')
with open(output_file, 'w') as f:
    f.write(report)

print(f"✅ Analysis complete!")
print(f"📄 Report saved to: {output_file}")
print(f"📊 Found {len(endpoints)} unique API endpoints")
PYTHON
    "$CAPTURE_FILE" "$OUTPUT_DIR"
elif [[ "$CAPTURE_FILE" == *.har ]]; then
    echo "🔍 Analyzing HAR file..."
    echo "   (HAR analysis not yet implemented)"
    echo "   Consider converting to JSON or using browser DevTools"
elif [[ "$CAPTURE_FILE" == *.flow ]]; then
    echo "🔍 Analyzing mitmproxy flow file..."
    echo "   (Flow analysis not yet implemented)"
    echo "   Consider exporting to JSON from mitmproxy"
else
    echo "❌ Unsupported file format: $CAPTURE_FILE"
    echo "   Supported: .json (Charles), .har (browser), .flow (mitmproxy)"
    exit 1
fi

echo ""
echo "✅ Analysis complete!"
echo "📄 Check: $OUTPUT_DIR/api-analysis.md"
