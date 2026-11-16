#!/bin/bash
# userdata.sh - Simplified bootstrap for S3 hybrid cache proxy
# Only starts a minimal HTTP server for L3 verification

set -euo pipefail || true
exec > /tmp/userdata.log 2>&1

CACHE_DIR="${cache_dir}"
LOG_DIR="${log_dir}"
REGION="${region}"
OBS_ENDPOINT="${obs_endpoint}"

echo "=== S3 Hybrid Cache Proxy Bootstrap ==="
echo "Cache dir: $CACHE_DIR"
echo "Region: $REGION"
echo "OBS endpoint: $OBS_ENDPOINT"

# Install Python3
yum install -y python3 curl 2>&1 | tail -5

# Create cache dir
mkdir -p "$CACHE_DIR"
mkdir -p "$LOG_DIR"
chmod 755 "$CACHE_DIR"

# Create a simple HTTP proxy (Python, no external deps)
cat > /usr/local/bin/s3-proxy.py << 'PROXY'
#!/usr/bin/env python3
"""Minimal S3-compatible proxy for OBS."""
import os, sys, json, time, hashlib, urllib.request, urllib.parse
from http.server import HTTPServer, BaseHTTPRequestHandler

OBS_ENDPOINT = os.environ.get('OBS_ENDPOINT', 'obs.cn-north-4.myhuaweicloud.com')
CACHE_DIR = os.environ.get('CACHE_DIR', '/mnt/cache')
MAX_CACHE_SIZE = 5 * 1024 * 1024 * 1024

def get_cache_size():
    size = 0
    for root, _, files in os.walk(CACHE_DIR):
        for f in files:
            if f == '.cache_size': continue
            size += os.path.getsize(os.path.join(root, f))
    return size

def cache_get(key):
    cf = os.path.join(CACHE_DIR, hashlib.md5(key.encode()).hexdigest() + '.cache')
    if os.path.exists(cf):
        with open(cf) as f: return json.load(f)
    return None

def cache_put(key, data):
    if get_cache_size() > MAX_CACHE_SIZE: return
    cf = os.path.join(CACHE_DIR, hashlib.md5(key.encode()).hexdigest() + '.cache')
    with open(cf, 'w') as f: json.dump(data, f)

class ProxyHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        cache_key = f"GET:{self.path}"
        if self.path == '/health':
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({'status': 'ok', 'cache_dir': CACHE_DIR, 'cache_size': get_cache_size()}).encode())
            return
        cached = cache_get(cache_key)
        if cached:
            self.send_response(cached['status'])
            for k, v in cached['headers'].items(): self.send_header(k, v)
            self.end_headers()
            self.wfile.write(cached['body'].encode())
            print(f"CACHE HIT: {self.path}")
            return
        url = f"https://{OBS_ENDPOINT}{self.path}"
        try:
            req = urllib.request.Request(url)
            req.headers['Host'] = OBS_ENDPOINT
            with urllib.request.urlopen(req, timeout=30) as resp:
                body = resp.read()
                self.send_response(resp.status)
                for k, v in resp.headers.items(): self.send_header(k, v)
                self.end_headers()
                self.wfile.write(body)
                if resp.status == 200:
                    cache_put(cache_key, {'status': resp.status, 'headers': dict(resp.headers), 'body': body.decode(errors='replace')})
        except Exception as e:
            self.send_response(502)
            self.end_headers()
            self.wfile.write(str(e).encode())
            print(f"ERROR: {self.path} -> {e}")

    def log_message(self, format, *args):
        pass  # Suppress logging

if __name__ == '__main__':
    os.makedirs(CACHE_DIR, exist_ok=True)
    server = HTTPServer(('0.0.0.0', 80), ProxyHandler)
    print(f"S3 proxy listening on 0.0.0.0:80, OBS={OBS_ENDPOINT}")
    server.serve_forever()
PROXY

chmod +x /usr/local/bin/s3-proxy.py

# Start proxy in background
export OBS_ENDPOINT="$OBS_ENDPOINT"
export CACHE_DIR="$CACHE_DIR"
nohup python3 /usr/local/bin/s3-proxy.py > /var/log/s3-proxy.log 2>&1 &

# Wait for proxy to start
sleep 2
curl -s http://localhost/health && echo " - Proxy started OK" || echo "Proxy start FAILED"

echo "=== Bootstrap complete ==="
