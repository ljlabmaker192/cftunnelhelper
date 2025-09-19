#!/bin/bash

# CF Tunnel Helper - Simple Auto-Fix Edition
# One-click install that just works on any Ubuntu server

set -euo pipefail

APP_NAME="cftunnel"
INSTALL_DIR="/opt/$APP_NAME"
LOG_DIR="/var/log/$APP_NAME"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Check root
[[ $EUID -eq 0 ]] || { error "Run with sudo"; exit 1; }

# Auto-detect and fix system
log "Setting up CF Tunnel Helper..."
apt update -qq
apt install -y python3 python3-pip curl wget systemd 2>/dev/null || true
pip3 install flask requests psutil --break-system-packages 2>/dev/null || pip3 install flask requests psutil

# Install cloudflared
if ! command -v cloudflared &>/dev/null; then
    log "Installing cloudflared..."
    arch=$(uname -m)
    case "$arch" in
        x86_64) arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        *) arch="amd64" ;;
    esac
    
    wget -q -O /tmp/cf.deb "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}.deb"
    dpkg -i /tmp/cf.deb 2>/dev/null || apt install -f -y
    rm -f /tmp/cf.deb
fi

# Create directories
mkdir -p "$INSTALL_DIR" "$LOG_DIR"

# Create simple Python app
cat > "$INSTALL_DIR/app.py" << 'EOF'
#!/usr/bin/env python3
import os, json, subprocess, threading, time, socket
from flask import Flask, render_template_string, request, jsonify
import psutil

app = Flask(__name__)
app.secret_key = os.urandom(24)

class TunnelManager:
    def __init__(self):
        self.auth_in_progress = False
        
    def run_cmd(self, cmd):
        try:
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
            return {'ok': result.returncode == 0, 'out': result.stdout.strip(), 'err': result.stderr.strip()}
        except:
            return {'ok': False, 'out': '', 'err': 'Command failed'}
    
    def is_authed(self):
        return os.path.exists(os.path.expanduser("~/.cloudflared/cert.pem"))
    
    def auth_start(self):
        if self.auth_in_progress:
            return {'ok': True, 'msg': 'Auth in progress'}
        self.auth_in_progress = True
        threading.Thread(target=self._do_auth, daemon=True).start()
        time.sleep(1)
        return {'ok': True, 'msg': 'Auth started - check your browser'}
    
    def _do_auth(self):
        try:
            self.run_cmd(['cloudflared', 'tunnel', 'login'])
        finally:
            self.auth_in_progress = False
    
    def list_tunnels(self):
        if not self.is_authed():
            return []
        result = self.run_cmd(['cloudflared', 'tunnel', 'list', '--output', 'json'])
        if result['ok'] and result['out']:
            try:
                return json.loads(result['out'])
            except:
                pass
        return []
    
    def create_tunnel(self, name):
        if not name or not self.is_authed():
            return {'ok': False, 'msg': 'Need name and auth'}
        name = name.lower().replace(' ', '-')
        result = self.run_cmd(['cloudflared', 'tunnel', 'create', name])
        return {'ok': result['ok'], 'msg': f"Created {name}" if result['ok'] else result['err']}
    
    def delete_tunnel(self, name):
        if not name or not self.is_authed():
            return {'ok': False, 'msg': 'Need name and auth'}
        self.run_cmd(['cloudflared', 'tunnel', 'cleanup', name])
        result = self.run_cmd(['cloudflared', 'tunnel', 'delete', name, '--force'])
        return {'ok': result['ok'], 'msg': f"Deleted {name}" if result['ok'] else result['err']}
    
    def route_dns(self, tunnel, hostname):
        if not tunnel or not hostname or not self.is_authed():
            return {'ok': False, 'msg': 'Need tunnel, hostname and auth'}
        result = self.run_cmd(['cloudflared', 'tunnel', 'route', 'dns', tunnel, hostname])
        return {'ok': result['ok'], 'msg': f"Routed {hostname} to {tunnel}" if result['ok'] else result['err']}

manager = TunnelManager()

HTML = '''<!DOCTYPE html>
<html><head>
<title>CF Tunnel Manager</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
* { box-sizing: border-box; margin: 0; padding: 0; }
body { font: 14px Arial; background: #1a1a1a; color: #fff; padding: 20px; }
.container { max-width: 1200px; margin: 0 auto; }
.header { text-align: center; margin-bottom: 30px; padding: 20px; background: #2a2a2a; border-radius: 8px; }
.header h1 { color: #0ea5e9; margin-bottom: 10px; }
.card { background: #2a2a2a; border-radius: 8px; padding: 20px; margin-bottom: 20px; }
.card h3 { color: #0ea5e9; margin-bottom: 15px; }
.form-group { margin-bottom: 15px; }
.form-group label { display: block; margin-bottom: 5px; color: #ccc; }
.form-control { width: 100%; padding: 10px; border: 1px solid #555; background: #333; color: #fff; border-radius: 4px; }
.btn { padding: 10px 20px; border: none; border-radius: 4px; cursor: pointer; margin: 5px; font-weight: bold; }
.btn-primary { background: #0ea5e9; color: white; }
.btn-success { background: #10b981; color: white; }
.btn-danger { background: #ef4444; color: white; }
.btn-warning { background: #f59e0b; color: white; }
.btn:hover { opacity: 0.8; }
.btn:disabled { opacity: 0.5; cursor: not-allowed; }
.status { padding: 10px; border-radius: 4px; margin: 10px 0; }
.status-success { background: #065f46; color: #10b981; }
.status-error { background: #7f1d1d; color: #ef4444; }
.status-warning { background: #78350f; color: #f59e0b; }
.output { width: 100%; height: 200px; background: #111; color: #0ea5e9; font-family: monospace; padding: 10px; border: 1px solid #555; border-radius: 4px; }
table { width: 100%; border-collapse: collapse; }
th, td { padding: 10px; text-align: left; border-bottom: 1px solid #555; }
th { background: #333; color: #0ea5e9; }
.btn-sm { padding: 5px 10px; font-size: 12px; }
@media (max-width: 768px) {
    .container { padding: 10px; }
    .card { padding: 15px; }
}
</style>
</head><body>
<div class="container">
    <div class="header">
        <h1>CF Tunnel Manager</h1>
        <p>Simple Cloudflare Tunnel Management - Server: {{ server_ip }}:5000</p>
    </div>
    
    {% if not is_authed %}
    <div class="card">
        <h3>Authentication Required</h3>
        <p>You need to authenticate with Cloudflare first.</p>
        <button class="btn btn-primary" onclick="authenticate()">Authenticate with Cloudflare</button>
        <div id="authStatus"></div>
    </div>
    {% endif %}
    
    <div class="card">
        <h3>System Status</h3>
        <div style="display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 15px;">
            <div>CPU: {{ cpu }}%</div>
            <div>Memory: {{ mem_used }}GB / {{ mem_total }}GB</div>
            <div>Disk: {{ disk_used }}GB / {{ disk_total }}GB</div>
            <div>Auth: {{ "Yes" if is_authed else "No" }}</div>
        </div>
    </div>
    
    {% if is_authed %}
    <div class="card">
        <h3>Tunnel Operations</h3>
        <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 15px;">
            <div class="form-group">
                <label>Tunnel Name:</label>
                <input type="text" id="tunnelName" class="form-control" placeholder="my-tunnel">
            </div>
            <div class="form-group">
                <label>Domain:</label>
                <input type="text" id="hostname" class="form-control" placeholder="sub.domain.com">
            </div>
        </div>
        <div>
            <button class="btn btn-success" onclick="createTunnel()">Create Tunnel</button>
            <button class="btn btn-primary" onclick="routeDns()">Route DNS</button>
            <button class="btn btn-danger" onclick="deleteTunnel()">Delete Tunnel</button>
            <button class="btn btn-warning" onclick="refreshTunnels()">Refresh</button>
        </div>
    </div>
    
    <div class="card">
        <h3>Active Tunnels</h3>
        <div id="tunnelsList">Loading...</div>
    </div>
    {% endif %}
    
    <div class="card">
        <h3>Output</h3>
        <textarea id="output" class="output" readonly></textarea>
        <button class="btn btn-warning" onclick="clearOutput()">Clear</button>
    </div>
</div>

<script>
function log(msg) {
    const out = document.getElementById('output');
    out.value += new Date().toLocaleTimeString() + ': ' + msg + '\\n';
    out.scrollTop = out.scrollHeight;
}

function showStatus(msg, type = 'info') {
    const statusDiv = document.getElementById('authStatus') || document.createElement('div');
    statusDiv.className = 'status status-' + type;
    statusDiv.textContent = msg;
    if (!document.getElementById('authStatus')) {
        statusDiv.id = 'authStatus';
        document.querySelector('.card').appendChild(statusDiv);
    }
}

async function authenticate() {
    try {
        const resp = await fetch('/api/auth', { method: 'POST' });
        const data = await resp.json();
        if (data.ok) {
            showStatus('Authentication started! Complete in your browser.', 'success');
            log('Authentication process started');
            // Check auth status periodically
            setTimeout(checkAuthStatus, 10000);
        } else {
            showStatus('Auth failed: ' + data.msg, 'error');
        }
    } catch (e) {
        showStatus('Network error', 'error');
    }
}

async function checkAuthStatus() {
    try {
        const resp = await fetch('/api/auth-status');
        const data = await resp.json();
        if (data.authed) {
            showStatus('Authentication successful!', 'success');
            setTimeout(() => location.reload(), 2000);
        } else {
            setTimeout(checkAuthStatus, 10000);
        }
    } catch (e) {
        setTimeout(checkAuthStatus, 10000);
    }
}

async function createTunnel() {
    const name = document.getElementById('tunnelName').value.trim();
    if (!name) { alert('Enter tunnel name'); return; }
    
    try {
        const resp = await fetch('/api/create', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ name })
        });
        const data = await resp.json();
        log(data.msg);
        if (data.ok) {
            document.getElementById('tunnelName').value = '';
            refreshTunnels();
        }
    } catch (e) {
        log('Network error');
    }
}

async function deleteTunnel() {
    const name = document.getElementById('tunnelName').value.trim();
    if (!name || !confirm('Delete tunnel: ' + name + '?')) return;
    
    try {
        const resp = await fetch('/api/delete', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ name })
        });
        const data = await resp.json();
        log(data.msg);
        if (data.ok) refreshTunnels();
    } catch (e) {
        log('Network error');
    }
}

async function routeDns() {
    const name = document.getElementById('tunnelName').value.trim();
    const hostname = document.getElementById('hostname').value.trim();
    if (!name || !hostname) { alert('Enter both tunnel name and hostname'); return; }
    
    try {
        const resp = await fetch('/api/route', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ tunnel: name, hostname })
        });
        const data = await resp.json();
        log(data.msg);
    } catch (e) {
        log('Network error');
    }
}

async function refreshTunnels() {
    document.getElementById('tunnelsList').innerHTML = 'Loading...';
    try {
        const resp = await fetch('/api/tunnels');
        const tunnels = await resp.json();
        
        if (tunnels.length === 0) {
            document.getElementById('tunnelsList').innerHTML = '<p>No tunnels found</p>';
            return;
        }
        
        let html = '<table><tr><th>Name</th><th>ID</th><th>Created</th><th>Actions</th></tr>';
        tunnels.forEach(t => {
            const created = t.created_at ? new Date(t.created_at).toLocaleDateString() : 'Unknown';
            html += '<tr><td>' + t.name + '</td><td>' + t.id.substring(0,8) + '...</td><td>' + created + '</td><td><button class="btn btn-danger btn-sm" onclick="deleteTunnelById(\\''+t.name+'\\')">Delete</button></td></tr>';
        });
        html += '</table>';
        document.getElementById('tunnelsList').innerHTML = html;
        log('Found ' + tunnels.length + ' tunnels');
    } catch (e) {
        document.getElementById('tunnelsList').innerHTML = '<p>Error loading tunnels</p>';
        log('Failed to load tunnels');
    }
}

async function deleteTunnelById(name) {
    if (!confirm('Delete tunnel: ' + name + '?')) return;
    document.getElementById('tunnelName').value = name;
    deleteTunnel();
}

function clearOutput() {
    document.getElementById('output').value = '';
}

// Auto-refresh tunnels
if ({{ 'true' if is_authed else 'false' }}) {
    refreshTunnels();
    setInterval(refreshTunnels, 30000);
}

log('CF Tunnel Manager loaded');
</script>
</body></html>'''

@app.route('/')
def index():
    try:
        server_ip = socket.gethostbyname(socket.gethostname())
    except:
        server_ip = 'localhost'
    
    # Get system info
    try:
        cpu = int(psutil.cpu_percent(interval=0.1))
        mem = psutil.virtual_memory()
        disk = psutil.disk_usage('/')
        
        return render_template_string(HTML,
            server_ip=server_ip,
            is_authed=manager.is_authed(),
            cpu=cpu,
            mem_used=round(mem.used/1024**3, 1),
            mem_total=round(mem.total/1024**3, 1),
            disk_used=round(disk.used/1024**3, 1),
            disk_total=round(disk.total/1024**3, 1)
        )
    except Exception as e:
        return f"Error: {str(e)}"

@app.route('/api/auth', methods=['POST'])
def api_auth():
    return jsonify(manager.auth_start())

@app.route('/api/auth-status')
def api_auth_status():
    return jsonify({'authed': manager.is_authed()})

@app.route('/api/tunnels')
def api_tunnels():
    return jsonify(manager.list_tunnels())

@app.route('/api/create', methods=['POST'])
def api_create():
    data = request.get_json()
    return jsonify(manager.create_tunnel(data.get('name', '')))

@app.route('/api/delete', methods=['POST'])
def api_delete():
    data = request.get_json()
    return jsonify(manager.delete_tunnel(data.get('name', '')))

@app.route('/api/route', methods=['POST'])
def api_route():
    data = request.get_json()
    return jsonify(manager.route_dns(data.get('tunnel', ''), data.get('hostname', '')))

if __name__ == '__main__':
    print(f"Starting CF Tunnel Manager on port 5000...")
    # Find available port
    for port in range(5000, 5010):
        try:
            app.run(host='0.0.0.0', port=port, debug=False)
            break
        except:
            continue
EOF

# Create service
cat > "/etc/systemd/system/$APP_NAME.service" << EOF
[Unit]
Description=CF Tunnel Manager
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$INSTALL_DIR
ExecStart=/usr/bin/python3 app.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# Create launcher
cat > "/usr/local/bin/$APP_NAME" << 'EOF'
#!/bin/bash
case "${1:-start}" in
    start)
        echo "Starting CF Tunnel Manager..."
        systemctl start cftunnel
        sleep 2
        ip=$(hostname -I | awk '{print $1}')
        echo "Web interface: http://$ip:5000"
        ;;
    stop)
        systemctl stop cftunnel
        echo "Stopped"
        ;;
    restart)
        systemctl restart cftunnel
        echo "Restarted"
        ;;
    status)
        systemctl status cftunnel --no-pager
        ;;
    logs)
        journalctl -u cftunnel -f
        ;;
    web)
        ip=$(hostname -I | awk '{print $1}')
        echo "Open: http://$ip:5000"
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|status|logs|web}"
        echo ""
        echo "Quick start:"
        echo "1. $0 start"
        echo "2. Open http://$(hostname -I | awk '{print $1}'):5000"
        echo "3. Click 'Authenticate'"
        ;;
esac
EOF

chmod +x "/usr/local/bin/$APP_NAME"

# Enable and start
systemctl daemon-reload
systemctl enable "$APP_NAME"

# Auto-fix common issues
pkill -f "python3.*app.py" 2>/dev/null || true
sleep 2

# Start service
systemctl start "$APP_NAME"
sleep 3

# Show result
server_ip=$(hostname -I | awk '{print $1}' || echo "localhost")
echo ""
echo "======================================"
echo "CF Tunnel Manager - Ready!"
echo "======================================"
echo "Web Interface: http://$server_ip:5000"
echo ""
echo "Commands:"
echo "  $APP_NAME start   - Start service"
echo "  $APP_NAME stop    - Stop service"  
echo "  $APP_NAME status  - Show status"
echo "  $APP_NAME logs    - View logs"
echo "  $APP_NAME web     - Show web URL"
echo ""
echo "Setup:"
echo "1. Open http://$server_ip:5000"
echo "2. Click 'Authenticate with Cloudflare'"
echo "3. Complete auth in browser"
echo "4. Create tunnels"
echo "======================================"

# Auto-open web interface if possible
if command -v xdg-open &>/dev/null; then
    xdg-open "http://$server_ip:5000" 2>/dev/null || true
fi
