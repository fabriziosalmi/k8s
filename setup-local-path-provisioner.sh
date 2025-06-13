#!/bin/bash

# Script to install local-path-provisioner for better storage management
# This is a more robust alternative to manual hostPath PVs

set -euo pipefail

# --- Configuration ---
LOCAL_PATH_VERSION="v0.0.24"
LOCAL_PATH_NAMESPACE="local-path-storage"
LOCAL_PATH_STORAGE_CLASS="local-path"
LOCAL_PATH_CONFIG_PATH="/opt/local-path-provisioner"

# --- Terminal Colors ---
RESET='\033[0m'
BOLD='\033[1m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'

# --- Helper Functions ---
log_info() { echo -e "${CYAN}ℹ️ INFO:${RESET} $1"; }
log_warn() { echo -e "${YELLOW}${BOLD}⚠️ WARNING:${RESET}${YELLOW} $1${RESET}"; }
log_step() { echo -e "\n${CYAN}${BOLD}=== $1 ===${RESET}"; }
success_msg() { echo -e "${GREEN}✅ SUCCESS:${RESET} $1"; }
error_exit() { echo -e "\n${RED}${BOLD}❌ ERROR:${RESET}${RED} $1${RESET}\n" >&2; exit 1; }

# Check if kubectl is available and connected
if ! command -v kubectl &> /dev/null; then
    error_exit "kubectl not found. Please install kubectl first."
fi

if ! kubectl cluster-info > /dev/null 2>&1; then
    error_exit "Cannot connect to Kubernetes cluster. Check kubectl configuration."
fi

log_step "Installing Local Path Provisioner ${LOCAL_PATH_VERSION}"

# Create storage directory
log_info "Creating local storage directory: ${LOCAL_PATH_CONFIG_PATH}"
sudo mkdir -p "$LOCAL_PATH_CONFIG_PATH"
sudo chmod 755 "$LOCAL_PATH_CONFIG_PATH"

# Install local-path-provisioner
log_info "Installing local-path-provisioner from GitHub..."
kubectl apply -f "https://raw.githubusercontent.com/rancher/local-path-provisioner/${LOCAL_PATH_VERSION}/deploy/local-path-storage.yaml"

# Wait for deployment to be ready
log_info "Waiting for local-path-provisioner to be ready..."
kubectl wait --for=condition=available --timeout=120s deployment/local-path-provisioner -n "$LOCAL_PATH_NAMESPACE"

# Check if it's working
log_info "Verifying installation..."
kubectl get storageclass "$LOCAL_PATH_STORAGE_CLASS" -o wide

# Make it the default storage class (optional)
read -p "$(echo -e "${CYAN}Make local-path the default StorageClass? [y/N]: ${RESET}")" make_default
if [[ "$make_default" =~ ^[Yy]$ ]]; then
    log_info "Setting local-path as default StorageClass..."
    kubectl patch storageclass "$LOCAL_PATH_STORAGE_CLASS" -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
    success_msg "local-path is now the default StorageClass"
fi

success_msg "Local Path Provisioner installation complete!"

echo
log_info "Usage instructions:"
echo -e "  - Create PVCs without specifying a storageClassName (will use default)"
echo -e "  - Or specify: ${BOLD}storageClassName: local-path${RESET}"
echo -e "  - Data will be stored in: ${BOLD}${LOCAL_PATH_CONFIG_PATH}${RESET}"
echo
log_info "Example PVC:"
cat <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: example-pvc
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: local-path
  resources:
    requests:
      storage: 1Gi
EOF

echo
log_warn "Remember: This is still node-local storage, not suitable for multi-node clusters."
