#!/bin/bash

# Enable strict error handling
set -euo pipefail

# --- Script Configuration ---
# Source common configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/config.sh" ]; then
    source "$SCRIPT_DIR/config.sh"
else
    # Fallback values if config.sh is not found
    K8S_VERSION="1.29.0"
    CALICO_VERSION="v3.27.2"
    DASHBOARD_VERSION="v2.7.0"
    INSTALL_DASHBOARD="true"
    INSTALL_CADDY="true"
    CADDY_NAMESPACE="example-caddy"
    DASHBOARD_SERVICE_TYPE="NodePort"
    DASHBOARD_TOKEN_DURATION="3600"
    DASHBOARD_TOKEN_FILE="/root/dashboard-token.txt"
    CALICO_WAIT_TIMEOUT="600"
    DASHBOARD_WAIT_TIMEOUT="360"
fi

# --- Terminal Colors ---
RESET='\033[0m'
BOLD='\033[1m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'

# --- Script Timer ---
SCRIPT_START_TIME=$(date +%s) # Record start time

# --- State Variables ---
CLUSTER_ACTION="init"
export KUBECONFIG="/etc/kubernetes/admin.conf" # Default Kubeconfig location

# --- Helper Functions ---
log_step() { echo -e "\n${MAGENTA}${BOLD}--------------------------------------------------${RESET}"; echo -e "${MAGENTA}${BOLD}STEP: $1${RESET}"; echo -e "${MAGENTA}${BOLD}--------------------------------------------------${RESET}"; }
log_warn() { echo -e "${YELLOW}${BOLD}⚠️ WARNING:${RESET}${YELLOW} $1${RESET}"; }
log_info() { echo -e "${CYAN}ℹ️ INFO:${RESET} $1"; }
error_exit() { echo -e "\n${RED}${BOLD}❌ ERROR:${RESET}${RED} $1${RESET}\n" >&2; exit 1; }
success_msg() { echo -e "${GREEN}✅ SUCCESS:${RESET} $1"; }

check_root() { if [ "$(id -u)" -ne 0 ]; then error_exit "This script must be run as root. Please use sudo."; fi; }
# Function to check if a command exists
check_command() { if ! command -v "$1" &> /dev/null; then error_exit "Required command '${BOLD}$1${RESET}${RED}' not found. Please install it."; fi; }
# Function to check file content (using grep -qF for fixed strings is slightly faster)
check_file_content() { local file="$1"; local pattern="$2"; [ -f "$file" ] && grep -qF -- "$pattern" "$file"; }
is_module_loaded() { lsmod | grep -q "^$1\s"; }
# Basic version format check (allows vX.Y.Z or X.Y.Z patterns)
check_version_format() {
  local version="$1"
  local name="$2"
  if ! [[ "$version" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+([-.].*)?$ ]]; then
    error_exit "Invalid format for ${name} version: '${version}'. Expected format like X.Y.Z or vX.Y.Z."
  fi
}

# --- Initial Checks ---
check_root
check_command curl
check_command gpg
check_command sed
check_command awk
check_command grep
check_command date
check_command id
check_command tee
check_command modprobe
check_command sysctl
check_command systemctl
check_command dpkg-query
check_command apt-get
check_command apt-mark
check_command hostname
check_command jq
# Check K8s tools existence, but allow script to proceed for installation steps
command -v kubectl &> /dev/null || log_warn "kubectl not found initially. Will be installed."
command -v kubeadm &> /dev/null || log_warn "kubeadm not found initially. Will be installed."
command -v kubelet &> /dev/null || log_warn "kubelet not found initially. Will be installed."

# Check configured version formats
check_version_format "$K8S_VERSION" "Kubernetes (K8S_VERSION)"
check_version_format "$CALICO_VERSION" "Calico (CALICO_VERSION)"
check_version_format "$DASHBOARD_VERSION" "Dashboard (DASHBOARD_VERSION)"

# --- Script Start ---
echo -e "${BLUE}${BOLD}##################################################${RESET}"
echo -e "${BLUE}${BOLD}# Starting Kubernetes Single-Node Setup          #${RESET}"
# ... (rest of header) ...
echo -e "${BLUE}${BOLD}# Install Caddy: ${INSTALL_CADDY}                    #${RESET}"
echo -e "${BLUE}${BOLD}##################################################${RESET}"
echo
log_warn "This script will modify system settings (network, packages, services)."
log_warn "Review the script ${BOLD}thoroughly${RESET}${YELLOW} before proceeding."
echo

# --- Pre-flight Check: Detect Existing Kubernetes ---
log_step "Checking for existing Kubernetes installations"
K8S_CONFIG_DIR="/etc/kubernetes"
K8S_MANIFESTS_DIR="${K8S_CONFIG_DIR}/manifests"
PERFORM_RESET="false"

if [ -f "$KUBECONFIG" ] || [ -d "$K8S_MANIFESTS_DIR" ]; then
    log_warn "EXISTING KUBERNETES CONFIGURATION DETECTED!"
    log_warn "Found indicators like ${CYAN}${KUBECONFIG}${RESET}${YELLOW} or ${CYAN}${K8S_MANIFESTS_DIR}${RESET}"
    echo
    echo -e "${BOLD}Choose an action:${RESET}"
    echo -e "  [${CYAN}d${RESET}] ${BOLD}Destroy${RESET}: Attempt 'kubeadm reset' to remove the existing cluster config on this node and proceed with fresh initialization. ${RED}${BOLD}THIS IS DESTRUCTIVE.${RESET}"
    echo -e "  [${CYAN}m${RESET}] ${BOLD}Modify${RESET}: Skip cluster initialization ('kubeadm init') and attempt to apply other configurations (CNI, Dashboard, etc.) to the existing setup. Use with caution."
    echo -e "  [${CYAN}e${RESET}] ${BOLD}Exit${RESET}: Stop the script now to avoid making changes."
    echo

    while true; do
        read -p "$(echo -e "${CYAN}Enter your choice (d/m/e) [e]: ${RESET}")" choice
        choice=${choice:-e}
        choice=$(echo "$choice" | tr '[:upper:]' '[:lower:]')
        case "$choice" in
            d) log_warn "You chose to DESTROY the existing cluster configuration."
               read -p "$(echo -e "${RED}${BOLD}ARE YOU ABSOLUTELY SURE?${RESET}${RED} Type '${BOLD}yes${RESET}${RED}' to confirm: ${RESET}")" confirm
               if [[ "$confirm" == "yes" ]]; then log_info "Proceeding with kubeadm reset..."; CLUSTER_ACTION="reset_and_init"; PERFORM_RESET="true"; break;
               else log_info "Reset cancelled."; fi ;;
            m) log_info "Proceeding in MODIFY mode. 'kubeadm init' will be skipped."; CLUSTER_ACTION="modify"; break ;;
            e) log_info "Exiting script as requested."; exit 0 ;;
            *) log_warn "Invalid choice. Please enter 'd', 'm', or 'e'." ;;
        esac
    done
else
    log_info "No definitive existing Kubernetes cluster config found at $KUBECONFIG. Proceeding with initial setup."
    CLUSTER_ACTION="init"
fi

echo
log_warn "Continuing script execution based on your choice."
log_warn "Action: ${BOLD}${CLUSTER_ACTION}${RESET}"
read -p "$(echo -e "${CYAN}Press Enter to continue or Ctrl+C to abort...${RESET}")"

# --- Perform Reset if requested ---
if [ "$PERFORM_RESET" = "true" ]; then
    log_step "Performing kubeadm reset (as requested)"
    check_command kubeadm
    kubeadm reset --force > /dev/null 2>&1 || log_warn "'kubeadm reset' encountered errors, but proceeding anyway."
    rm -rf /root/.kube "$KUBECONFIG" "$K8S_MANIFESTS_DIR" /var/lib/etcd /var/lib/cni/ /var/lib/kubelet/*
    systemctl stop kubelet &>/dev/null || true
    systemctl stop containerd &>/dev/null || true
    log_info "kubeadm reset executed. Residual files potentially cleaned."
    if [ -f "$KUBECONFIG" ]; then error_exit "Failed to remove ${KUBECONFIG} even after kubeadm reset. Aborting."; fi
    log_info "Restarting containerd after reset..."
    systemctl start containerd
    sleep 3 # Give containerd a moment after reset/restart
fi

# --- 1. System Preparation ---
log_step "Updating package index and installing prerequisites"
apt-get update > /dev/null
apt-get install -y apt-transport-https ca-certificates curl gnupg software-properties-common conntrack socat jq > /dev/null
success_msg "Prerequisites installed."

log_step "Disabling Swap"
if ! swapon --show | grep -q '.'; then log_info "Swap is already disabled."; else
  swapoff -a; sed -i.bak -E 's|^([^#].*\sswap\s+sw\s+.*)$|#\1|' /etc/fstab
  log_info "Swap disabled. Original fstab backed up to /etc/fstab.bak"
fi

log_step "Configuring Kernel parameters"
K8S_MODULE_CONF="/etc/modules-load.d/k8s.conf"; [ ! -f "$K8S_MODULE_CONF" ] && touch "$K8S_MODULE_CONF"
MOD_CHANGED=0
if ! check_file_content "$K8S_MODULE_CONF" "overlay"; then echo "overlay" >> "$K8S_MODULE_CONF"; log_info "Set 'overlay' module to load."; MOD_CHANGED=1; fi
if ! check_file_content "$K8S_MODULE_CONF" "br_netfilter"; then echo "br_netfilter" >> "$K8S_MODULE_CONF"; log_info "Set 'br_netfilter' module to load."; MOD_CHANGED=1; fi
if ! is_module_loaded "overlay"; then modprobe overlay; log_info "Loaded 'overlay' module now."; fi
if ! is_module_loaded "br_netfilter"; then modprobe br_netfilter; log_info "Loaded 'br_netfilter' module now."; fi
if [ $MOD_CHANGED -eq 0 ] && is_module_loaded "overlay" && is_module_loaded "br_netfilter"; then log_info "Kernel modules already configured/loaded."; fi

K8S_SYSCTL_CONF="/etc/sysctl.d/k8s.conf"; [ ! -f "$K8S_SYSCTL_CONF" ] && touch "$K8S_SYSCTL_CONF"
SYSCTL_CHANGED=0
if ! check_file_content "$K8S_SYSCTL_CONF" "net.bridge.bridge-nf-call-iptables = 1"; then echo "net.bridge.bridge-nf-call-iptables = 1" >> "$K8S_SYSCTL_CONF"; log_info "Set bridge-nf-call-iptables=1"; SYSCTL_CHANGED=1; fi
if ! check_file_content "$K8S_SYSCTL_CONF" "net.bridge.bridge-nf-call-ip6tables = 1"; then echo "net.bridge.bridge-nf-call-ip6tables = 1" >> "$K8S_SYSCTL_CONF"; log_info "Set bridge-nf-call-ip6tables=1"; SYSCTL_CHANGED=1; fi
if ! check_file_content "$K8S_SYSCTL_CONF" "net.ipv4.ip_forward = 1"; then echo "net.ipv4.ip_forward = 1" >> "$K8S_SYSCTL_CONF"; log_info "Set ip_forward=1"; SYSCTL_CHANGED=1; fi
if [ $SYSCTL_CHANGED -eq 1 ]; then log_info "Applying sysctl parameters..."; sysctl --system > /dev/null; else log_info "Sysctl parameters already configured."; fi
success_msg "Kernel parameters configured."

# --- 2. Install Container Runtime (containerd) ---
log_step "Setting up Containerd repository"
CONTAINERD_VERSION="1.7"
DOCKER_KEYRING="/etc/apt/keyrings/docker.gpg"; DOCKER_SOURCES_LIST="/etc/apt/sources.list.d/docker.list"
OS_CODENAME=$(. /etc/os-release && echo "$VERSION_CODENAME")
DOCKER_REPO_LINE="deb [arch=$(dpkg --print-architecture) signed-by=${DOCKER_KEYRING}] https://download.docker.com/linux/ubuntu ${OS_CODENAME} stable"
install -m 0755 -d /etc/apt/keyrings &> /dev/null
REPO_UPDATED=0
if [ ! -f "$DOCKER_KEYRING" ]; then log_info "Adding Docker GPG key."; curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o "$DOCKER_KEYRING"; chmod a+r "$DOCKER_KEYRING"; else log_info "Docker GPG key already exists."; fi
if ! check_file_content "$DOCKER_SOURCES_LIST" "https://download.docker.com/linux/ubuntu"; then log_info "Adding Docker repository."; echo "$DOCKER_REPO_LINE" | tee "$DOCKER_SOURCES_LIST" > /dev/null; apt-get update > /dev/null; REPO_UPDATED=1; else log_info "Docker repository already configured."; fi

log_step "Installing containerd.io"
if dpkg -s containerd.io &> /dev/null; then log_info "containerd.io package is already installed."; else
  log_info "Installing containerd.io..."; apt-get install -y "containerd.io${CONTAINERD_VERSION:+=$CONTAINERD_VERSION.*}" > /dev/null;
  success_msg "containerd.io installed.";
fi

log_step "Configuring containerd"
CONTAINERD_CONFIG_FILE="/etc/containerd/config.toml"; RESTART_CONTAINERD="false"
if [ ! -f "$CONTAINERD_CONFIG_FILE" ]; then
    log_info "Generating default containerd configuration."; install -d "$(dirname "$CONTAINERD_CONFIG_FILE")" &> /dev/null; containerd config default | tee "$CONTAINERD_CONFIG_FILE" >/dev/null
    if grep -q 'SystemdCgroup = false' "$CONTAINERD_CONFIG_FILE"; then sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' "$CONTAINERD_CONFIG_FILE"; log_info "Set SystemdCgroup = true in new config."; RESTART_CONTAINERD="true";
    elif ! grep -q 'SystemdCgroup = true' "$CONTAINERD_CONFIG_FILE"; then log_warn "SystemdCgroup setting not found in default config. Verify manually."; else log_info "SystemdCgroup already true in generated config."; fi
else
    log_warn "Existing containerd config found: ${CYAN}${CONTAINERD_CONFIG_FILE}${RESET}";
    if ! grep -q 'SystemdCgroup = true' "$CONTAINERD_CONFIG_FILE"; then
        if grep -q 'SystemdCgroup = false' "$CONTAINERD_CONFIG_FILE"; then sed -i.bak 's/SystemdCgroup = false/SystemdCgroup = true/' "$CONTAINERD_CONFIG_FILE"; log_info "Set SystemdCgroup = true in existing config (backed up)."; RESTART_CONTAINERD="true";
        else log_warn "Could not reliably find/modify SystemdCgroup. Ensure ${BOLD}'SystemdCgroup = true'${RESET}${YELLOW} is set."; fi
    else log_info "SystemdCgroup already set to true."; fi
fi
if [ "$RESTART_CONTAINERD" = "true" ]; then log_info "Restarting containerd due to config change."; systemctl restart containerd; sleep 3; fi

log_step "Ensuring containerd service is enabled and active"
if ! systemctl is-enabled --quiet containerd; then systemctl enable containerd > /dev/null; log_info "containerd service enabled."; fi
if ! systemctl is-active --quiet containerd; then log_info "Starting containerd service..."; systemctl restart containerd; sleep 5; systemctl is-active --quiet containerd || error_exit "containerd failed to start."; success_msg "containerd service active."; else log_info "containerd service already active."; fi

# Check for containerd socket before proceeding to K8s install
CONTAINERD_SOCK="/run/containerd/containerd.sock"
if [ ! -S "$CONTAINERD_SOCK" ]; then
  error_exit "Containerd socket ($CONTAINERD_SOCK) not found or not active. Cannot proceed with Kubernetes installation."
fi
log_info "Containerd socket found at $CONTAINERD_SOCK"

# --- 3. Install Kubernetes Components (kubeadm, kubelet, kubectl) ---
log_step "Setting up Kubernetes apt repository"
K8S_KEYRING="/etc/apt/keyrings/kubernetes-apt-keyring.gpg"; K8S_SOURCES_LIST="/etc/apt/sources.list.d/kubernetes.list"
K8S_MAJOR_MINOR=$(echo "$K8S_VERSION" | cut -d. -f1-2)
K8S_REPO_LINE="deb [signed-by=${K8S_KEYRING}] https://pkgs.k8s.io/core:/stable:/v${K8S_MAJOR_MINOR}/deb/ /"
log_info "Using Kubernetes ${BOLD}v${K8S_MAJOR_MINOR}${RESET} repository"
install -m 0755 -d "$(dirname "$K8S_KEYRING")" &> /dev/null
if [ ! -f "$K8S_KEYRING" ]; then log_info "Adding K8s GPG key."; curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_MAJOR_MINOR}/deb/Release.key" | gpg --dearmor -o "$K8S_KEYRING"; else log_info "K8s GPG key already exists."; fi
if ! check_file_content "$K8S_SOURCES_LIST" "https://pkgs.k8s.io/core:/stable:/v${K8S_MAJOR_MINOR}/deb/"; then log_info "Adding K8s repository."; echo "$K8S_REPO_LINE" | tee "$K8S_SOURCES_LIST" > /dev/null; if [ $REPO_UPDATED -eq 0 ]; then apt-get update > /dev/null; fi; else log_info "K8s repository already configured."; fi

log_step "Installing kubelet, kubeadm, and kubectl (${BOLD}${K8S_VERSION}${RESET})"
KUBELET_INSTALLED=$(dpkg-query -W -f='${Status} ${Version}\n' kubelet 2>/dev/null | grep "^install ok installed ${K8S_VERSION}-" || true)
KUBEADM_INSTALLED=$(dpkg-query -W -f='${Status} ${Version}\n' kubeadm 2>/dev/null | grep "^install ok installed ${K8S_VERSION}-" || true)
KUBECTL_INSTALLED=$(dpkg-query -W -f='${Status} ${Version}\n' kubectl 2>/dev/null | grep "^install ok installed ${K8S_VERSION}-" || true)
if [ -n "$KUBELET_INSTALLED" ] && [ -n "$KUBEADM_INSTALLED" ] && [ -n "$KUBECTL_INSTALLED" ]; then log_info "Correct K8s component versions already installed."; else
    log_info "Installing/Updating K8s components to ${BOLD}${K8S_VERSION}${RESET}..."; apt-mark unhold kubelet kubeadm kubectl containerd.io &>/dev/null || true
    apt-get install -y kubelet=${K8S_VERSION}-* kubeadm=${K8S_VERSION}-* kubectl=${K8S_VERSION}-* > /dev/null;
    success_msg "K8s components installed/updated."
fi
log_info "Holding K8s components and containerd.io versions."; apt-mark hold kubelet kubeadm kubectl containerd.io &> /dev/null

log_step "Ensuring Kubelet service is enabled"
if ! systemctl is-enabled --quiet kubelet; then systemctl enable kubelet > /dev/null; log_info "Kubelet service enabled."; else log_info "Kubelet service already enabled."; fi
if [ "$CLUSTER_ACTION" != "modify" ] && systemctl is-active --quiet kubelet; then log_warn "Kubelet is active before init/reset. Stopping it."; systemctl stop kubelet; fi

# --- 4. Initialize or Identify Kubernetes Cluster ---
if [ "$CLUSTER_ACTION" = "init" ] || [ "$CLUSTER_ACTION" = "reset_and_init" ]; then
    log_step "Initializing Kubernetes cluster with kubeadm"
    if [ -f "$KUBECONFIG" ]; then error_exit "Found ${KUBECONFIG} unexpectedly before kubeadm init. Aborting."; fi
    log_info "Running kubeadm init (this may take a few minutes)..."
    check_command kubeadm
    kubeadm init --pod-network-cidr=${POD_NETWORK_CIDR} --kubernetes-version="${K8S_VERSION}" > kubeadm-init.log 2>&1 &
    KUBEADM_PID=$!
    spin='-\|/'; i=0
    while kill -0 $KUBEADM_PID 2>/dev/null; do i=$(( (i+1) %4 )); printf "\r${CYAN}Initializing... ${spin:$i:1}${RESET}"; sleep .1; done
    printf "\r${CYAN}Initializing... Done.${RESET}     \n"; wait $KUBEADM_PID; KUBEADM_EXIT_CODE=$?
    if [ $KUBEADM_EXIT_CODE -ne 0 ]; then error_exit "kubeadm init failed. Check ${BOLD}kubeadm-init.log${RESET}${RED} for details."; fi
    if [ ! -f "$KUBECONFIG" ]; then error_exit "kubeadm init succeeded, but ${KUBECONFIG} not found! Check logs."; fi
    success_msg "kubeadm init completed successfully."; log_info "Full log available in ${BOLD}kubeadm-init.log${RESET}"

    # --- 5. Configure kubectl Access (Only after successful kubeadm init) ---
    log_step "Configuring kubectl access (after init)"
    mkdir -p /root/.kube; cp -f "$KUBECONFIG" /root/.kube/config; chown root:root /root/.kube/config
    export KUBECONFIG # Keep using /etc/kubernetes/admin.conf
    log_info "kubectl configured for root user in ${CYAN}/root/.kube/config${RESET}"
    echo -e "${CYAN}For non-root user access, run the following AS THE NON-ROOT USER:${RESET}" # Use -e here
    echo -e "  ${BOLD}mkdir -p \$HOME/.kube${RESET}" # Use -e here
    echo -e "  ${BOLD}sudo cp -i ${KUBECONFIG} \$HOME/.kube/config${RESET}" # Use -e here
    echo -e "  ${BOLD}sudo chown \$(id -u):\$(id -g) \$HOME/.kube/config${RESET}" # Use -e here

elif [ "$CLUSTER_ACTION" = "modify" ]; then
    log_step "Skipping kubeadm init (Modify Mode)"
    if [ ! -f "$KUBECONFIG" ]; then error_exit "Modify mode selected, but cannot find existing config at ${KUBECONFIG}. Aborting."; fi
    log_info "Using existing Kubernetes configuration: ${CYAN}${KUBECONFIG}${RESET}"
    if ! systemctl is-active --quiet kubelet; then log_info "Starting kubelet service in modify mode..."; systemctl start kubelet; sleep 5; systemctl is-active --quiet kubelet || log_warn "Kubelet failed to start in modify mode."; fi
else
    error_exit "Invalid CLUSTER_ACTION state: ${CLUSTER_ACTION}"
fi

# --- Post-Init/Modify Steps ---
check_command kubectl # Ensure kubectl exists before proceeding

log_step "Verifying cluster node readiness and retrieving node info"
NODE_NAME=""; NODE_IP=""; RETRY_COUNT=0; MAX_RETRIES=6
while [ -z "$NODE_NAME" ] && [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    NODE_NAME=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [ -z "$NODE_NAME" ]; then log_warn "Waiting for node to register... (${RETRY_COUNT}/${MAX_RETRIES})"; sleep 5; RETRY_COUNT=$((RETRY_COUNT + 1)); fi
done
if [ -z "$NODE_NAME" ]; then error_exit "Failed to get node name after ${MAX_RETRIES} attempts."; fi
log_info "Detected Node Name: ${BOLD}${NODE_NAME}${RESET}"
NODE_IP=$(kubectl get node "$NODE_NAME" -o jsonpath="{.status.addresses[?(@.type=='InternalIP')].address}" 2>/dev/null || true)
[ -z "$NODE_IP" ] && NODE_IP=$(kubectl get node "$NODE_NAME" -o jsonpath="{.status.addresses[?(@.type=='ExternalIP')].address}" 2>/dev/null || true)
[ -z "$NODE_IP" ] && NODE_IP=$(hostname -I | awk '{print $1}')
if [ -n "$NODE_IP" ]; then log_info "Detected Node IP: ${BOLD}${NODE_IP}${RESET} (for NodePort access)"; else log_warn "Could not determine Node IP."; fi
log_info "Waiting for node ${BOLD}${NODE_NAME}${RESET} to be Ready..."
kubectl wait --for=condition=Ready node/"$NODE_NAME" --timeout=120s || log_warn "Node ${NODE_NAME} did not become Ready within timeout."
kubectl get nodes -o wide

# --- 6. Install Network Plugin (Calico) ---
log_step "Installing Calico network plugin (${BOLD}${CALICO_VERSION}${RESET})"
CALICO_URL="https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml"
log_info "Applying Calico manifest from ${CYAN}${CALICO_URL}${RESET}"; kubectl apply -f "$CALICO_URL" > /dev/null
log_step "Waiting for Calico pods to be ready..."
log_info "Calico is essential for cluster networking. Waiting up to ${CALICO_WAIT_TIMEOUT} seconds..."

# Check calico-kube-controllers
if ! kubectl wait --for=condition=ready pod -l k8s-app=calico-kube-controllers -n kube-system --timeout="${CALICO_WAIT_TIMEOUT}s"; then
    log_warn "Calico kube-controllers failed to become ready. Checking pod status..."
    kubectl get pods -n kube-system -l k8s-app=calico-kube-controllers
    kubectl describe pods -n kube-system -l k8s-app=calico-kube-controllers
    error_exit "Calico kube-controllers not ready. Cluster will not function properly without CNI."
fi

# Check calico-node
if ! kubectl wait --for=condition=ready pod -l k8s-app=calico-node -n kube-system --timeout="${CALICO_WAIT_TIMEOUT}s"; then
    log_warn "Calico node pods failed to become ready. Checking pod status..."
    kubectl get pods -n kube-system -l k8s-app=calico-node
    kubectl describe pods -n kube-system -l k8s-app=calico-node
    error_exit "Calico node pods not ready. Cluster will not function properly without CNI."
fi

success_msg "Calico networking is ready!"

# --- 7. Untaint Control Plane Node ---
log_step "Allowing scheduling on control-plane node (${BOLD}${NODE_NAME}${RESET})"
if kubectl get node "$NODE_NAME" -o jsonpath='{.spec.taints[?(@.key=="node-role.kubernetes.io/control-plane")].effect}' | grep -q "NoSchedule"; then
    log_info "Removing control-plane:NoSchedule taint..."; kubectl taint nodes "$NODE_NAME" node-role.kubernetes.io/control-plane:NoSchedule- > /dev/null
    success_msg "Node ${NODE_NAME} untainted."
else log_info "Node ${NODE_NAME} does not have the NoSchedule taint or taint already removed."; fi

# --- 8. Install Kubernetes Dashboard (Optional) ---
if [ "$INSTALL_DASHBOARD" = "true" ]; then
  DASHBOARD_NS="kubernetes-dashboard"; DASHBOARD_SVC="kubernetes-dashboard"; DASHBOARD_SA="admin-user"
  log_step "Installing Kubernetes Dashboard (${BOLD}${DASHBOARD_VERSION}${RESET})"
  DASHBOARD_URL="https://raw.githubusercontent.com/kubernetes/dashboard/${DASHBOARD_VERSION}/aio/deploy/recommended.yaml"
  log_info "Applying Dashboard manifest from ${CYAN}${DASHBOARD_URL}${RESET}"; kubectl apply -f "$DASHBOARD_URL" > /dev/null

  if [ "$DASHBOARD_SERVICE_TYPE" = "NodePort" ]; then
    log_info "Patching Dashboard Service (${DASHBOARD_SVC}) to type ${BOLD}NodePort${RESET}"
    PATCH_RETRY=0; MAX_PATCH_RETRY=4; PATCH_SUCCESS="false"
    while [ "$PATCH_SUCCESS" = "false" ] && [ $PATCH_RETRY -lt $MAX_PATCH_RETRY ]; do
        if kubectl patch service "$DASHBOARD_SVC" -n "$DASHBOARD_NS" -p '{"spec": {"type": "NodePort"}}' --request-timeout=10s >/dev/null 2>&1; then PATCH_SUCCESS="true"; break; fi
        if [ $PATCH_RETRY -eq 0 ]; then sleep 2; else sleep 5; fi
        log_warn "Retrying dashboard service patch (${PATCH_RETRY}/${MAX_PATCH_RETRY})..."; PATCH_RETRY=$((PATCH_RETRY + 1))
    done
    if [ "$PATCH_SUCCESS" = "false" ]; then log_warn "Could not patch Dashboard service to NodePort. Defaulting to ClusterIP access."; DASHBOARD_SERVICE_TYPE="ClusterIP";
    else success_msg "Dashboard service patched to NodePort."; fi
  fi

  log_step "Creating Dashboard Admin User (${BOLD}${DASHBOARD_SA}${RESET}) and RBAC with limited permissions"
  cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: ServiceAccount
metadata: { name: ${DASHBOARD_SA}, namespace: ${DASHBOARD_NS} }
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata: { name: dashboard-viewer }
rules:
- apiGroups: [""]
  resources: ["nodes", "namespaces", "pods", "services", "configmaps", "secrets", "persistentvolumes", "persistentvolumeclaims"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["apps"]
  resources: ["deployments", "replicasets", "daemonsets", "statefulsets"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["extensions", "networking.k8s.io"]
  resources: ["ingresses", "networkpolicies"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["storage.k8s.io"]
  resources: ["storageclasses"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["metrics.k8s.io"]
  resources: ["nodes", "pods"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata: { name: ${DASHBOARD_SA} }
roleRef: { apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: dashboard-viewer }
subjects: [ { kind: ServiceAccount, name: ${DASHBOARD_SA}, namespace: ${DASHBOARD_NS} } ]
EOF
  success_msg "Dashboard ServiceAccount and ClusterRoleBinding (view-only) applied."

  log_step "Waiting for Dashboard pods to be ready..."
  kubectl wait --for=condition=ready pod -l k8s-app=kubernetes-dashboard -n "$DASHBOARD_NS" --timeout=${DASHBOARD_WAIT_TIMEOUT}s || log_warn "Timed out waiting for Dashboard pods."
  success_msg "Finished waiting for Dashboard pods."

  # --- Dashboard Access Instructions ---
  echo; log_step "Dashboard Access Information"; echo -e "${BLUE}---${RESET}"
  DASHBOARD_TOKEN=""; DASHBOARD_NODE_PORT=""
  if kubectl get serviceaccount "$DASHBOARD_SA" -n "$DASHBOARD_NS" > /dev/null 2>&1; then
      log_info "Generating temporary access token for ${DASHBOARD_SA}..."
      DASHBOARD_TOKEN=$(kubectl -n "$DASHBOARD_NS" create token "$DASHBOARD_SA" --duration="${DASHBOARD_TOKEN_DURATION}s")
      
      # Save token to secure file
      echo "$DASHBOARD_TOKEN" > "$DASHBOARD_TOKEN_FILE"
      chmod 600 "$DASHBOARD_TOKEN_FILE"
      chown root:root "$DASHBOARD_TOKEN_FILE"
      
      log_info "Dashboard token saved to: ${BOLD}${DASHBOARD_TOKEN_FILE}${RESET}"
      echo -e "${YELLOW}${BOLD}Dashboard Access Token (expires in $((DASHBOARD_TOKEN_DURATION/3600)) hour(s)):${RESET}"
      echo -e "${YELLOW}${BOLD}${DASHBOARD_TOKEN}${RESET}"
      echo -e "${BLUE}---${RESET}"
      log_warn "This token provides read-only dashboard access. Store securely and do not share."
      log_info "Token file permissions set to 600 (root only)."
  else 
      log_warn "Cannot find '${DASHBOARD_SA}' SA in '${DASHBOARD_NS}' ns. Token not generated."
  fi
  echo -e "${BLUE}---${RESET}"
  if [ "$DASHBOARD_SERVICE_TYPE" = "NodePort" ] && [ -n "$NODE_IP" ]; then
      DASHBOARD_NODE_PORT=$(kubectl get service "$DASHBOARD_SVC" -n "$DASHBOARD_NS" -o=jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || echo "")
      if [ -n "$DASHBOARD_NODE_PORT" ]; then
          DASHBOARD_URL="https://${NODE_IP}:${DASHBOARD_NODE_PORT}"
          echo -e "${BOLD}Access Dashboard via NodePort at:${RESET} ${CYAN}${DASHBOARD_URL}${RESET}" # Use -e
          echo -e "(Accept browser warning for self-signed certificate.)" # Use -e
          echo -e "Login using the '${BOLD}Token${RESET}' option." # Use -e
          if command -v ufw &> /dev/null && ufw status | grep -qw active; then
              log_info "UFW firewall is active."
              LOCAL_SUBNET=$(echo "$NODE_IP" | sed 's/\.[0-9]*$/.0\/24/')
              read -p "$(echo -e "${CYAN}Allow access to Dashboard port ${BOLD}${DASHBOARD_NODE_PORT}${RESET}${CYAN} from local network (${LOCAL_SUBNET})? [y/N]: ${RESET}")" allow_fw
              if [[ "$allow_fw" =~ ^[Yy]$ ]]; then log_info "Adding UFW rule..."; ufw allow from "${LOCAL_SUBNET}" to any port "${DASHBOARD_NODE_PORT}" proto tcp comment 'Kubernetes Dashboard Access' > /dev/null; ufw reload > /dev/null; success_msg "UFW rule added.";
              else log_warn "Firewall rule not added."; fi
          else log_warn "Firewall (UFW) not detected or inactive. Ensure port ${DASHBOARD_NODE_PORT} is open on ${NODE_IP}."; fi
      else
          log_warn "Could not retrieve Dashboard NodePort. Falling back to kubectl proxy."
          echo -e "Access via '${BOLD}kubectl proxy${RESET}' and URL: ${CYAN}http://localhost:8001/api/v1/namespaces/${DASHBOARD_NS}/services/https:${DASHBOARD_SVC}:/proxy/${RESET}" # Use -e
      fi
  else
      log_info "Dashboard Service Type is ClusterIP or Node IP unknown."
      echo -e "Access Dashboard via '${BOLD}kubectl proxy${RESET}':" # Use -e
      echo -e "  1. Run '${BOLD}kubectl proxy${RESET}'" # Use -e
      echo -e "  2. Open browser to: ${CYAN}http://localhost:8001/api/v1/namespaces/${DASHBOARD_NS}/services/https:${DASHBOARD_SVC}:/proxy/${RESET}" # Use -e
      echo -e "  3. Login using the '${BOLD}Token${RESET}' option." # Use -e
  fi
  echo -e "${BLUE}---${RESET}"
fi # End Install Dashboard

# --- 9. Install Caddy Example Service (Optional) ---
if [ "$INSTALL_CADDY" = "true" ]; then
  CADDY_DEPLOY="caddy-deployment"; CADDY_SVC="caddy-service"; CADDY_APP_LABEL="caddy"
  log_step "Installing Caddy example service in namespace '${BOLD}${CADDY_NAMESPACE}${RESET}'"
  cat <<EOF | kubectl apply -f - >/dev/null; log_info "Namespace ${CADDY_NAMESPACE} ensured."
apiVersion: v1
kind: Namespace
metadata: { name: ${CADDY_NAMESPACE} }
EOF
  log_step "Applying Caddy Deployment"; cat <<EOF | kubectl apply -n "$CADDY_NAMESPACE" -f - >/dev/null; success_msg "Caddy Deployment applied."
apiVersion: apps/v1
kind: Deployment
metadata: { name: ${CADDY_DEPLOY} }
spec: { replicas: 1, selector: { matchLabels: { app: ${CADDY_APP_LABEL} } }, template: { metadata: { labels: { app: ${CADDY_APP_LABEL} } }, spec: { containers: [ { name: caddy, image: caddy:latest, ports: [ { containerPort: 80, name: http } ] } ] } } }
EOF
  log_step "Applying Caddy Service (NodePort)"; cat <<EOF | kubectl apply -n "$CADDY_NAMESPACE" -f - >/dev/null; success_msg "Caddy Service applied."
apiVersion: v1
kind: Service
metadata: { name: ${CADDY_SVC} }
spec: { selector: { app: ${CADDY_APP_LABEL} }, ports: [ { protocol: TCP, port: 80, targetPort: http } ], type: NodePort }
EOF
  log_step "Waiting for Caddy deployment to be available..."
  kubectl wait --for=condition=available deployment/"$CADDY_DEPLOY" -n "$CADDY_NAMESPACE" --timeout=360s || log_warn "Timed out waiting for Caddy deployment."
  success_msg "Finished waiting for Caddy deployment."
  log_step "Caddy Example Service Instructions"
  CADDY_NODE_PORT=""
  if [ -n "$NODE_IP" ]; then CADDY_NODE_PORT=$(kubectl get svc "$CADDY_SVC" -n "$CADDY_NAMESPACE" -o=jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || echo ""); fi
  if [ -n "$CADDY_NODE_PORT" ]; then
      CADDY_URL="http://${NODE_IP}:${CADDY_NODE_PORT}"
      echo -e "${BOLD}Access Caddy default page via NodePort at:${RESET} ${CYAN}${CADDY_URL}${RESET}" # Use -e
      log_warn "Ensure firewall allows traffic to port ${BOLD}${CADDY_NODE_PORT}${RESET}${YELLOW} on ${NODE_IP}."
  else log_warn "Could not retrieve Caddy NodePort or Node IP unknown."; log_info "Check service: ${BOLD}kubectl get svc ${CADDY_SVC} -n ${CADDY_NAMESPACE}${RESET}"; fi
fi # End Install Caddy

# --- Script End ---
log_step "Kubernetes setup script finished!"
echo -e "${BLUE}--------------------------------------------------${RESET}"
echo -e "${BOLD}Final Cluster Status Check:${RESET}"
if command -v kubectl &> /dev/null && [ -f "$KUBECONFIG" ]; then
    echo -e "${BOLD}Cluster Info:${RESET}"; kubectl cluster-info || log_warn "Could not retrieve cluster info."
    echo -e "\n${BOLD}Node Status:${RESET}"; kubectl get nodes -o wide || log_warn "Could not retrieve node status."
    echo -e "\n${BOLD}Pod Status (all namespaces):${RESET}"; kubectl get pods --all-namespaces || log_warn "Could not retrieve pod status."
    echo
    if [ -f "kubeadm-init.log" ]; then log_info "Check ${BOLD}kubeadm-init.log${RESET} for initialization details (if performed)."; fi
    success_msg "Setup appears complete. Refer to previous steps for access details."
else log_warn "kubectl not available or KUBECONFIG ($KUBECONFIG) not found. Cannot display final status."; fi

# --- Calculate and Display Execution Time ---
SCRIPT_END_TIME=$(date +%s)
DURATION=$((SCRIPT_END_TIME - SCRIPT_START_TIME))
MINUTES=$((DURATION / 60))
SECONDS=$((DURATION % 60))
echo -e "${BLUE}--------------------------------------------------${RESET}"
log_info "Script execution completed in ${BOLD}${MINUTES} minutes and ${SECONDS} seconds${RESET}."
echo -e "${BLUE}${BOLD}##################################################${RESET}"

exit 0
