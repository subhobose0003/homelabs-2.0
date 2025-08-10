import json
import os
import subprocess
import sys
from datetime import datetime
import tempfile
import shutil

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

import threading

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
        cluster_name = env_config['cluster_name']
        api_server = env_config['api_server']
    except (FileNotFoundError, KeyError) as e:
        error(f"Failed to load or parse configuration: {e}")
        sys.exit(1)

    config_dir = os.path.join(project_root, 'clusters', environment, 'talos-config')
    os.chdir(config_dir)

    node_count = len(nodes_map)
    log(f"Ready to provision up to {node_count} nodes defined in config. Boot any subset now.")
    print()
    print(f"{YELLOW}Enter DHCP IPs of booted nodes one per line. Press [Enter] on an empty line when done.{NC}")
    
    def get_node_details(node_ip, nodes_map):
        def parse_multi_json(stdout: str):
            s = stdout.strip()
            if not s:
                return []
            # Fast path: try array or single object
            try:
                val = json.loads(s)
                return val if isinstance(val, list) else [val]
            except json.JSONDecodeError:
                pass
            # Convert concatenated objects into an array by inserting commas
            try:
                arrayish = '[' + s.replace('}\n{', '},{') + ']'
                return json.loads(arrayish)
            except json.JSONDecodeError:
                # Brace-depth parser fallback
                blocks = []
                buf = ''
                depth = 0
                for ch in s:
                    buf += ch
                    if ch == '{':
                        depth += 1
                    elif ch == '}':
                        depth -= 1
                        if depth == 0:
                            blocks.append(buf)
                            buf = ''
                out = []
                for b in blocks:
                    try:
                        out.append(json.loads(b))
                    except json.JSONDecodeError:
                        continue
                return out
        try:
            links_cmd = ['talosctl', 'get', 'links', '-e', node_ip, '-n', node_ip, '-i', '-o', 'json']
            links_result = subprocess.run(links_cmd, capture_output=True, text=True)
            if links_result.returncode != 0:
                warning(f"links command failed for {node_ip} (rc={links_result.returncode}): {links_result.stderr.strip()}")
                return None
            if not links_result.stdout.strip():
                warning(f"links returned empty output for {node_ip}")
                return None

            links = parse_multi_json(links_result.stdout)
            for link in links:
                spec = link.get('spec', {})
                mac_addr = spec.get('hardwareAddr', '').upper()
                meta = link.get('metadata', {})
                iface_name = spec.get('name') or spec.get('linkName') or meta.get('id')
                if mac_addr in nodes_map and iface_name:
                    hostname = nodes_map[mac_addr]['hostname']
                    log(f"Discovered known node: {hostname} ({mac_addr}) at IP {node_ip}")
                    return {
                        'address': node_ip,
                        'hardwareAddr': mac_addr,
                        'interfaces': [{'name': iface_name}],
                        'config': nodes_map[mac_addr]
                    }
                elif iface_name and mac_addr:
                    warning(f"Found node at {node_ip} with MAC {mac_addr} on interface {iface_name}, but it's not in config.json.")
        except (json.JSONDecodeError, FileNotFoundError):
            return None
        return None

    discovered_nodes = {}
    while True:
        ip = input("Node DHCP IP (or blank to finish): ").strip()
        if not ip:
            break
        # Skip already processed IPs
        if any(n.get('address') == ip for n in discovered_nodes.values()):
            warning(f"IP {ip} already processed; skipping")
            continue
        details = get_node_details(ip, nodes_map)
        if details:
            discovered_nodes[details['hardwareAddr']] = details
        else:
            warning(f"Could not map node at {ip}. Ensure it is booted in Talos maintenance mode.")

    final_discovered_nodes = [node for node in discovered_nodes.values() if not node.get('unknown')]

    if not final_discovered_nodes:
        error("No known nodes were discovered. Please check VM status and network.")
        sys.exit(1)

    # Display summary and ask for confirmation
    log("--- Discovered Nodes Summary ---")
    print(f"{YELLOW}{'MAC Address':<20}{'DHCP IP':<18}{'Hostname':<25}{'Static IP':<18}{NC}")
    print(f"{'='*20}{'='*18}{'='*25}{'='*18}")
    for node in final_discovered_nodes:
        print(f"{node.get('hardwareAddr', '').upper():<20}{node.get('address'):<18}{node['config']['hostname']:<25}{node['config']['ip_address']:<18}")
    
    try:
        input(f"\n{GREEN}Found {len(final_discovered_nodes)}/{node_count} nodes. Press [Enter] to apply configuration or Ctrl+C to abort...{NC}")
    except KeyboardInterrupt:
        warning("\nUser aborted. No changes have been made.")
        sys.exit(0)

    # Apply configuration to all confirmed nodes
    successful_nodes = []
    for node in final_discovered_nodes:
        try:
            node_ip = node.get('address')
            mac_addr = node.get('hardwareAddr', '').upper()
            interface = node.get('interfaces', [{}])[0].get('name')
            node_info = node['config']
            hostname = node_info['hostname']
            static_ip = node_info['ip_address']
            node_type = node_info['type']
            base_config = 'controlplane.yaml' if node_type == 'control-plane' else 'worker.yaml'
            generated_config = f"{hostname}.yaml"

            log(f"Configuring {hostname} ({node_ip} -> {static_ip})...")

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

            patch_str = json.dumps(config_patch)
            # Apply base config plus per-node patch directly; no per-node secrets or files
            apply_result = subprocess.run([
                'talosctl', 'apply-config', '--insecure',
                '--nodes', node_ip,
                '--file', base_config,
                '--config-patch', patch_str
            ], capture_output=True, text=True)
            
            if apply_result.returncode == 0:
                success(f"Applied config to {hostname}. Node will reboot with static IP {static_ip}.")
                successful_nodes.append({
                    'hostname': hostname,
                    'ip_address': static_ip,
                    'type': node_type,
                    'mac': mac_addr
                })
            else:
                error(f"Failed to apply config to {hostname}. Error: {apply_result.stderr}")

        except (KeyError, IndexError) as e:
            error(f"Failed to process node data for MAC {mac_addr}: {e}")

    # Persist successfully provisioned nodes for dynamic join phase
    try:
        provisioned_path = os.path.join(config_dir, 'provisioned_nodes.json')
        with open(provisioned_path, 'w') as f:
            json.dump({'nodes': successful_nodes}, f, indent=2)
        log(f"Wrote provisioned node list to {provisioned_path}")
    except Exception as e:
        warning(f"Could not write provisioned_nodes.json: {e}")

    success("Configuration process complete for all discovered nodes.")

if __name__ == "__main__":
    main()
