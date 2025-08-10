import json
import os
import subprocess
import sys
from datetime import datetime

# --- Constants ---
RED = '\033[0;31m'
GREEN = '\033[0;32m'
YELLOW = '\033[1;33m'
BLUE = '\033[0;34m'
NC = '\033[0m'  # No Color

# --- Helper Functions ---
def log(message):
    print(f"{BLUE}[{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] {message}{NC}")

def success(message):
    print(f"{GREEN}[{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] ✓ {message}{NC}")

def warning(message):
    print(f"{YELLOW}[{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] ⚠ {message}{NC}")

def error(message):
    print(f"{RED}[{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] ✗ {message}{NC}")

def main():
    if len(sys.argv) < 2:
        error("Usage: python provision.py [non-prod|prod]")
        sys.exit(1)

    environment = sys.argv[1]
    script_dir = os.path.dirname(os.path.realpath(__file__))
    config_path = os.path.join(script_dir, 'config.json')
    project_root = os.path.dirname(script_dir)

    # Load configuration
    try:
        with open(config_path, 'r') as f:
            config = json.load(f)
        env_config = config['environments'][environment]
        nodes_map = env_config['nodes']
        net_config = env_config['network']
    except (FileNotFoundError, KeyError) as e:
        error(f"Failed to load or parse configuration: {e}")
        sys.exit(1)

    config_dir = os.path.join(project_root, 'clusters', environment, 'talos-config')
    os.chdir(config_dir)

    node_count = len(nodes_map)
    provisioned_count = 0
    log(f"Ready to provision {node_count} nodes. Boot your VMs now.")
    log("Starting node discovery...")

    # Start discovery process
    process = subprocess.Popen(['talosctl', 'discover', '--nodes', '127.0.0.1:50000'],
                               stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE,
                               text=True)

    while True:
        line = process.stdout.readline()
        if not line:
            break

        try:
            node_data = json.loads(line)
            node_ip = node_data.get('address')
            mac_addr = node_data.get('hardwareAddr', '').upper()
            interface = node_data.get('interfaces', [{}])[0].get('name')

            log(f"Discovered node at {node_ip} with MAC {mac_addr} on interface {interface}")

            if mac_addr not in nodes_map:
                error(f"Discovered node with unknown MAC {mac_addr}. Skipping.")
                continue

            node_info = nodes_map[mac_addr]
            hostname = node_info['hostname']
            static_ip = node_info['ip_address']
            node_type = node_info['type']
            base_config = 'controlplane.yaml' if node_type == 'control-plane' else 'worker.yaml'
            
            log(f"Identified as {node_type.replace('-', ' ').title()} node: {hostname} ({static_ip})")
            generated_config = f"{hostname}.yaml"

            # Create configuration patch
            config_patch = [
                {'op': 'add', 'path': '/machine/network/hostname', 'value': hostname},
                {'op': 'add', 'path': '/machine/network/interfaces', 'value': [
                    {
                        'interface': interface,
                        'dhcp': False,
                        'addresses': [f"{static_ip}/{net_config['ip_cidr']}"],
                        'routes': [{'network': '0.0.0.0/0', 'gateway': net_config['gateway_ip']}]
                    }
                ]},
                {'op': 'add', 'path': '/machine/network/nameservers', 'value': net_config['dns_servers']},
                {'op': 'add', 'path': '/machine/time/servers', 'value': net_config['ntp_servers']},
                {'op': 'add', 'path': '/machine/install/diskSelector', 'value': {'size': '< 50GB'}}
            ]

            # Generate and apply config
            patch_str = json.dumps(config_patch)
            subprocess.run(['talosctl', 'gen', 'patch', generated_config, base_config, '--patch', patch_str], check=True, capture_output=True)
            success(f"Generated patched config: {generated_config}")

            log(f"Applying configuration to {hostname} ({node_ip})...")
            apply_result = subprocess.run(['talosctl', 'apply-config', '--insecure', '--nodes', node_ip, '--file', generated_config], capture_output=True, text=True)
            
            if apply_result.returncode == 0:
                success(f"Applied config to {hostname}. Node will reboot with static IP {static_ip}.")
                os.remove(generated_config)
                provisioned_count += 1
                if provisioned_count == node_count:
                    success(f"All {node_count} nodes have been provisioned.")
                    break
            else:
                error(f"Failed to apply config to {hostname} ({node_ip}). Error: {apply_result.stderr}")

        except (json.JSONDecodeError, KeyError) as e:
            error(f"Failed to parse discovery data or node config: {e}. Line: {line.strip()}")

    process.stdout.close()
    process.wait()

if __name__ == "__main__":
    main()
