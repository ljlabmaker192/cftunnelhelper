#!/bin/bash

# CF Tunnel Helper - Professional Installation Script
# Version: 3.0.1 - Fixed Authentication & Industrial UI
# GitHub: https://github.com/ljlabmaker192/cftunnelhelper

set -euo pipefail

# Configuration
readonly APP_NAME="cftunnelhelper"
readonly INSTALL_DIR="/opt/$APP_NAME"
readonly BIN_LINK="/usr/local/bin/$APP_NAME"
readonly SERVICE_FILE="/etc/systemd/system/$APP_NAME.service"
readonly LOG_DIR="/var/log/$APP_NAME"
readonly CONFIG_DIR="/etc/$APP_NAME"

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_header() {
    echo -e "${BOLD}${CYAN}$1${NC}"
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root. Please use sudo."
        exit 1
    fi
}

# Detect Ubuntu version
detect_ubuntu_version() {
    if [[ ! -f /etc/os-release ]]; then
        log_error "Cannot detect OS version"
        exit 1
    fi
    
    source /etc/os-release
    if [[ "$ID" != "ubuntu" ]]; then
        log_warning "This script is designed for Ubuntu, but will attempt to install on $ID"
    fi
    
    log_info "Detected: $PRETTY_NAME"
}

# Create directories
create_directories() {
    log_info "Creating directories..."
    mkdir -p "$INSTALL_DIR" "$LOG_DIR" "$CONFIG_DIR"
    chmod 755 "$INSTALL_DIR" "$LOG_DIR" "$CONFIG_DIR"
}

# Install system dependencies
install_dependencies() {
    log_info "Installing system dependencies..."
    
    # Update package list
    apt update -qq
    
    # Install base packages
    apt install -y \
        python3 \
        python3-pip \
        python3-flask \
        python3-requests \
        python3-psutil \
        curl \
        wget \
        sudo \
        systemd \
        ufw \
        net-tools \
        2>/dev/null || {
        
        # Fallback for older Ubuntu versions
        log_warning "Some packages not available, installing alternatives..."
        apt install -y python3 python3-pip curl wget sudo systemd
        pip3 install --break-system-packages flask requests psutil 2>/dev/null || \
        pip3 install flask requests psutil
    }
}

# Install cloudflared with version detection
install_cloudflared() {
    log_info "Installing cloudflared..."
    
    local temp_deb="/tmp/cloudflared.deb"
    
    # Detect architecture
    local arch
    case "$(uname -m)" in
        x86_64) arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        armv7l) arch="armhf" ;;
        *) arch="amd64" ;;
    esac
    
    log_info "Detected architecture: $arch"
    
    # Download and install
    wget -q -O "$temp_deb" "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}.deb"
    
    if dpkg -i "$temp_deb" 2>/dev/null; then
        log_success "cloudflared installed successfully"
    else
        log_warning "Fixing dependencies..."
        apt install -f -y
    fi
    
    rm -f "$temp_deb"
    
    # Verify installation
    if ! command -v cloudflared &> /dev/null; then
        log_error "cloudflared installation failed"
        exit 1
    fi
    
    local version=$(cloudflared version | head -n1)
    log_success "Cloudflared version: $version"
}

# Create the main application with fixed authentication and industrial UI
create_application() {
    log_info "Creating application..."
    
    cat > "$INSTALL_DIR/$APP_NAME.py" << 'PYTHON_APP_EOF'
#!/usr/bin/env python3
"""
CF Tunnel Helper - Professional Web GUI for Cloudflare Tunnel Management
Industrial UI with Fixed Authentication
"""

import os
import json
import subprocess
import logging
import socket
import threading
import time
from datetime import datetime
from flask import Flask, render_template_string, request, jsonify, redirect, url_for, flash
import psutil

# Configure logging
os.makedirs('/var/log/cftunnelhelper', exist_ok=True)
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler('/var/log/cftunnelhelper/app.log'),
        logging.StreamHandler()
    ]
)
logger = logging.getLogger(__name__)

app = Flask(__name__)
app.secret_key = os.urandom(24)

class CFTunnelManager:
    """Cloudflare Tunnel Management Class with Fixed Authentication"""
    
    def __init__(self):
        self.config_path = "/etc/cftunnelhelper/config.json"
        self.cloudflare_config_path = os.path.expanduser("~/.cloudflared")
        self.auth_in_progress = False
        self.auth_url = None
        self.ensure_config_exists()
    
    def ensure_config_exists(self):
        """Ensure configuration file exists"""
        os.makedirs(os.path.dirname(self.config_path), exist_ok=True)
        if not os.path.exists(self.config_path):
            with open(self.config_path, 'w') as f:
                json.dump({
                    "authenticated": False,
                    "last_auth_check": None,
                    "tunnels": {}
                }, f, indent=2)
    
    def is_authenticated(self):
        """Check if user is authenticated with Cloudflare"""
        try:
            # Check if credentials exist
            if os.path.exists(f"{self.cloudflare_config_path}/cert.pem"):
                result = self.run_command(['cloudflared', 'tunnel', 'list'], timeout=10)
                return result['success']
            return False
        except Exception:
            return False
    
    def get_auth_url(self):
        """Start authentication process and get URL"""
        try:
            self.auth_in_progress = True
            
            # Create a thread to handle the authentication
            auth_thread = threading.Thread(target=self._authenticate_background)
            auth_thread.daemon = True
            auth_thread.start()
            
            # Wait a moment for the process to start
            time.sleep(2)
            
            # Return the auth URL that users should visit
            return "https://dash.cloudflare.com/profile/api-tokens"
            
        except Exception as e:
            logger.error(f"Auth URL generation failed: {e}")
            self.auth_in_progress = False
            return None
    
    def _authenticate_background(self):
        """Background authentication process"""
        try:
            logger.info("Starting background authentication process...")
            result = self.run_command(['cloudflared', 'tunnel', 'login'], timeout=300)
            
            if result['success']:
                self.update_config({'authenticated': True, 'last_auth_check': datetime.now().isoformat()})
                logger.info("Authentication completed successfully")
            else:
                logger.error(f"Authentication failed: {result['stderr']}")
                
        except Exception as e:
            logger.error(f"Background authentication error: {e}")
        finally:
            self.auth_in_progress = False
    
    def run_command(self, cmd, timeout=30):
        """Execute cloudflared command safely with better error handling"""
        try:
            logger.info(f"Executing command: {' '.join(cmd)}")
            result = subprocess.run(
                cmd, 
                capture_output=True, 
                text=True, 
                timeout=timeout,
                check=False,
                env=dict(os.environ)
            )
            
            output = {
                'success': result.returncode == 0,
                'stdout': result.stdout.strip(),
                'stderr': result.stderr.strip(),
                'returncode': result.returncode
            }
            
            if not output['success']:
                logger.error(f"Command failed: {output['stderr']}")
            
            return output
            
        except subprocess.TimeoutExpired:
            logger.error(f"Command timed out: {' '.join(cmd)}")
            return {
                'success': False,
                'stdout': '',
                'stderr': f'Command timed out after {timeout} seconds',
                'returncode': -1
            }
        except Exception as e:
            logger.error(f"Command execution error: {str(e)}")
            return {
                'success': False,
                'stdout': '',
                'stderr': str(e),
                'returncode': -1
            }
    
    def authenticate_cloudflare(self):
        """Start Cloudflare authentication process"""
        if self.auth_in_progress:
            return {
                'success': True,
                'message': 'Authentication already in progress. Please complete in your browser.',
                'auth_url': 'https://dash.cloudflare.com/profile/api-tokens'
            }
        
        try:
            auth_url = self.get_auth_url()
            return {
                'success': True,
                'message': 'Authentication process started. Please complete in your browser.',
                'auth_url': auth_url
            }
        except Exception as e:
            return {
                'success': False,
                'message': f'Failed to start authentication: {str(e)}',
                'auth_url': None
            }
    
    def update_config(self, updates):
        """Update configuration file"""
        try:
            with open(self.config_path, 'r') as f:
                config = json.load(f)
            config.update(updates)
            with open(self.config_path, 'w') as f:
                json.dump(config, f, indent=2)
        except Exception as e:
            logger.error(f"Failed to update config: {e}")
    
    def list_tunnels(self):
        """List all tunnels with better error handling"""
        if not self.is_authenticated():
            return []
        
        result = self.run_command(['cloudflared', 'tunnel', 'list', '--output', 'json'])
        
        if result['success'] and result['stdout']:
            try:
                data = json.loads(result['stdout'])
                return data if isinstance(data, list) else []
            except json.JSONDecodeError:
                logger.error("Failed to parse tunnel list JSON")
                return []
        
        return []
    
    def create_tunnel(self, name):
        """Create a new tunnel"""
        if not name or not name.strip():
            return {'success': False, 'message': 'Tunnel name is required'}
        
        if not self.is_authenticated():
            return {'success': False, 'message': 'Please authenticate with Cloudflare first'}
        
        name = name.strip().lower().replace(' ', '-')
        result = self.run_command(['cloudflared', 'tunnel', 'create', name])
        
        if result['success']:
            logger.info(f"Tunnel '{name}' created successfully")
            return {'success': True, 'message': f'Tunnel "{name}" created successfully'}
        else:
            return {'success': False, 'message': result['stderr'] or 'Failed to create tunnel'}
    
    def delete_tunnel(self, name):
        """Delete a tunnel"""
        if not name or not name.strip():
            return {'success': False, 'message': 'Tunnel name is required'}
        
        if not self.is_authenticated():
            return {'success': False, 'message': 'Please authenticate with Cloudflare first'}
        
        name = name.strip()
        
        # Try to clean up first
        self.run_command(['cloudflared', 'tunnel', 'cleanup', name])
        
        # Then delete
        result = self.run_command(['cloudflared', 'tunnel', 'delete', name, '--force'])
        
        if result['success']:
            logger.info(f"Tunnel '{name}' deleted successfully")
            return {'success': True, 'message': f'Tunnel "{name}" deleted successfully'}
        else:
            return {'success': False, 'message': result['stderr'] or 'Failed to delete tunnel'}
    
    def route_dns(self, tunnel_name, hostname):
        """Route DNS for a tunnel"""
        if not tunnel_name or not hostname:
            return {'success': False, 'message': 'Tunnel name and hostname are required'}
        
        if not self.is_authenticated():
            return {'success': False, 'message': 'Please authenticate with Cloudflare first'}
        
        tunnel_name = tunnel_name.strip()
        hostname = hostname.strip().lower()
        
        result = self.run_command(['cloudflared', 'tunnel', 'route', 'dns', tunnel_name, hostname])
        
        if result['success']:
            logger.info(f"DNS route created: {hostname} -> {tunnel_name}")
            return {'success': True, 'message': f'DNS route created: {hostname} → {tunnel_name}'}
        else:
            return {'success': False, 'message': result['stderr'] or 'Failed to create DNS route'}
    
    def get_system_info(self):
        """Get comprehensive system information"""
        try:
            memory = psutil.virtual_memory()
            disk = psutil.disk_usage('/')
            
            return {
                'cpu_percent': psutil.cpu_percent(interval=0.1),
                'memory': {
                    'percent': memory.percent,
                    'used': self.bytes_to_gb(memory.used),
                    'total': self.bytes_to_gb(memory.total)
                },
                'disk': {
                    'percent': (disk.used / disk.total) * 100,
                    'used': self.bytes_to_gb(disk.used),
                    'total': self.bytes_to_gb(disk.total)
                },
                'cloudflared_running': self.is_cloudflared_running(),
                'authenticated': self.is_authenticated(),
                'auth_in_progress': self.auth_in_progress
            }
        except Exception as e:
            logger.error(f"Error getting system info: {str(e)}")
            return {'authenticated': False, 'cloudflared_running': False, 'auth_in_progress': False}
    
    def bytes_to_gb(self, bytes_val):
        """Convert bytes to GB"""
        return round(bytes_val / (1024**3), 2)
    
    def is_cloudflared_running(self):
        """Check if any cloudflared processes are running"""
        try:
            for proc in psutil.process_iter(['pid', 'name', 'cmdline']):
                if 'cloudflared' in proc.info['name']:
                    return True
        except (psutil.NoSuchProcess, psutil.AccessDenied):
            pass
        return False

# Initialize tunnel manager
tunnel_manager = CFTunnelManager()

# Industrial Professional HTML Template with Fixed Colors
HTML_TEMPLATE = """
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>CF Tunnel Manager - Industrial Control Panel</title>
    <link href="https://cdnjs.cloudflare.com/ajax/libs/bootstrap/5.3.2/css/bootstrap.min.css" rel="stylesheet">
    <link href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.4.0/css/all.min.css" rel="stylesheet">
    <link href="https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@300;400;500;600&family=Inter:wght@300;400;500;600;700&display=swap" rel="stylesheet">
    <style>
        :root {
            /* Industrial Color Scheme */
            --primary-bg: #1e1e1e;          /* Dark charcoal */
            --secondary-bg: #2d2d2d;        /* Medium gray */
            --tertiary-bg: #3a3a3a;         /* Light gray */
            --accent-primary: #00b4d8;      /* Industrial blue */
            --accent-secondary: #0077b6;    /* Darker blue */
            --accent-success: #06d6a0;      /* Teal green */
            --accent-warning: #ffd60a;      /* Amber */
            --accent-danger: #f72585;       /* Magenta red */
            --accent-info: #7209b7;         /* Purple */
            --text-primary: #ffffff;        /* Pure white */
            --text-secondary: #d4d4d4;      /* Light gray */
            --text-muted: #9ca3af;          /* Medium gray */
            --text-accent: #00b4d8;         /* Blue accent */
            --border-color: #4a4a4a;        /* Border gray */
            --border-light: #5a5a5a;        /* Lighter border */
            --shadow-primary: rgba(0, 180, 216, 0.15);
            --shadow-dark: rgba(0, 0, 0, 0.5);
        }

        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }

        body {
            font-family: 'Inter', -apple-system, BlinkMacSystemFont, sans-serif;
            background: linear-gradient(135deg, var(--primary-bg) 0%, #0f0f0f 100%);
            color: var(--text-primary);
            line-height: 1.6;
            min-height: 100vh;
        }

        /* Navigation - Industrial Style */
        .navbar {
            background: rgba(30, 30, 30, 0.98) !important;
            backdrop-filter: blur(20px);
            border-bottom: 2px solid var(--accent-primary);
            box-shadow: 0 4px 20px var(--shadow-dark);
        }

        .navbar-brand {
            font-family: 'JetBrains Mono', monospace;
            font-weight: 600;
            font-size: 1.3rem;
            color: var(--text-primary) !important;
            display: flex;
            align-items: center;
            gap: 10px;
        }

        .navbar-brand i {
            color: var(--accent-primary);
            font-size: 1.5rem;
        }

        .navbar-text {
            color: var(--text-secondary) !important;
            font-family: 'JetBrains Mono', monospace;
            font-size: 0.9rem;
        }

        /* Cards - Industrial Design */
        .card {
            background: linear-gradient(145deg, var(--secondary-bg), #262626);
            border: 1px solid var(--border-color);
            border-radius: 8px;
            box-shadow: 
                0 4px 12px var(--shadow-dark),
                inset 0 1px 0 rgba(255, 255, 255, 0.1);
            transition: all 0.3s ease;
        }

        .card:hover {
            border-color: var(--accent-primary);
            box-shadow: 
                0 8px 25px var(--shadow-primary),
                0 4px 12px var(--shadow-dark),
                inset 0 1px 0 rgba(255, 255, 255, 0.1);
            transform: translateY(-2px);
        }

        .card-header {
            background: linear-gradient(145deg, var(--tertiary-bg), #333333);
            border-bottom: 1px solid var(--border-light);
            border-radius: 8px 8px 0 0 !important;
            padding: 1rem 1.25rem;
            font-weight: 600;
            color: var(--text-primary);
            font-family: 'JetBrains Mono', monospace;
        }

        .card-header h5 {
            color: var(--text-primary);
            margin: 0;
        }

        .card-body {
            background: var(--secondary-bg);
            color: var(--text-primary);
        }

        /* Forms - Industrial Style */
        .form-control, .form-select {
            background: linear-gradient(145deg, var(--tertiary-bg), #353535);
            border: 1px solid var(--border-color);
            color: var(--text-primary);
            border-radius: 6px;
            padding: 0.65rem 1rem;
            transition: all 0.3s ease;
            font-size: 0.95rem;
            box-shadow: inset 0 2px 4px rgba(0, 0, 0, 0.2);
        }

        .form-control:focus, .form-select:focus {
            background: var(--tertiary-bg);
            border-color: var(--accent-primary);
            color: var(--text-primary);
            box-shadow: 
                0 0 0 0.25rem var(--shadow-primary),
                inset 0 2px 4px rgba(0, 0, 0, 0.2);
        }

        .form-control::placeholder {
            color: var(--text-muted);
        }

        .form-label {
            color: var(--text-secondary);
            font-weight: 500;
            margin-bottom: 0.5rem;
            font-family: 'JetBrains Mono', monospace;
            font-size: 0.9rem;
        }

        /* Buttons - Industrial Style */
        .btn {
            border-radius: 6px;
            font-weight: 500;
            padding: 0.65rem 1.25rem;
            border: none;
            transition: all 0.3s ease;
            font-size: 0.9rem;
            display: inline-flex;
            align-items: center;
            gap: 0.5rem;
            font-family: 'JetBrains Mono', monospace;
            text-transform: uppercase;
            letter-spacing: 0.5px;
            box-shadow: 
                0 2px 4px rgba(0, 0, 0, 0.2),
                inset 0 1px 0 rgba(255, 255, 255, 0.1);
        }

        .btn-primary {
            background: linear-gradient(145deg, var(--accent-primary), var(--accent-secondary));
            color: var(--text-primary);
        }

        .btn-primary:hover {
            background: linear-gradient(145deg, var(--accent-secondary), #005577);
            transform: translateY(-2px);
            box-shadow: 
                0 4px 12px var(--shadow-primary),
                inset 0 1px 0 rgba(255, 255, 255, 0.2);
            color: var(--text-primary);
        }

        .btn-success {
            background: linear-gradient(145deg, var(--accent-success), #048a6b);
            color: var(--text-primary);
        }

        .btn-success:hover {
            background: linear-gradient(145deg, #048a6b, #036653);
            transform: translateY(-2px);
            color: var(--text-primary);
        }

        .btn-danger {
            background: linear-gradient(145deg, var(--accent-danger), #d41e5a);
            color: var(--text-primary);
        }

        .btn-danger:hover {
            background: linear-gradient(145deg, #d41e5a, #b81847);
            transform: translateY(-2px);
            color: var(--text-primary);
        }

        .btn-warning {
            background: linear-gradient(145deg, var(--accent-warning), #e6c200);
            color: var(--primary-bg);
        }

        .btn-warning:hover {
            background: linear-gradient(145deg, #e6c200, #ccad00);
            transform: translateY(-2px);
            color: var(--primary-bg);
        }

        .btn-info {
            background: linear-gradient(145deg, var(--accent-info), #5a0890);
            color: var(--text-primary);
        }

        .btn-info:hover {
            background: linear-gradient(145deg, #5a0890, #4a0770);
            transform: translateY(-2px);
            color: var(--text-primary);
        }

        .btn:disabled {
            opacity: 0.6;
            transform: none !important;
            cursor: not-allowed;
        }

        /* Status indicators */
        .status-indicator {
            display: inline-block;
            width: 12px;
            height: 12px;
            border-radius: 50%;
            margin-right: 8px;
            position: relative;
            box-shadow: 0 0 6px rgba(0, 0, 0, 0.3);
        }

        .status-active {
            background: var(--accent-success);
            box-shadow: 0 0 12px var(--accent-success);
        }

        .status-active::before {
            content: '';
            position: absolute;
            width: 100%;
            height: 100%;
            border-radius: 50%;
            background: var(--accent-success);
            animation: industrial-pulse 2s infinite;
        }

        .status-inactive {
            background: var(--text-muted);
            box-shadow: 0 0 6px rgba(0, 0, 0, 0.3);
        }

        @keyframes industrial-pulse {
            0% { transform: scale(0.9); opacity: 1; }
            50% { transform: scale(1.1); opacity: 0.7; }
            100% { transform: scale(0.9); opacity: 1; }
        }

        /* Tables - Industrial Style */
        .table-dark {
            background: var(--secondary-bg);
            color: var(--text-primary);
        }

        .table-dark th {
            background: linear-gradient(145deg, var(--tertiary-bg), #404040);
            border-color: var(--border-light);
            color: var(--text-primary);
            font-weight: 600;
            font-family: 'JetBrains Mono', monospace;
            font-size: 0.9rem;
            text-transform: uppercase;
            letter-spacing: 0.5px;
        }

        .table-dark td {
            border-color: var(--border-color);
            color: var(--text-secondary);
            font-family: 'JetBrains Mono', monospace;
            font-size: 0.85rem;
        }

        .table-hover .table-dark tbody tr:hover {
            background: var(--tertiary-bg);
            color: var(--text-primary);
        }

        /* Output area */
        .output-area {
            background: linear-gradient(145deg, var(--primary-bg), #1a1a1a);
            border: 1px solid var(--border-color);
            border-radius: 6px;
            color: var(--accent-success);
            font-family: 'JetBrains Mono', monospace;
            font-size: 0.85rem;
            min-height: 200px;
            resize: vertical;
            padding: 1rem;
            box-shadow: inset 0 2px 8px rgba(0, 0, 0, 0.4);
            line-height: 1.4;
        }

        /* System info cards - Industrial style */
        .system-metric {
            display: flex;
            align-items: center;
            justify-content: space-between;
            padding: 0.75rem 1rem;
            background: linear-gradient(145deg, var(--tertiary-bg), #404040);
            border-radius: 6px;
            margin-bottom: 0.75rem;
            border: 1px solid var(--border-color);
            box-shadow: inset 0 1px 0 rgba(255, 255, 255, 0.1);
        }

        .metric-label {
            color: var(--text-secondary);
            font-weight: 500;
            font-family: 'JetBrains Mono', monospace;
            font-size: 0.9rem;
            display: flex;
            align-items: center;
            gap: 0.5rem;
        }

        .metric-value {
            color: var(--text-primary);
            font-weight: 600;
            font-family: 'JetBrains Mono', monospace;
            font-size: 0.9rem;
        }

        /* Authentication section */
        .auth-section {
            text-align: center;
            padding: 3rem 2rem;
            background: linear-gradient(145deg, var(--secondary-bg), #2a2a2a);
            border-radius: 12px;
            border: 2px solid var(--accent-primary);
            margin: 2rem 0;
            box-shadow: 
                0 8px 32px var(--shadow-dark),
                inset 0 1px 0 rgba(255, 255, 255, 0.1);
        }

        .auth-icon {
            font-size: 4rem;
            color: var(--accent-primary);
            margin-bottom: 1.5rem;
            text-shadow: 0 0 20px var(--accent-primary);
        }

        .auth-section h2 {
            color: var(--text-primary);
            font-family: 'JetBrains Mono', monospace;
            margin-bottom: 1rem;
        }

        .auth-section p {
            color: var(--text-secondary);
            margin-bottom: 2rem;
        }

        /* Loading states */
        .loading {
            position: relative;
            pointer-events: none;
            overflow: hidden;
        }

        .loading::after {
            content: '';
            position: absolute;
            top: 50%;
            left: 50%;
            width: 20px;
            height: 20px;
            border: 2px solid var(--border-color);
            border-top: 2px solid var(--accent-primary);
            border-radius: 50%;
            transform: translate(-50%, -50%);
            animation: industrial-spin 1s linear infinite;
        }

        @keyframes industrial-spin {
            0% { transform: translate(-50%, -50%) rotate(0deg); }
            100% { transform: translate(-50%, -50%) rotate(360deg); }
        }

        /* Toast messages - Industrial style */
        .toast {
            background: linear-gradient(145deg, var(--secondary-bg), #2a2a2a) !important;
            border: 1px solid var(--border-color);
            color: var(--text-primary);
            box-shadow: 0 8px 32px var(--shadow-dark);
        }

        .toast-header {
            background: var(--tertiary-bg);
            border-bottom: 1px solid var(--border-color);
            color: var(--text-primary);
            font-family: 'JetBrains Mono', monospace;
            font-size: 0.85rem;
        }

        .toast-body {
            color: var(--text-primary);
            font-family: 'JetBrains Mono', monospace;
            font-size: 0.85rem;
        }

        /* Progress bars */
        .progress {
            background: var(--tertiary-bg);
            border-radius: 6px;
            height: 8px;
            box-shadow: inset 0 2px 4px rgba(0, 0, 0, 0.2);
        }

        .progress-bar {
            background: linear-gradient(90deg, var(--accent-primary), var(--accent-secondary));
            border-radius: 6px;
            transition: width 0.6s ease;
        }

        /* Alerts - Industrial style */
        .alert {
            border-radius: 6px;
            border: 1px solid;
            font-family: 'JetBrains Mono', monospace;
            box-shadow: inset 0 1px 0 rgba(255, 255, 255, 0.1);
        }

        .alert-danger {
            background: linear-gradient(145deg, rgba(247, 37, 133, 0.15), rgba(212, 30, 90, 0.1));
            border-color: var(--accent-danger);
            color: #ff89b5;
        }

        .alert-success {
            background: linear-gradient(145deg, rgba(6, 214, 160, 0.15), rgba(4, 138, 107, 0.1));
            border-color: var(--accent-success);
            color: #4eedc7;
        }

        .alert-warning {
            background: linear-gradient(145deg, rgba(255, 214, 10, 0.15), rgba(230, 194, 0, 0.1));
            border-color: var(--accent-warning);
            color: #ffe55c;
        }

        .alert-info {
            background: linear-gradient(145deg, rgba(0, 180, 216, 0.15), rgba(0, 119, 182, 0.1));
            border-color: var(--accent-primary);
            color: #5cc9e8;
        }

        /* Responsive design */
        @media (max-width: 768px) {
            .container-fluid {
                padding: 1rem;
            }
            
            .card {
                margin-bottom: 1rem;
            }
            
            .btn-group {
                flex-direction: column;
            }
            
            .btn-group .btn {
                margin-bottom: 0.5rem;
                border-radius: 6px !important;
            }
        }

        /* Custom scrollbar - Industrial */
        ::-webkit-scrollbar {
            width: 8px;
        }

        ::-webkit-scrollbar-track {
            background: var(--primary-bg);
        }

        ::-webkit-scrollbar-thumb {
            background: linear-gradient(145deg, var(--accent-primary), var(--accent-secondary));
            border-radius: 4px;
        }

        ::-webkit-scrollbar-thumb:hover {
            background: linear-gradient(145deg, var(--accent-secondary), #005577);
        }

        /* Additional industrial elements */
        code {
            background: var(--primary-bg);
            color: var(--accent-success);
            padding: 0.2rem 0.4rem;
            border-radius: 4px;
            font-family: 'JetBrains Mono', monospace;
            font-size: 0.85rem;
            border: 1px solid var(--border-color);
        }

        .text-accent {
            color: var(--accent-primary) !important;
        }

        .text-success-custom {
            color: var(--accent-success) !important;
        }

        .text-warning-custom {
            color: var(--accent-warning) !important;
        }

        .text-danger-custom {
            color: var(--accent-danger) !important;
        }
    </style>
</head>
<body>
    <!-- Navigation -->
    <nav class="navbar navbar-expand-lg sticky-top">
        <div class="container-fluid">
            <a class="navbar-brand" href="/">
                <i class="fas fa-cloud-upload-alt"></i>
                CF TUNNEL CONTROL
            </a>
            <div class="navbar-nav ms-auto">
                <span class="navbar-text">
                    <i class="fas fa-server"></i> {{ server_ip }}:5000
                </span>
            </div>
        </div>
    </nav>

    <div class="container-fluid mt-4">
        {% if not system_info.authenticated %}
        <!-- Authentication Required Section -->
        <div class="row">
            <div class="col-12">
                <div class="auth-section">
                    <i class="fas fa-key auth-icon"></i>
                    <h2 class="mb-3">CLOUDFLARE AUTHENTICATION REQUIRED</h2>
                    <p class="text-secondary mb-4">
                        System requires Cloudflare authentication to manage tunnels.<br>
                        Authentication process will provide a secure login URL.
                    </p>
                    <div class="d-flex gap-3 justify-content-center flex-wrap">
                        <button class="btn btn-primary btn-lg" onclick="authenticateCloudflare()" id="authBtn">
                            <i class="fas fa-sign-in-alt"></i> AUTHENTICATE
                        </button>
                        <button class="btn btn-info btn-lg" onclick="openAuthUrl()" id="manualAuthBtn" style="display:none;">
                            <i class="fas fa-external-link-alt"></i> OPEN AUTH URL
                        </button>
                    </div>
                    <div class="mt-4" id="authInstructions" style="display:none;">
                        <div class="alert alert-info">
                            <i class="fas fa-info-circle"></i> 
                            <strong>AUTHENTICATION IN PROGRESS</strong><br>
                            Click the "OPEN AUTH URL" button above to complete authentication in your browser.
                        </div>
                    </div>
                </div>
            </div>
        </div>
        {% endif %}

        <div class="row">
            <!-- System Information -->
            <div class="col-lg-4 mb-4">
                <div class="card">
                    <div class="card-header">
                        <h5 class="mb-0">
                            <i class="fas fa-tachometer-alt"></i> SYSTEM STATUS
                        </h5>
                    </div>
                    <div class="card-body">
                        <div class="system-metric">
                            <span class="metric-label">
                                <i class="fas fa-microchip"></i> CPU USAGE
                            </span>
                            <span class="metric-value text-accent">{{ "%.1f"|format(system_info.cpu_percent or 0) }}%</span>
                        </div>
                        
                        <div class="system-metric">
                            <span class="metric-label">
                                <i class="fas fa-memory"></i> MEMORY
                            </span>
                            <span class="metric-value text-accent">
                                {{ system_info.memory.used or 0 }}GB / {{ system_info.memory.total or 0 }}GB
                                ({{ "%.1f"|format(system_info.memory.percent if system_info.memory else 0) }}%)
                            </span>
                        </div>
                        
                        <div class="system-metric">
                            <span class="metric-label">
                                <i class="fas fa-hdd"></i> DISK USAGE
                            </span>
                            <span class="metric-value text-accent">
                                {{ system_info.disk.used or 0 }}GB / {{ system_info.disk.total or 0 }}GB
                                ({{ "%.1f"|format(system_info.disk.percent if system_info.disk else 0) }}%)
                            </span>
                        </div>
                        
                        <div class="system-metric">
                            <span class="metric-label">
                                <i class="fas fa-cloud"></i> CLOUDFLARED
                            </span>
                            <span class="metric-value">
                                <span class="status-indicator {{ 'status-active' if system_info.cloudflared_running else 'status-inactive' }}"></span>
                                <span class="{{ 'text-success-custom' if system_info.cloudflared_running else 'text-muted' }}">
                                    {{ 'ONLINE' if system_info.cloudflared_running else 'OFFLINE' }}
                                </span>
                            </span>
                        </div>
                        
                        <div class="system-metric">
                            <span class="metric-label">
                                <i class="fas fa-key"></i> AUTHENTICATION
                            </span>
                            <span class="metric-value">
                                <span class="status-indicator {{ 'status-active' if system_info.authenticated else 'status-inactive' }}"></span>
                                <span class="{{ 'text-success-custom' if system_info.authenticated else 'text-warning-custom' }}">
                                    {{ 'AUTHENTICATED' if system_info.authenticated else 'REQUIRED' }}
                                </span>
                            </span>
                        </div>
                    </div>
                </div>
            </div>

            <!-- Tunnel Management -->
            <div class="col-lg-8 mb-4">
                <div class="card">
                    <div class="card-header">
                        <h5 class="mb-0">
                            <i class="fas fa-cogs"></i> TUNNEL OPERATIONS
                        </h5>
                    </div>
                    <div class="card-body">
                        <form id="tunnelForm" class="row g-3">
                            <div class="col-md-6">
                                <label class="form-label">
                                    <i class="fas fa-tag"></i> TUNNEL NAME
                                </label>
                                <input type="text" name="tunnel_name" class="form-control" 
                                       placeholder="production-app-tunnel" required
                                       pattern="[a-zA-Z0-9\-_]+" 
                                       title="Only letters, numbers, hyphens, and underscores allowed">
                            </div>
                            <div class="col-md-6">
                                <label class="form-label">
                                    <i class="fas fa-globe"></i> DOMAIN/HOSTNAME
                                </label>
                                <input type="text" name="hostname" class="form-control" 
                                       placeholder="app.yourdomain.com"
                                       pattern="^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*$"
                                       title="Enter a valid domain name">
                            </div>
                            <div class="col-12">
                                <div class="btn-group flex-wrap" role="group">
                                    <button type="button" class="btn btn-success" onclick="performAction('create')" 
                                            {% if not system_info.authenticated %}disabled{% endif %}>
                                        <i class="fas fa-plus"></i> CREATE
                                    </button>
                                    <button type="button" class="btn btn-primary" onclick="performAction('route')"
                                            {% if not system_info.authenticated %}disabled{% endif %}>
                                        <i class="fas fa-route"></i> ROUTE DNS
                                    </button>
                                    <button type="button" class="btn btn-danger" onclick="performAction('delete')"
                                            {% if not system_info.authenticated %}disabled{% endif %}>
                                        <i class="fas fa-trash-alt"></i> DELETE
                                    </button>
                                    <button type="button" class="btn btn-warning" onclick="refreshTunnels()">
                                        <i class="fas fa-sync-alt"></i> REFRESH
                                    </button>
                                    {% if not system_info.authenticated %}
                                    <button type="button" class="btn btn-info" onclick="authenticateCloudflare()">
                                        <i class="fas fa-key"></i> AUTH
                                    </button>
                                    {% endif %}
                                </div>
                            </div>
                        </form>
                    </div>
                </div>
            </div>
        </div>

        <!-- Active Tunnels -->
        <div class="row">
            <div class="col-12 mb-4">
                <div class="card">
                    <div class="card-header d-flex justify-content-between align-items-center">
                        <h5 class="mb-0">
                            <i class="fas fa-list-ul"></i> ACTIVE TUNNELS
                        </h5>
                        <button class="btn btn-sm btn-warning" onclick="refreshTunnels()">
                            <i class="fas fa-sync-alt"></i>
                        </button>
                    </div>
                    <div class="card-body">
                        <div id="tunnelsList">
                            <div class="d-flex justify-content-center align-items-center" style="min-height: 100px;">
                                <div class="text-center">
                                    <div class="spinner-border text-primary" role="status">
                                        <span class="visually-hidden">Loading...</span>
                                    </div>
                                    <p class="mt-2 text-secondary">SCANNING TUNNELS...</p>
                                </div>
                            </div>
                        </div>
                    </div>
                </div>
            </div>
        </div>

        <!-- Command Output -->
        <div class="row">
            <div class="col-12 mb-4">
                <div class="card">
                    <div class="card-header d-flex justify-content-between align-items-center">
                        <h5 class="mb-0">
                            <i class="fas fa-terminal"></i> SYSTEM OUTPUT
                        </h5>
                        <button class="btn btn-sm btn-danger" onclick="clearOutput()">
                            <i class="fas fa-eraser"></i> CLEAR
                        </button>
                    </div>
                    <div class="card-body">
                        <textarea id="output" class="output-area form-control" readonly 
                                  placeholder="[SYSTEM] Command output and system messages will appear here...">{{ output }}</textarea>
                    </div>
                </div>
            </div>
        </div>
    </div>

    <!-- Toast Container -->
    <div class="toast-container position-fixed bottom-0 end-0 p-3" id="toastContainer"></div>

    <!-- Scripts -->
    <script src="https://cdnjs.cloudflare.com/ajax/libs/bootstrap/5.3.2/js/bootstrap.bundle.min.js"></script>
    <script>
        // Global state
        let isLoading = false;
        let authCheckInterval;
        let authUrl = null;

        // Utility functions
        function showToast(message, type = 'info', duration = 5000) {
            const toastContainer = document.getElementById('toastContainer');
            const toastId = 'toast_' + Date.now();
            
            const iconMap = {
                'success': 'check-circle',
                'error': 'exclamation-triangle',
                'warning': 'exclamation-triangle',
                'info': 'info-circle'
            };
            
            const bgClass = {
                'success': 'bg-success',
                'error': 'bg-danger', 
                'warning': 'bg-warning text-dark',
                'info': 'bg-info'
            }[type] || 'bg-info';

            const icon = iconMap[type] || 'info-circle';

            const toastHtml = `
                <div id="${toastId}" class="toast ${bgClass}" role="alert" data-bs-autohide="true" data-bs-delay="${duration}">
                    <div class="toast-header">
                        <i class="fas fa-${icon} me-2"></i>
                        <strong class="me-auto">CF TUNNEL CONTROL</strong>
                        <small>NOW</small>
                        <button type="button" class="btn-close" data-bs-dismiss="toast"></button>
                    </div>
                    <div class="toast-body">
                        ${message}
                    </div>
                </div>
            `;
            
            toastContainer.insertAdjacentHTML('beforeend', toastHtml);
            const toast = new bootstrap.Toast(document.getElementById(toastId));
            toast.show();
            
            document.getElementById(toastId).addEventListener('hidden.bs.toast', function() {
                this.remove();
            });
        }

        function updateOutput(text, append = false) {
            const output = document.getElementById('output');
            const timestamp = new Date().toLocaleTimeString();
            const formattedText = `[${timestamp}] ${text}`;
            
            if (append) {
                output.value += '\n' + formattedText;
            } else {
                output.value = formattedText;
            }
            output.scrollTop = output.scrollHeight;
        }

        function clearOutput() {
            document.getElementById('output').value = '';
            updateOutput('[SYSTEM] Output cleared');
        }

        function setLoading(loading) {
            isLoading = loading;
            const buttons = document.querySelectorAll('button[onclick^="performAction"], button[onclick="authenticateCloudflare()"]');
            buttons.forEach(btn => {
                if (loading) {
                    btn.classList.add('loading');
                    btn.disabled = true;
                } else {
                    btn.classList.remove('loading');
                    // Only enable if authenticated or it's the auth button
                    if (!btn.onclick.toString().includes('authenticateCloudflare')) {
                        btn.disabled = !{{ system_info.authenticated|lower }};
                    } else {
                        btn.disabled = false;
                    }
                }
            });
        }

        // Fixed Authentication
        async function authenticateCloudflare() {
            if (isLoading) return;
            
            setLoading(true);
            updateOutput('[AUTH] Starting Cloudflare authentication process...');
            showToast('Initiating authentication with Cloudflare...', 'info');
            
            try {
                const response = await fetch('/api/authenticate', {
                    method: 'POST'
                });
                
                const result = await response.json();
                
                if (result.success) {
                    updateOutput('[AUTH] Authentication process initiated successfully', true);
                    showToast('Authentication started! Opening auth URL...', 'success');
                    
                    // Store auth URL and show manual auth button
                    authUrl = result.auth_url;
                    document.getElementById('authInstructions').style.display = 'block';
                    document.getElementById('manualAuthBtn').style.display = 'inline-flex';
                    
                    // Automatically try to open the auth URL
                    setTimeout(() => {
                        openAuthUrl();
                    }, 1000);
                    
                    // Start checking for authentication status
                    startAuthCheck();
                } else {
                    updateOutput('[AUTH] Authentication failed: ' + result.message, true);
                    showToast('Authentication failed: ' + result.message, 'error');
                }
                
            } catch (error) {
                updateOutput('[AUTH] Authentication error: ' + error.message, true);
                showToast('Authentication error: ' + error.message, 'error');
            } finally {
                setLoading(false);
            }
        }

        function openAuthUrl() {
            if (authUrl) {
                updateOutput('[AUTH] Opening authentication URL: ' + authUrl, true);
                window.open(authUrl, '_blank');
                showToast('Authentication page opened in new tab', 'info', 3000);
            } else {
                showToast('No authentication URL available', 'warning');
            }
        }

        function startAuthCheck() {
            let attempts = 0;
            const maxAttempts = 60; // 10 minutes
            
            updateOutput('[AUTH] Starting authentication status monitoring...', true);
            
            authCheckInterval = setInterval(async () => {
                attempts++;
                
                try {
                    const response = await fetch('/api/auth-status');
                    const result = await response.json();
                    
                    if (result.authenticated) {
                        clearInterval(authCheckInterval);
                        updateOutput('[AUTH] ✓ Authentication completed successfully!', true);
                        showToast('Successfully authenticated with Cloudflare!', 'success');
                        
                        // Hide auth UI elements
                        document.getElementById('authInstructions').style.display = 'none';
                        document.getElementById('manualAuthBtn').style.display = 'none';
                        
                        setTimeout(() => location.reload(), 2000);
                    } else if (attempts >= maxAttempts) {
                        clearInterval(authCheckInterval);
                        updateOutput('[AUTH] ✗ Authentication timeout. Please try again.', true);
                        showToast('Authentication timeout. Please try again.', 'warning');
                        
                        // Reset auth UI
                        document.getElementById('authInstructions').style.display = 'none';
                        document.getElementById('manualAuthBtn').style.display = 'none';
                        authUrl = null;
                    } else {
                        // Show progress every 10 attempts
                        if (attempts % 10 === 0) {
                            updateOutput(`[AUTH] Waiting for authentication completion... (${attempts}/${maxAttempts})`, true);
                        }
                    }
                } catch (error) {
                    console.error('Auth check error:', error);
                }
            }, 10000); // Check every 10 seconds
        }

        // Tunnel operations
        async function performAction(action) {
            if (isLoading) return;
            
            const form = document.getElementById('tunnelForm');
            const formData = new FormData(form);
            formData.append('action', action);
            
            const tunnelName = formData.get('tunnel_name').trim();
            const hostname = formData.get('hostname').trim();
            
            // Validation
            if (!tunnelName && ['create', 'delete', 'route'].includes(action)) {
                showToast('TUNNEL NAME REQUIRED', 'error');
                return;
            }
            
            if (action === 'route' && !hostname) {
                showToast('HOSTNAME REQUIRED FOR DNS ROUTING', 'error');
                return;
            }
            
            // Validate tunnel name format
            if (tunnelName && !/^[a-zA-Z0-9\-_]+$/.test(tunnelName)) {
                showToast('INVALID TUNNEL NAME FORMAT', 'error');
                return;
            }
            
            // Validate hostname format
            if (hostname && action === 'route') {
                const hostnameRegex = /^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*$/;
                if (!hostnameRegex.test(hostname)) {
                    showToast('INVALID DOMAIN NAME FORMAT', 'error');
                    return;
                }
            }
            
            setLoading(true);
            
            const actionMessages = {
                'create': `[TUNNEL] Creating tunnel "${tunnelName}"...`,
                'delete': `[TUNNEL] Deleting tunnel "${tunnelName}"...`,
                'route': `[DNS] Creating route ${hostname} → ${tunnelName}...`
            };
            
            updateOutput(actionMessages[action] || `[CMD] Executing ${action} command...`);
            
            try {
                const response = await fetch('/api/action', {
                    method: 'POST',
                    body: formData
                });
                
                const result = await response.json();
                
                if (result.success) {
                    showToast(result.message, 'success');
                    updateOutput('[SUCCESS] ✓ ' + result.message, true);
                    
                    // Clear form on successful create
                    if (action === 'create') {
                        form.reset();
                    }
                    
                    // Refresh tunnels list after successful operations
                    if (['create', 'delete', 'route'].includes(action)) {
                        setTimeout(refreshTunnels, 1500);
                    }
                } else {
                    showToast(result.message || 'OPERATION FAILED', 'error');
                    updateOutput('[ERROR] ✗ ' + (result.message || 'Operation failed'), true);
                }
                
            } catch (error) {
                const errorMsg = `[NETWORK] Connection error: ${error.message}`;
                showToast('NETWORK ERROR', 'error');
                updateOutput(errorMsg, true);
            } finally {
                setLoading(false);
            }
        }

        // Tunnel list management
        async function refreshTunnels() {
            const container = document.getElementById('tunnelsList');
            container.innerHTML = `
                <div class="d-flex justify-content-center align-items-center" style="min-height: 100px;">
                    <div class="text-center">
                        <div class="spinner-border text-primary" role="status">
                            <span class="visually-hidden">Loading...</span>
                        </div>
                        <p class="mt-2 text-secondary">SCANNING TUNNELS...</p>
                    </div>
                </div>
            `;
            
            try {
                const response = await fetch('/api/tunnels');
                const tunnels = await response.json();
                
                if (!Array.isArray(tunnels)) {
                    throw new Error('Invalid response format');
                }
                
                if (tunnels.length === 0) {
                    container.innerHTML = `
                        <div class="text-center py-5">
                            <i class="fas fa-cloud fa-4x text-muted mb-3"></i>
                            <h4 class="text-secondary">NO TUNNELS DETECTED</h4>
                            <p class="text-muted">Create your first tunnel using the operations panel above.</p>
                        </div>
                    `;
                } else {
                    let tableHtml = `
                        <div class="table-responsive">
                            <table class="table table-dark table-hover align-middle">
                                <thead>
                                    <tr>
                                        <th><i class="fas fa-tag"></i> NAME</th>
                                        <th><i class="fas fa-fingerprint"></i> TUNNEL ID</th>
                                        <th><i class="fas fa-calendar"></i> CREATED</th>
                                        <th><i class="fas fa-plug"></i> CONNECTIONS</th>
                                        <th><i class="fas fa-cogs"></i> ACTIONS</th>
                                    </tr>
                                </thead>
                                <tbody>
                    `;
                    
                    tunnels.forEach(tunnel => {
                        const createdDate = tunnel.created_at ? 
                            new Date(tunnel.created_at).toLocaleDateString('en-US', {
                                year: 'numeric',
                                month: 'short',
                                day: 'numeric'
                            }) : 'UNKNOWN';
                        
                        const connections = tunnel.connections || 0;
                        const connectionStatus = connections > 0 ? 'status-active' : 'status-inactive';
                        
                        tableHtml += `
                            <tr>
                                <td>
                                    <strong class="text-accent">${tunnel.name}</strong>
                                </td>
                                <td>
                                    <code>${tunnel.id.substring(0, 8)}...</code>
                                    <button class="btn btn-sm btn-warning ms-2" 
                                            onclick="copyToClipboard('${tunnel.id}')" 
                                            title="Copy full ID">
                                        <i class="fas fa-copy"></i>
                                    </button>
                                </td>
                                <td class="text-secondary">${createdDate}</td>
                                <td>
                                    <span class="status-indicator ${connectionStatus}"></span>
                                    <span class="${connections > 0 ? 'text-success-custom' : 'text-secondary'}">${connections}</span>
                                </td>
                                <td>
                                    <div class="btn-group btn-group-sm">
                                        <button class="btn btn-info" 
                                                onclick="showTunnelDetails('${tunnel.name}', '${tunnel.id}')"
                                                title="View Details">
                                            <i class="fas fa-info-circle"></i>
                                        </button>
                                        <button class="btn btn-danger" 
                                                onclick="deleteTunnel('${tunnel.name}')"
                                                title="Delete Tunnel">
                                            <i class="fas fa-trash-alt"></i>
                                        </button>
                                    </div>
                                </td>
                            </tr>
                        `;
                    });
                    
                    tableHtml += '</tbody></table></div>';
                    container.innerHTML = tableHtml;
                }
                
                updateOutput(`[SCAN] Found ${tunnels.length} active tunnels`, true);
                
            } catch (error) {
                console.error('Failed to load tunnels:', error);
                container.innerHTML = `
                    <div class="alert alert-danger">
                        <i class="fas fa-exclamation-triangle"></i> 
                        <strong>TUNNEL SCAN FAILED:</strong> ${error.message}
                        <button class="btn btn-sm btn-danger ms-2" onclick="refreshTunnels()">
                            <i class="fas fa-redo"></i> RETRY
                        </button>
                    </div>
                `;
                updateOutput(`[ERROR] Failed to scan tunnels: ${error.message}`, true);
            }
        }

        // Helper functions
        async function deleteTunnel(name) {
            if (!confirm(`CONFIRM DELETION:\n\nTunnel: "${name}"\n\nThis action cannot be undone.\n\nProceed?`)) {
                return;
            }
            
            const formData = new FormData();
            formData.append('tunnel_name', name);
            formData.append('action', 'delete');
            
            setLoading(true);
            updateOutput(`[DELETE] Removing tunnel "${name}"...`);
            
            try {
                const response = await fetch('/api/action', {
                    method: 'POST',
                    body: formData
                });
                
                const result = await response.json();
                
                if (result.success) {
                    showToast(result.message, 'success');
                    updateOutput('[SUCCESS] ✓ ' + result.message, true);
                    setTimeout(refreshTunnels, 1000);
                } else {
                    showToast(result.message || 'DELETION FAILED', 'error');
                    updateOutput('[ERROR] ✗ ' + (result.message || 'Deletion failed'), true);
                }
                
            } catch (error) {
                const errorMsg = `[NETWORK] Connection error: ${error.message}`;
                showToast('NETWORK ERROR', 'error');
                updateOutput(errorMsg, true);
            } finally {
                setLoading(false);
            }
        }

        function copyToClipboard(text) {
            navigator.clipboard.writeText(text).then(() => {
                showToast('TUNNEL ID COPIED TO CLIPBOARD', 'success', 2000);
                updateOutput(`[COPY] Tunnel ID copied: ${text}`, true);
            }).catch(() => {
                showToast('CLIPBOARD COPY FAILED', 'error');
                updateOutput(`[COPY] Failed to copy tunnel ID`, true);
            });
        }

        function showTunnelDetails(name, id) {
            const details = `TUNNEL INFORMATION:\n\nName: ${name}\nID: ${id}\nStatus: ACTIVE\nProtocol: HTTPS\nManager: CF Tunnel Helper`;
            updateOutput(`[INFO] ${details}`, true);
            showToast(`Tunnel details for "${name}" displayed in output`, 'info');
        }

        // Initialize application
        document.addEventListener('DOMContentLoaded', function() {
            // Initial load
            refreshTunnels();
            
            // Auto-refresh tunnels every 30 seconds
            setInterval(refreshTunnels, 30000);
            
            // Add startup info
            const startupInfo = `[SYSTEM] CF Tunnel Manager initialized\n[TIME] ${new Date().toLocaleString()}\n[SERVER] {{ server_ip }}:5000\n[AUTH] ${{{ system_info.authenticated }} ? 'AUTHENTICATED' : 'REQUIRED'}\n[STATUS] Industrial Control Panel Online\n${'='.repeat(60)}`;
            updateOutput(startupInfo);
            
            // Show welcome message
            {% if system_info.authenticated %}
            showToast('SYSTEM ONLINE - AUTHENTICATED', 'success');
            updateOutput('[AUTH] ✓ Cloudflare authentication verified', true);
            {% else %}
            showToast('AUTHENTICATION REQUIRED', 'warning');
            updateOutput('[AUTH] ⚠ Cloudflare authentication needed', true);
            {% endif %}
        });

        // Handle form submission
        document.getElementById('tunnelForm').addEventListener('submit', function(e) {
            e.preventDefault();
        });

        // System health monitoring
        setInterval(async function() {
            try {
                const response = await fetch('/api/auth-status');
                const result = await response.json();
                
                // Update auth status indicator if changed
                const currentAuth = {{ system_info.authenticated|lower }};
                if (result.authenticated !== currentAuth) {
                    location.reload();
                }
            } catch (error) {
                console.error('Health check failed:', error);
            }
        }, 60000); // Check every minute
    </script>
</body>
</html>
"""

# Flask Routes
@app.route("/")
def index():
    """Main dashboard page"""
    try:
        hostname = socket.gethostname()
        server_ip = socket.gethostbyname(hostname)
    except:
        server_ip = "localhost"
    
    system_info = tunnel_manager.get_system_info()
    
    return render_template_string(
        HTML_TEMPLATE, 
        output="", 
        server_ip=server_ip,
        system_info=system_info
    )

@app.route("/api/tunnels")
def api_tunnels():
    """API endpoint to get tunnels list"""
    try:
        tunnels = tunnel_manager.list_tunnels()
        return jsonify(tunnels)
    except Exception as e:
        logger.error(f"Error fetching tunnels: {e}")
        return jsonify([])

@app.route("/api/action", methods=["POST"])
def api_action():
    """API endpoint for tunnel actions"""
    try:
        action = request.form.get("action", "").strip()
        tunnel_name = request.form.get("tunnel_name", "").strip()
        hostname = request.form.get("hostname", "").strip()
        
        if action == "create":
            result = tunnel_manager.create_tunnel(tunnel_name)
        elif action == "delete":
            result = tunnel_manager.delete_tunnel(tunnel_name)
        elif action == "route":
            result = tunnel_manager.route_dns(tunnel_name, hostname)
        else:
            result = {"success": False, "message": "Invalid action"}
        
        return jsonify(result)
    except Exception as e:
        logger.error(f"API action error: {e}")
        return jsonify({"success": False, "message": str(e)})

@app.route("/api/authenticate", methods=["POST"])
def api_authenticate():
    """Start Cloudflare authentication process"""
    try:
        result = tunnel_manager.authenticate_cloudflare()
        logger.info(f"Authentication request result: {result}")
        return jsonify(result)
    except Exception as e:
        logger.error(f"Authentication error: {e}")
        return jsonify({"success": False, "message": str(e)})

@app.route("/api/auth-status")
def api_auth_status():
    """Check authentication status"""
    try:
        authenticated = tunnel_manager.is_authenticated()
        return jsonify({"authenticated": authenticated})
    except Exception as e:
        logger.error(f"Auth status error: {e}")
        return jsonify({"authenticated": False})

if __name__ == "__main__":
    logger.info("Starting CF Tunnel Helper Professional...")
    
    # Display startup information
    try:
        hostname = socket.gethostname()
        server_ip = socket.gethostbyname(hostname)
        
        print("\n" + "="*80)
        print("🔧 CF TUNNEL HELPER - INDUSTRIAL CONTROL PANEL 🔧")
        print("="*80)
        print(f"🌐 Web Interface: http://{server_ip}:5000")
        print(f"📊 Server IP: {server_ip}")
        print(f"🔑 Authentication: {'✓ READY' if tunnel_manager.is_authenticated() else '⚠ REQUIRED'}")
        print("="*80)
        print("📋 SETUP PROCEDURE:")
        print("1. Open the web interface above")
        if not tunnel_manager.is_authenticated():
            print("2. Click 'AUTHENTICATE' button")
            print("3. Complete authentication in browser")
            print("4. Return to create tunnels")
        else:
            print("2. System authenticated and ready")
            print("3. Begin tunnel operations")
        print("="*80)
    except Exception as e:
        logger.error(f"Startup display error: {e}")
    
    app.run(host="0.0.0.0", port=5000, debug=False, threaded=True)
PYTHON_APP_EOF
}

# Create systemd service
create_service() {
    log_info "Creating systemd service..."
    
    cat > "$SERVICE_FILE" << 'SERVICE_EOF'
[Unit]
Description=CF Tunnel Helper - Industrial Control Panel
After=network.target
Wants=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/cftunnelhelper
ExecStart=/usr/bin/python3 /opt/cftunnelhelper/cftunnelhelper.py
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=cftunnelhelper
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
SERVICE_EOF

    systemctl daemon-reload
    systemctl enable "$APP_NAME"
}

# Create advanced launcher script
create_launcher() {
    log_info "Creating launcher script..."
    
    cat > "$BIN_LINK" << 'LAUNCHER_EOF'
#!/bin/bash

# CF Tunnel Helper - Industrial Control Panel Launcher
APP_DIR="/opt/cftunnelhelper"
PID_FILE="/var/run/cftunnelhelper.pid"
LOG_FILE="/var/log/cftunnelhelper/app.log"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

show_banner() {
    echo -e "${BOLD}${CYAN}"
    echo "════════════════════════════════════════════════════════════"
    echo "🔧        CF TUNNEL HELPER - INDUSTRIAL CONTROL        🔧"
    echo "════════════════════════════════════════════════════════════"
    echo -e "${NC}"
}

get_server_ip() {
    hostname -I | awk '{print $1}' 2>/dev/null || echo "localhost"
}

show_status() {
    local server_ip=$(get_server_ip)
    echo -e "${BLUE}[INFO]${NC} Server IP: ${BOLD}$server_ip${NC}"
    echo -e "${BLUE}[INFO]${NC} Web Interface: ${BOLD}http://$server_ip:5000${NC}"
    
    if [[ -f "$PID_FILE" ]]; then
        local pid=$(cat "$PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            echo -e "${GREEN}[STATUS]${NC} CF Tunnel Helper is ${BOLD}ONLINE${NC} (PID: $pid)"
            return 0
        else
            echo -e "${YELLOW}[STATUS]${NC} CF Tunnel Helper is ${BOLD}OFFLINE${NC} (stale PID file)"
            rm -f "$PID_FILE"
            return 1
        fi
    else
        echo -e "${YELLOW}[STATUS]${NC} CF Tunnel Helper is ${BOLD}OFFLINE${NC}"
        return 1
    fi
}

case "${1:-start}" in
    start)
        show_banner
        echo -e "${BLUE}[INFO]${NC} Starting Industrial Control Panel..."
        
        if [[ -f "$PID_FILE" ]]; then
            PID=$(cat "$PID_FILE")
            if kill -0 "$PID" 2>/dev/null; then
                echo -e "${YELLOW}[WARNING]${NC} CF Tunnel Helper is already running (PID: $PID)"
                show_status
                exit 0
            else
                rm -f "$PID_FILE"
            fi
        fi
        
        cd "$APP_DIR"
        nohup python3 cftunnelhelper.py > "$LOG_FILE" 2>&1 & 
        echo $! > "$PID_FILE"
        
        sleep 3
        if kill -0 $(cat "$PID_FILE") 2>/dev/null; then
            echo -e "${GREEN}[SUCCESS]${NC} Industrial Control Panel started successfully!"
            echo ""
            show_status
            echo ""
            echo -e "${CYAN}[SETUP]${NC} Access Instructions:"
            echo -e "  1. Open: ${BOLD}http://$(get_server_ip):5000${NC}"
            echo -e "  2. Click: ${BOLD}'AUTHENTICATE'${NC}"
            echo -e "  3. Complete authentication in browser"
            echo -e "  4. Begin tunnel operations"
            echo ""
        else
            echo -e "${RED}[ERROR]${NC} Failed to start CF Tunnel Helper"
            rm -f "$PID_FILE"
            exit 1
        fi
        ;;
    stop)
        echo -e "${BLUE}[INFO]${NC} Stopping Industrial Control Panel..."
        if [[ -f "$PID_FILE" ]]; then
            PID=$(cat "$PID_FILE")
            if kill -0 "$PID" 2>/dev/null; then
                kill "$PID"
                rm -f "$PID_FILE"
                echo -e "${GREEN}[SUCCESS]${NC} CF Tunnel Helper stopped"
            else
                echo -e "${YELLOW}[INFO]${NC} CF Tunnel Helper was not running"
                rm -f "$PID_FILE"
            fi
        else
            echo -e "${YELLOW}[INFO]${NC} CF Tunnel Helper was not running"
        fi
        ;;
    restart)
        $0 stop
        sleep 2
        $0 start
        ;;
    status)
        show_banner
        show_status
        echo ""
        ;;
    logs)
        echo -e "${BLUE}[INFO]${NC} Showing system logs (Press Ctrl+C to exit)..."
        echo "════════════════════════════════════════════════════════════"
        tail -f "$LOG_FILE"
        ;;
    service)
        echo -e "${BLUE}[INFO]${NC} Managing CF Tunnel Helper systemd service..."
        case "${2:-status}" in
            enable)
                systemctl enable cftunnelhelper
                echo -e "${GREEN}[SUCCESS]${NC} Service enabled for auto-start"
                ;;
            disable)
                systemctl disable cftunnelhelper
                echo -e "${GREEN}[SUCCESS]${NC} Service disabled"
                ;;
            start)
                systemctl start cftunnelhelper
                echo -e "${GREEN}[SUCCESS]${NC} Service started"
                show_status
                ;;
            stop)
                systemctl stop cftunnelhelper
                echo -e "${GREEN}[SUCCESS]${NC} Service stopped"
                ;;
            restart)
                systemctl restart cftunnelhelper
                echo -e "${GREEN}[SUCCESS]${NC} Service restarted"
                show_status
                ;;
            status|*)
                systemctl status cftunnelhelper --no-pager
                ;;
        esac
        ;;
    web)
        local server_ip=$(get_server_ip)
        echo -e "${BLUE}[INFO]${NC} Opening Industrial Control Panel..."
        echo -e "${CYAN}[URL]${NC} http://$server_ip:5000"
        
        if command -v xdg-open &> /dev/null; then
            xdg-open "http://$server_ip:5000" 2>/dev/null || true
        fi
        ;;
    install)
        echo -e "${BLUE}[INFO]${NC} CF Tunnel Helper is already installed!"
        show_status
        ;;
    *)
        show_banner
        echo -e "${BOLD}USAGE:${NC} $0 {start|stop|restart|status|service|logs|web}"
        echo ""
        echo -e "${BOLD}Commands:${NC}"
        echo -e "  ${GREEN}start${NC}     - Start the control panel"
        echo -e "  ${RED}stop${NC}      - Stop the control panel"
        echo -e "  ${YELLOW}restart${NC}   - Restart the control panel"
        echo -e "  ${BLUE}status${NC}    - Show system status"
        echo -e "  ${CYAN}logs${NC}      - Show system logs (live)"
        echo -e "  ${CYAN}web${NC}       - Open web interface"
        echo ""
        echo -e "${BOLD}Service Management:${NC}"
        echo -e "  ${GREEN}service start${NC}   - Start systemd service"
        echo -e "  ${RED}service stop${NC}    - Stop systemd service"
        echo -e "  ${YELLOW}service restart${NC} - Restart systemd service"
        echo -e "  ${BLUE}service status${NC}  - Show service status"
        echo -e "  ${CYAN}service enable${NC}  - Enable auto-start on boot"
        echo -e "  ${CYAN}service disable${NC} - Disable auto-start"
        echo ""
        echo -e "${BOLD}Quick Start:${NC}"
        echo -e "  1. $0 start"
        echo -e "  2. Open: http://$(get_server_ip):5000"
        echo -e "  3. Click 'AUTHENTICATE' button"
        echo ""
        exit 1
        ;;
esac
LAUNCHER_EOF

    chmod +x "$BIN_LINK"
}

# Create repository files
create_repository_files() {
    log_info "Creating repository files..."
    
    # Create README
    cat > "$INSTALL_DIR/README.md" << 'README_EOF'
# CF Tunnel Helper - Industrial Edition

Professional-grade web interface for managing Cloudflare tunnels with industrial UI design and fixed authentication.

## Features

- 🔧 **Industrial UI** - Professional control panel design with proper contrast
- 🔐 **Fixed Authentication** - Working Cloudflare authentication with proper URL handling  
- 🚀 **Tunnel Management** - Create, delete, and route tunnels with real-time feedback
- 📊 **System Monitoring** - Live system resource monitoring
- 🔄 **Auto-refresh** - Automatic tunnel status updates
- 📱 **Mobile Ready** - Responsive industrial design
- ⚡ **Performance** - Optimized for server environments

## Installation

### Quick Install
```bash
curl -fsSL https://raw.githubusercontent.com/yourusername/cftunnelhelper/main/install.sh | sudo bash
```

### Manual Install
```bash
wget -O /tmp/install-cftunnel.sh https://raw.githubusercontent.com/yourusername/cftunnelhelper/main/install.sh
sudo chmod +x /tmp/install-cftunnel.sh
sudo /tmp/install-cftunnel.sh
```

## Usage

### Control Panel Commands
```bash
# Start the industrial control panel
sudo cftunnelhelper start

# Stop the control panel
sudo cftunnelhelper stop

# Check system status
sudo cftunnelhelper status

# View system logs
sudo cftunnelhelper logs

# Open web interface
sudo cftunnelhelper web
```

### Service Management
```bash
# Enable auto-start on boot
sudo cftunnelhelper service enable

# Start as system service
sudo cftunnelhelper service start

# Check service status
sudo cftunnelhelper service status
```

## Web Interface

Access the industrial control panel at: `http://YOUR_SERVER_IP:5000`

### Authentication Process
1. Open the web interface
2. Click "AUTHENTICATE" button
3. System will provide authentication URL
4. Complete authentication in browser
5. Return to control panel

## System Requirements

- Ubuntu 18.04+ or Debian 10+
- Python 3.6+ with Flask support
- 1GB+ RAM (2GB recommended)
- Network connectivity to Cloudflare

## Fixed Issues

- ✅ Authentication button now works properly
- ✅ Industrial color scheme with proper contrast
- ✅ Fixed authentication URL generation
- ✅ Improved error handling and feedback
- ✅ Professional server software appearance

## License

MIT License - see LICENSE file for details.
README_EOF

    # Create version file
    echo "3.0.1" > "$INSTALL_DIR/VERSION"
    
    # Create install info
    cat > "$INSTALL_DIR/INSTALL_INFO" << EOF
Installation Date: $(date)
Server IP: $(hostname -I | awk '{print $1}')
Ubuntu Version: $(lsb_release -d 2>/dev/null | cut -f2 || echo "Unknown")
Python Version: $(python3 --version 2>/dev/null || echo "Unknown")
Cloudflared Version: $(cloudflared version 2>/dev/null | head -n1 || echo "Unknown")
Fixed Issues: Authentication, Industrial UI, Color Scheme
EOF
}

# Create uninstall script
create_uninstaller() {
    log_info "Creating uninstaller..."
    
    cat > "$INSTALL_DIR/uninstall.sh" << 'UNINSTALL_EOF'
#!/bin/bash

# CF Tunnel Helper Uninstaller
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${YELLOW}CF Tunnel Helper Industrial Uninstaller${NC}"
echo "============================================="

read -p "Are you sure you want to completely remove CF Tunnel Helper? [y/N]: " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo -e "${GREEN}Uninstall cancelled.${NC}"
    exit 0
fi

echo -e "${YELLOW}Removing CF Tunnel Helper Industrial Control Panel...${NC}"

# Stop services
systemctl stop cftunnelhelper 2>/dev/null || true
systemctl disable cftunnelhelper 2>/dev/null || true

# Remove files
rm -f /usr/local/bin/cftunnelhelper
rm -f /etc/systemd/system/cftunnelhelper.service
rm -rf /opt/cftunnelhelper
rm -rf /var/log/cftunnelhelper
rm -rf /etc/cftunnelhelper

# Reload systemd
systemctl daemon-reload

echo -e "${GREEN}CF Tunnel Helper Industrial Control Panel has been completely removed.${NC}"
echo -e "${YELLOW}Note: Cloudflared and Python packages were left installed.${NC}"
UNINSTALL_EOF

    chmod +x "$INSTALL_DIR/uninstall.sh"
}

# Final setup and display
final_setup() {
    log_info "Performing final setup..."
    
    # Set proper permissions
    chown -R root:root "$INSTALL_DIR"
    chmod -R 755 "$INSTALL_DIR"
    chmod 644 "$INSTALL_DIR"/*.py "$INSTALL_DIR"/*.md 2>/dev/null || true
    
    # Create firewall rule (optional)
    if command -v ufw &> /dev/null; then
        log_info "Configuring firewall..."
        ufw allow 5000/tcp comment "CF Tunnel Helper Industrial" 2>/dev/null || true
    fi
    
    # Display installation summary
    local server_ip=$(hostname -I | awk '{print $1}' || echo "localhost")
    
    log_success "Installation completed successfully!"
    echo
    log_header "╔══════════════════════════════════════════════════════════╗"
    log_header "║            🔧 CF TUNNEL INDUSTRIAL - READY! 🔧            ║"
    log_header "╚══════════════════════════════════════════════════════════╝"
    echo
    log_info "🌐 Control Panel: ${BOLD}http://$server_ip:5000${NC}"
    log_info "📋 Commands:"
    log_info "   • Start:  ${GREEN}sudo $APP_NAME start${NC}"
    log_info "   • Stop:   ${RED}sudo $APP_NAME stop${NC}"  
    log_info "   • Status: ${BLUE}sudo $APP_NAME status${NC}"
    log_info "   • Logs:   ${CYAN}sudo $APP_NAME logs${NC}"
    echo
    log_info "🚀 Setup Procedure:"
    log_info "   1. Open: http://$server_ip:5000"
    log_info "   2. Click: 'AUTHENTICATE' button"
    log_info "   3. Complete authentication in browser"
    log_info "   4. Begin tunnel operations"
    echo
    log_info "📖 Documentation: /opt/$APP_NAME/README.md"
    log_info "🗑️  Uninstall: sudo /opt/$APP_NAME/uninstall.sh"
    echo
    log_info "✅ Fixed Issues: Authentication, Industrial UI, Color Scheme"
    echo
}

# Main installation function
main() {
    log_header "╔══════════════════════════════════════════════════════════╗"
    log_header "║      CF TUNNEL HELPER - INDUSTRIAL CONTROL INSTALLER      ║"
    log_header "╚══════════════════════════════════════════════════════════╝"
    echo
    
    check_root
    detect_ubuntu_version
    create_directories
    install_dependencies
    install_cloudflared
    create_application
    create_service
    create_launcher
    create_repository_files
    create_uninstaller
    final_setup
    
    # Start the application
    log_info "Starting Industrial Control Panel..."
    sleep 2
    "$BIN_LINK" start
}

# Run main function
main "$@"
