# Common configuration for Kubernetes deployment scripts
# This file can be sourced by all scripts to ensure consistent configuration

# --- Kubernetes Configuration ---
K8S_VERSION="1.29.0"
POD_NETWORK_CIDR="10.244.0.0/16"  # Aligned between install.sh and switch.sh (Calico default)

# --- CNI Configuration ---
CALICO_VERSION="v3.27.2"

# --- Dashboard Configuration ---
DASHBOARD_VERSION="v2.7.0"
INSTALL_DASHBOARD="true"
DASHBOARD_SERVICE_TYPE="NodePort" # NodePort or ClusterIP

# --- Application Configuration ---
INSTALL_CADDY="true"
CADDY_NAMESPACE="example-caddy"

# --- Storage Configuration ---
HOST_DATA_BASE_DIR="/srv/k8s-apps-data"

# --- User Configuration ---
# These values can be overridden by environment variables
DEFAULT_PUID="${PUID:-1000}"
DEFAULT_PGID="${PGID:-1000}"

# --- Security Configuration ---
# Dashboard token duration (in seconds)
DASHBOARD_TOKEN_DURATION="3600"  # 1 hour
# Secure token storage location
DASHBOARD_TOKEN_FILE="/root/dashboard-token.txt"

# --- Timeouts (in seconds) ---
DEPLOYMENT_WAIT_TIMEOUT="300"
CALICO_WAIT_TIMEOUT="600"
DASHBOARD_WAIT_TIMEOUT="360"
