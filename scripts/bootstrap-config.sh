#!/bin/bash

# -----------------------------------------------------------------------------
# Bootstrap Script Configuration
# -----------------------------------------------------------------------------
# This file contains all the user-configurable variables for the Talos
# cluster bootstrap script.
# -----------------------------------------------------------------------------

# --- Global Network Configuration ---
# These settings are applied to all nodes in all environments unless overridden.

# The IP address of your network's default gateway.
GATEWAY_IP="192.168.0.1"

# A list of DNS servers for the nodes to use.
DNS_SERVERS=("192.168.0.5" "8.8.8.8")

# A list of NTP (time) servers for time synchronization.
NTP_SERVERS=("time.cloudflare.com" "pool.ntp.org")

# The subnet mask in CIDR notation (e.g., 24 for 255.255.255.0).
IP_CIDR="24"


# --- Environment-Specific Configuration ---
# Define your cluster settings for each environment (e.g., non-prod, prod).

if [[ "$ENVIRONMENT" == "non-prod" ]]; then
    # --- Non-Production Environment ---

    CLUSTER_NAME="homelab-nonprod"
    API_SERVER="https://non-prod-api.local.homelabs.in:6443"
    
    # The static IP of the first control plane node, used for bootstrapping.
    CONTROL_PLANE_IP="192.168.0.50"

    # Node Mapping: Link MAC addresses to hostnames and static IPs.
    # Format: ["<MAC_ADDRESS>"]="<hostname>;<ip_address>"
    declare -A CONTROL_PLANE_MAP
    CONTROL_PLANE_MAP["BC:24:11:B3:E3:BB"]="non-prod-controller1;192.168.0.50"
    CONTROL_PLANE_MAP["BC:24:11:B4:EC:89"]="non-prod-controller2;192.168.0.51"
    CONTROL_PLANE_MAP["BC:24:11:64:46:F5"]="non-prod-controller3;192.168.0.52"

    declare -A WORKER_MAP
    WORKER_MAP["BC:24:11:B5:5C:0E"]="non-prod-worker1;192.168.0.53"
    WORKER_MAP["BC:24:11:4C:E5:FA"]="non-prod-worker2;192.168.0.54"
    WORKER_MAP["BC:24:11:25:59:0E"]="non-prod-worker3;192.168.0.55"

elif [[ "$ENVIRONMENT" == "prod" ]]; then
    # --- Production Environment ---

    echo "Production environment configuration is not yet defined."
    exit 1

    # CLUSTER_NAME="homelab-prod"
    # API_SERVER="https://prod-api.local.homelabs.in:6443"
    # CONTROL_PLANE_IP="<prod_cp1_ip>"
    #
    # declare -A CONTROL_PLANE_MAP
    # CONTROL_PLANE_MAP["<prod_cp1_mac>"]="prod-controller1;<prod_cp1_ip>"
    # # ...
    # declare -A WORKER_MAP
    # WORKER_MAP["<prod_worker1_mac>"]="prod-worker1;<prod_worker1_ip>"
    # # ...
    # declare -A CONTROL_PLANE_MAP=(
    #     ["<prod_cp1_mac>"]="prod-controller1;<prod_cp1_ip>"
    #     # ...
    # )
    # declare -A WORKER_MAP=(
    #     ["<prod_worker1_mac>"]="prod-worker1;<prod_worker1_ip>"
    #     # ...
    # )
fi
