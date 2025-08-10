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
    except (FileNotFoundError, KeyError) as e:
        error(f"Failed to load or parse configuration: {e}")
        sys.exit(1)

    config_dir = os.path.join(project_root, 'clusters', environment, 'talos-config')
    os.chdir(config_dir)

    node_count = len(nodes_map)
    log(f"Ready to provision {node_count} nodes. Boot your VMs now.")
    
    initial_ip = input(f"{YELLOW}Please enter the DHCP IP of any booted node to start discovery: {NC}").strip()
    if not initial_ip:
        error("Initial IP address is required.")
        sys.exit(1)

    log(f"Starting discovery using initial node {initial_ip}...")
    log(f"{YELLOW}Press [Enter] when all desired nodes have been discovered.{NC}")

    discovered_nodes = {}
    stop_discovery = threading.Event()

    def discover_and_map_nodes(initial_node_ip, discovered_nodes_dict, nodes_map, stop_event):


        while not stop_event.is_set():
            try:
                # Step 1: Discover affiliates using the initial node as an endpoint
                affiliates_cmd = ['talosctl', 'get', 'affiliates', '-e', initial_node_ip, '-n', initial_node_ip, '-i', '-o', 'json']
                result = subprocess.run(affiliates_cmd, capture_output=True, text=True, check=False)

                if result.returncode != 0 or not result.stdout.strip():
                    time.sleep(5) # Wait and retry if initial node is not ready or output is empty
                    continue

                affiliates = json.loads(result.stdout)

                for affiliate in affiliates:
                    node_ip = affiliate.get('spec', {}).get('addresses', [None])[0]
                    if not node_ip or any(node.get('address') == node_ip for node in discovered_nodes_dict.values()):
                        continue

                    # Step 2: Get MAC address for the affiliate
                    node_details = get_node_details(node_ip, nodes_map)
                    if node_details and node_details['hardwareAddr'] not in discovered_nodes_dict:
                        discovered_nodes_dict[node_details['hardwareAddr']] = node_details

            except (json.JSONDecodeError, FileNotFoundError):
                pass # Suppress errors
            
            stop_event.wait(5) # Poll every 5 seconds

    import time
    # Process the initial node first, then start discovery for others.
    # This is done in the main thread before starting the discovery loop.
    def get_node_details(node_ip, nodes_map):
        try:
            links_cmd = ['talosctl', 'get', 'links', '-e', node_ip, '-n', node_ip, '-i', '-o', 'json']
            links_result = subprocess.run(links_cmd, capture_output=True, text=True)
            if links_result.returncode != 0 or not links_result.stdout.strip():
                return None

            links = json.loads(links_result.stdout)
            for link in links:
                mac_addr = link.get('spec', {}).get('hardwareAddr', '').upper()
                if mac_addr in nodes_map:
                    hostname = nodes_map[mac_addr]['hostname']
                    log(f"Discovered known node: {hostname} ({mac_addr}) at IP {node_ip}")
                    return {
                        'address': node_ip,
                        'hardwareAddr': mac_addr,
                        'interfaces': [{'name': link.get('spec', {}).get('linkName')}],
                        'config': nodes_map[mac_addr]
                    }
        except (json.JSONDecodeError, FileNotFoundError):
            return None
        return None

    initial_node_details = get_node_details(initial_ip, nodes_map)
    if initial_node_details:
        discovered_nodes[initial_node_details['hardwareAddr']] = initial_node_details

    discovery_thread = threading.Thread(target=discover_and_map_nodes, args=(initial_ip, discovered_nodes, nodes_map, stop_discovery))
    discovery_thread.daemon = True
    discovery_thread.start()

    # Wait for user to press Enter
    input()

    log("Stopping discovery...")
    stop_discovery.set()
    discovery_thread.join()

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
            subprocess.run(['talosctl', 'gen', 'patch', generated_config, base_config, '--patch', patch_str], check=True, capture_output=True)
            
            apply_result = subprocess.run(['talosctl', 'apply-config', '--insecure', '--nodes', node_ip, '--file', generated_config], capture_output=True, text=True)
            
            if apply_result.returncode == 0:
                success(f"Applied config to {hostname}. Node will reboot with static IP {static_ip}.")
                os.remove(generated_config)
            else:
                error(f"Failed to apply config to {hostname}. Error: {apply_result.stderr}")

        except (KeyError, IndexError) as e:
            error(f"Failed to process node data for MAC {mac_addr}: {e}")

    success("Configuration process complete for all discovered nodes.")

if __name__ == "__main__":
    main()
