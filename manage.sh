#!/bin/bash

# Enable strict error handling
set -euo pipefail

# --- Configuration ---
# Source common configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/config.sh" ]; then
    source "$SCRIPT_DIR/config.sh"
else
    # Fallback values if config.sh is not found
    HOST_DATA_BASE_DIR="/srv/k8s-apps-data"
    DEFAULT_PUID="1000"
    DEFAULT_PGID="1000"
    DEPLOYMENT_WAIT_TIMEOUT="300"
fi
NODE_IP=""

# --- Terminal Colors ---
RESET='\033[0m'; BOLD='\033[1m'; RED='\033[0;31m'; GREEN='\033[0;32m';
YELLOW='\033[0;33m'; BLUE='\033[0;34m'; MAGENTA='\033[0;35m'; CYAN='\033[0;36m';

# --- Script Timer ---
SCRIPT_START_TIME=$(date +%s)

# --- Helper Functions ---
log_step() { echo -e "\n${MAGENTA}${BOLD}--------------------------------------------------${RESET}"; echo -e "${MAGENTA}${BOLD}STEP: $1${RESET}"; echo -e "${MAGENTA}${BOLD}--------------------------------------------------${RESET}"; }
log_warn() { echo -e "${YELLOW}${BOLD}⚠️ WARNING:${RESET}${YELLOW} $1${RESET}"; }
log_info() { echo -e "${CYAN}ℹ️ INFO:${RESET} $1"; }
error_exit() { echo -e "\n${RED}${BOLD}❌ ERROR:${RESET}${RED} $1${RESET}\n" >&2; exit 1; }
success_msg() { echo -e "${GREEN}✅ SUCCESS:${RESET} $1"; }

check_root() { if [ "$(id -u)" -ne 0 ]; then error_exit "This script must be run as root OR ensure kubectl is configured for your user."; fi; }
check_command() { if ! command -v "$1" &> /dev/null; then error_exit "Required command '${BOLD}$1${RESET}${RED}' not found. Please install it."; fi; }
check_kubectl() { if ! kubectl cluster-info > /dev/null 2>&1; then error_exit "Cannot connect to Kubernetes cluster. Check kubectl config (${BOLD}KUBECONFIG=${KUBECONFIG:-'default'}${RESET}${RED})."; fi; log_info "Successfully connected to Kubernetes cluster."; }

# Function to create host path and PV/PVC with secure permissions
# Metadata format: "namespace;pvc_suffixes;pv_suffixes" (comma-separated suffixes)
setup_hostpath_pv_pvc() {
    local app_name="$1"; local namespace="$2"; local pvc_name="$3"; local host_path_suffix="$4"; local pv_suffix="$5"; local size="${6:-1Gi}"
    local host_path="${HOST_DATA_BASE_DIR}/${namespace}/${host_path_suffix}"; local pv_name="${namespace}-${pv_suffix}-pv"
    
    log_info "[${app_name}] Ensuring host directory: ${CYAN}${host_path}${RESET}"
    mkdir -p "$host_path" || error_exit "Failed to create host directory: $host_path"
    
    # Set secure permissions instead of 777
    # The directory owner should be able to read/write, and the group/others should have minimal access
    # The actual permissions will be managed by Kubernetes securityContext
    chown "${DEFAULT_PUID}:${DEFAULT_PGID}" "$host_path" 2>/dev/null || log_warn "Could not set ownership on $host_path. Directory permissions may need manual adjustment."
    chmod 755 "$host_path" || log_warn "Failed to set permissions on $host_path."
    
    log_info "[${app_name}] Set secure permissions (755) with owner ${DEFAULT_PUID}:${DEFAULT_PGID} on ${host_path}"
    log_info "[${app_name}] Applying PV (${pv_name}) and PVC (${pvc_name})"
    cat <<EOF | kubectl apply -n "$namespace" -f - >/dev/null
apiVersion: v1
kind: PersistentVolume
metadata:
  name: ${pv_name}
  labels:
    app.kubernetes.io/name: ${app_name}
    app.kubernetes.io/instance: ${app_name}-${host_path_suffix}
    managed-by: selfhost-deploy-script
spec: { capacity: { storage: ${size} }, volumeMode: Filesystem, accessModes: [ReadWriteOnce], persistentVolumeReclaimPolicy: Retain, storageClassName: "", hostPath: { path: "${host_path}", type: DirectoryOrCreate } }
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${pvc_name}
  labels: { managed-by: selfhost-deploy-script }
spec: { accessModes: [ReadWriteOnce], resources: { requests: { storage: ${size} } }, storageClassName: "", volumeName: ${pv_name} }
EOF
    success_msg "[${app_name}] PV/PVC (${pvc_name} -> ${pv_name}) setup complete."
}

# Function to deploy a generic app
deploy_generic_app() {
    local app_name="$1"; local namespace="$2"; local image="$3"; local pvc_name="$4"; local container_port="$5"; local host_path_suffix="$6"; local pv_suffix="$7"; local pvc_size="${8:-1Gi}"; local extra_env_yaml="${9:-}"
    log_step "Deploying: ${app_name}"
    log_info "[${app_name}] Creating Namespace: ${namespace}"; kubectl create namespace "$namespace" >/dev/null 2>&1 || log_info "[${app_name}] Namespace ${namespace} already exists."
    setup_hostpath_pv_pvc "$app_name" "$namespace" "$pvc_name" "$host_path_suffix" "$pv_suffix" "$pvc_size"
    log_info "[${app_name}] Applying Deployment and Service"
    cat <<EOF | kubectl apply -n "$namespace" -f - >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata: 
  name: ${app_name}-deployment
  labels: 
    app: ${app_name}
    managed-by: selfhost-deploy-script
spec: 
  replicas: 1
  selector: 
    matchLabels: 
      app: ${app_name}
  template: 
    metadata: 
      labels: 
        app: ${app_name}
    spec: 
      securityContext:
        runAsUser: ${DEFAULT_PUID}
        runAsGroup: ${DEFAULT_PGID}
        fsGroup: ${DEFAULT_PGID}
      volumes: 
        - name: data-volume
          persistentVolumeClaim: 
            claimName: ${pvc_name}
      containers: 
        - name: ${app_name}
          image: ${image}
          ports: 
            - containerPort: ${container_port}
              name: http
          volumeMounts: 
            - name: data-volume
              mountPath: /data
          env: 
            - name: PUID
              value: "${DEFAULT_PUID}"
            - name: PGID
              value: "${DEFAULT_PGID}"
            - name: TZ
              value: "Etc/UTC"
---
apiVersion: v1
kind: Service
metadata: 
  name: ${app_name}-service
  labels: 
    managed-by: selfhost-deploy-script
spec: 
  selector: 
    app: ${app_name}
  ports: 
    - protocol: TCP
      port: ${container_port}
      targetPort: ${container_port}
  type: NodePort
EOF
    log_info "[${app_name}] Waiting for deployment to be ready..."
    if kubectl wait --for=condition=available --timeout=${DEPLOYMENT_WAIT_TIMEOUT}s deployment/${app_name}-deployment -n "$namespace"; then
        success_msg "[${app_name}] Deployment successful!"
        local node_port=$(kubectl get svc ${app_name}-service -n "$namespace" -o=jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || echo "N/A")
        if [[ "$node_port" != "N/A" ]] && [[ -n "$NODE_IP" ]]; then
            local access_url="http://${NODE_IP}:${node_port}"; echo -e "${GREEN}--> Access ${app_name} at: ${BOLD}${CYAN}${access_url}${RESET}${RESET}";
        else log_warn "[${app_name}] Could not get NodePort or Node IP. Check service manually."; fi
    else 
        log_warn "[${app_name}] Deployment did not become available within ${DEPLOYMENT_WAIT_TIMEOUT} seconds."
        log_warn "Debug commands:"
        log_warn "  kubectl get pods -n ${namespace}"
        log_warn "  kubectl describe deployment ${app_name}-deployment -n ${namespace}"
        log_warn "  kubectl logs -l app=${app_name} -n ${namespace}"
    fi
}

# --- Specific App Deployment Functions (Install) ---
# (Functions deploy_portainer, deploy_nextcloud, deploy_gitea, etc. remain the same)
# ... (omitted for brevity, no changes needed in these functions from previous version) ...
deploy_portainer() {
    local app_name="portainer"; local ns="portainer"; local image="portainer/portainer-ce:latest"; local pvc="portainer-data-pvc"; local host_suffix="data"; local pv_suffix="data"; local size="2Gi"
    log_step "Deploying: Portainer (Container Management UI)"
    if kubectl get deployment portainer -n $ns > /dev/null 2>&1; then
        log_info "[${app_name}] Portainer deployment exists. Ensuring service is NodePort."
        kubectl patch service portainer -n "$ns" -p '{"spec": {"type": "NodePort"}}' >/dev/null 2>&1 || log_warn "[${app_name}] Failed to patch existing service."
    else
        log_info "[${app_name}] Creating Namespace: ${ns}"; kubectl create namespace "$ns" >/dev/null 2>&1 || true
        setup_hostpath_pv_pvc "$app_name" "$ns" "$pvc" "$host_suffix" "$pv_suffix" "$size"
        log_info "[${app_name}] Applying Deployment and Service"
        cat <<EOF | kubectl apply -n "$ns" -f - >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata: { name: portainer, labels: { app: portainer, managed-by: selfhost-deploy-script } }
spec: { replicas: 1, selector: { matchLabels: { app: portainer } }, template: { metadata: { labels: { app: portainer } }, spec: { volumes: [ { name: data, persistentVolumeClaim: { claimName: ${pvc} } } ], containers: [ { name: portainer, image: ${image}, ports: [ { containerPort: 8000, name: http-edge }, { containerPort: 9443, name: https-ui }, { containerPort: 9000, name: http-legacy } ], volumeMounts: [ { name: data, mountPath: /data } ] } ] } } }
---
apiVersion: v1
kind: Service
metadata: { name: portainer, labels: { managed-by: selfhost-deploy-script } }
spec: { selector: { app: portainer }, ports: [ { name: https-ui, protocol: TCP, port: 9443, targetPort: 9443 }, { name: http-edge, protocol: TCP, port: 8000, targetPort: 8000 } ], type: NodePort }
EOF
    fi
    log_info "[${app_name}] Waiting for deployment to be ready..."
    if kubectl wait --for=condition=available --timeout=300s deployment/portainer -n "$ns"; then
        success_msg "[${app_name}] Deployment ready!"
        local node_port=$(kubectl get svc portainer -n "$ns" -o=jsonpath='{.spec.ports[?(@.name=="https-ui")].nodePort}' 2>/dev/null || echo "N/A")
        if [[ "$node_port" != "N/A" ]] && [[ -n "$NODE_IP" ]]; then
            local access_url="https://${NODE_IP}:${node_port}"; echo -e "${GREEN}--> Access ${app_name} at: ${BOLD}${CYAN}${access_url}${RESET}${RESET}";
            echo -e "${YELLOW}    On first login, create an admin user.${RESET}"; echo -e "${YELLOW}    (Accept browser warning).${RESET}"
        else log_warn "[${app_name}] Could not get NodePort/IP."; fi
    else log_warn "[${app_name}] Deployment did not become available."; fi
}
deploy_nextcloud() {
    local app_name="nextcloud"; local ns="nextcloud"; local image="nextcloud:latest"; local pvc="nextcloud-data-pvc"; local port=80; local host_suffix="data"; local pv_suffix="data"; local size="10Gi"; local extra_env="- name: SQLITE_DATABASE\n          value: nextcloud.db"
    deploy_generic_app "$app_name" "$ns" "$image" "$pvc" "$port" "$host_suffix" "$pv_suffix" "$size" "$extra_env"; echo -e "${YELLOW}    On first login, create admin.${RESET}"; log_warn "[${app_name}] Using SQLite.";
}
deploy_gitea() {
    local app_name="gitea"; local ns="gitea"; local image="gitea/gitea:latest"; local pvc="gitea-data-pvc"; local port=3000; local host_suffix="data"; local pv_suffix="data"; local size="5Gi";
    log_step "Deploying: ${app_name} (Git Server)"; log_info "[${app_name}] Creating Namespace: ${ns}"; kubectl create namespace "$ns" >/dev/null 2>&1 || true
    setup_hostpath_pv_pvc "$app_name" "$ns" "$pvc" "$host_suffix" "$pv_suffix" "$size"
    log_info "[${app_name}] Applying Deployment and Service"
    cat <<EOF | kubectl apply -n "$ns" -f - >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata: { name: ${app_name}-deployment, labels: { app: ${app_name}, managed-by: selfhost-deploy-script } }
spec: { replicas: 1, selector: { matchLabels: { app: ${app_name} } }, template: { metadata: { labels: { app: ${app_name} } }, spec: { volumes: [ { name: d, persistentVolumeClaim: { claimName: ${pvc} } } ], containers: [ { name: ${app_name}, image: ${image}, ports: [ { containerPort: ${port}, name: http }, { containerPort: 22, name: ssh } ], volumeMounts: [ { name: d, mountPath: /data } ], env: [ { name: USER_UID, value: "1000" }, { name: USER_GID, value: "1000" } ] } ] } } }
---
apiVersion: v1
kind: Service
metadata: { name: ${app_name}-service, labels: { managed-by: selfhost-deploy-script } }
spec: { selector: { app: ${app_name} }, ports: [ { name: http, protocol: TCP, port: ${port}, targetPort: ${port} } ], type: NodePort }
EOF
    log_info "[${app_name}] Waiting for deployment..."; if kubectl wait --for=condition=available --timeout=300s deployment/${app_name}-deployment -n "$ns"; then
        success_msg "[${app_name}] Deployment successful!"; local node_port=$(kubectl get svc ${app_name}-service -n "$ns" -o=jsonpath='{.spec.ports[?(@.name=="http")].nodePort}' 2>/dev/null || echo "N/A");
        if [[ "$node_port" != "N/A" ]] && [[ -n "$NODE_IP" ]]; then local access_url="http://${NODE_IP}:${node_port}"; echo -e "${GREEN}--> Access ${app_name} at: ${BOLD}${CYAN}${access_url}${RESET}${RESET}"; echo -e "${YELLOW}    Complete initial setup (Database: SQLite3).${RESET}"; else log_warn "[${app_name}] Could not get NodePort/IP."; fi
    else log_warn "[${app_name}] Deployment failed."; fi
}
deploy_vaultwarden() {
    local app_name="vaultwarden"; local ns="vaultwarden"; local image="vaultwarden/server:latest"; local pvc="vw-data-pvc"; local port=80; local host_suffix="data"; local pv_suffix="data"; local size="1Gi"; local extra_env="- name: WEBSOCKET_ENABLED\n          value: \"true\""
    deploy_generic_app "$app_name" "$ns" "$image" "$pvc" "$port" "$host_suffix" "$pv_suffix" "$size" "$extra_env"; echo -e "${YELLOW}    Create account via web UI or client.${RESET}"; echo -e "${YELLOW}    Configure client API/Server URL.${RESET}"; log_warn "[${app_name}] Set ADMIN_TOKEN env var for admin panel.";
}
deploy_uptime_kuma() {
    local app_name="uptime-kuma"; local ns="uptime-kuma"; local image="louislam/uptime-kuma:latest"; local pvc="uk-data-pvc"; local port=3001; local host_suffix="data"; local pv_suffix="data"; local size="1Gi"
    deploy_generic_app "$app_name" "$ns" "$image" "$pvc" "$port" "$host_suffix" "$pv_suffix" "$size"; echo -e "${YELLOW}    Create admin account on first access.${RESET}";
}
deploy_jellyfin() {
    local app_name="jellyfin"; local ns="jellyfin"; local image="jellyfin/jellyfin:latest"; local cfg_pvc="jf-config-pvc"; local med_pvc="jf-media-pvc"; local port=8096; local cfg_host_sfx="config"; local med_host_sfx="media"; local cfg_pv_sfx="config"; local med_pv_sfx="media"; local cfg_size="2Gi"; local med_size="1Gi"
    log_step "Deploying: ${app_name} (Media Server)"; log_info "[${app_name}] Creating Namespace: ${ns}"; kubectl create namespace "$ns" >/dev/null 2>&1 || true
    setup_hostpath_pv_pvc "$app_name" "$ns" "$cfg_pvc" "$cfg_host_sfx" "$cfg_pv_sfx" "$cfg_size"
    setup_hostpath_pv_pvc "$app_name" "$ns" "$med_pvc" "$med_host_sfx" "$med_pv_sfx" "$med_size"
    log_warn "[${app_name}] Media dir: ${HOST_DATA_BASE_DIR}/${ns}/${med_host_sfx}. Update PV if needed.";
    log_info "[${app_name}] Applying Deployment and Service"
    cat <<EOF | kubectl apply -n "$ns" -f - >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata: { name: ${app_name}-deployment, labels: { app: ${app_name}, managed-by: selfhost-deploy-script } }
spec: { replicas: 1, selector: { matchLabels: { app: ${app_name} } }, template: { metadata: { labels: { app: ${app_name} } }, spec: { volumes: [ { name: vcfg, persistentVolumeClaim: { claimName: ${cfg_pvc} } }, { name: vmed, persistentVolumeClaim: { claimName: ${med_pvc} } } ], containers: [ { name: ${app_name}, image: ${image}, ports: [ { containerPort: ${port}, name: http } ], volumeMounts: [ { name: vcfg, mountPath: /config }, { name: vmed, mountPath: /media } ], env: [ { name: PUID, value: "1000" }, { name: PGID, value: "1000" }, { name: TZ, value: "Etc/UTC" } ] } ] } } }
---
apiVersion: v1
kind: Service
metadata: { name: ${app_name}-service, labels: { managed-by: selfhost-deploy-script } }
spec: { selector: { app: ${app_name} }, ports: [ { name: http, protocol: TCP, port: ${port}, targetPort: ${port} } ], type: NodePort }
EOF
    log_info "[${app_name}] Waiting for deployment..."; if kubectl wait --for=condition=available --timeout=300s deployment/${app_name}-deployment -n "$ns"; then
        success_msg "[${app_name}] Deployment successful!"; local node_port=$(kubectl get svc ${app_name}-service -n "$ns" -o=jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || echo "N/A");
        if [[ "$node_port" != "N/A" ]] && [[ -n "$NODE_IP" ]]; then local access_url="http://${NODE_IP}:${node_port}"; echo -e "${GREEN}--> Access ${app_name} at: ${BOLD}${CYAN}${access_url}${RESET}${RESET}"; echo -e "${YELLOW}    Complete initial setup.${RESET}"; echo -e "${YELLOW}    Configure media libraries pointing to ${BOLD}/media${RESET}${YELLOW}.${RESET}"; else log_warn "[${app_name}] Could not get NodePort/IP."; fi
    else log_warn "[${app_name}] Deployment failed."; fi
}
deploy_home_assistant() {
    local app_name="home-assistant"; local ns="home-assistant"; local image="ghcr.io/home-assistant/home-assistant:stable"; local pvc="ha-config-pvc"; local port=8123; local host_suffix="config"; local pv_suffix="config"; local size="5Gi"
    log_step "Deploying: ${app_name} (Home Automation)"; log_info "[${app_name}] Creating Namespace: ${ns}"; kubectl create namespace "$ns" >/dev/null 2>&1 || true
    setup_hostpath_pv_pvc "$app_name" "$ns" "$pvc" "$host_suffix" "$pv_suffix" "$size"
    log_info "[${app_name}] Applying Deployment and Service"
    cat <<EOF | kubectl apply -n "$ns" -f - >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata: { name: ${app_name}-deployment, labels: { app: ${app_name}, managed-by: selfhost-deploy-script } }
spec: { replicas: 1, selector: { matchLabels: { app: ${app_name} } }, template: { metadata: { labels: { app: ${app_name} } }, spec: { volumes: [ { name: vcfg, persistentVolumeClaim: { claimName: ${pvc} } } ], containers: [ { name: ${app_name}, image: ${image}, ports: [ { containerPort: ${port}, name: http } ], volumeMounts: [ { name: vcfg, mountPath: /config } ], env: [ { name: TZ, value: "Etc/UTC" } ] } ] } } }
---
apiVersion: v1
kind: Service
metadata: { name: ${app_name}-service, labels: { managed-by: selfhost-deploy-script } }
spec: { selector: { app: ${app_name} }, ports: [ { name: http, protocol: TCP, port: ${port}, targetPort: ${port} } ], type: NodePort }
EOF
    log_info "[${app_name}] Waiting for deployment (can take a while)..."; if kubectl wait --for=condition=available --timeout=480s deployment/${app_name}-deployment -n "$ns"; then # Longer timeout
        success_msg "[${app_name}] Deployment successful!"; local node_port=$(kubectl get svc ${app_name}-service -n "$ns" -o=jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || echo "N/A");
        if [[ "$node_port" != "N/A" ]] && [[ -n "$NODE_IP" ]]; then local access_url="http://${NODE_IP}:${node_port}"; echo -e "${GREEN}--> Access ${app_name} at: ${BOLD}${CYAN}${access_url}${RESET}${RESET}"; echo -e "${YELLOW}    Create account during onboarding.${RESET}"; else log_warn "[${app_name}] Could not get NodePort/IP."; fi
    else log_warn "[${app_name}] Deployment failed."; fi
}
deploy_filebrowser() {
    local app_name="filebrowser"; local ns="filebrowser"; local image="filebrowser/filebrowser:latest"; local cfg_pvc="fb-config-pvc"; local data_pvc="fb-data-pvc"; local port=80; local cfg_host_sfx="config"; local data_host_sfx="files"; local cfg_pv_sfx="config"; local data_pv_sfx="files"; local cfg_size="1Gi"; local data_size="10Gi"
    log_step "Deploying: ${app_name} (Web File Manager)"; log_info "[${app_name}] Creating Namespace: ${ns}"; kubectl create namespace "$ns" >/dev/null 2>&1 || true
    setup_hostpath_pv_pvc "$app_name" "$ns" "$cfg_pvc" "$cfg_host_sfx" "$cfg_pv_sfx" "$cfg_size"
    setup_hostpath_pv_pvc "$app_name" "$ns" "$data_pvc" "$data_host_sfx" "$data_pv_sfx" "$data_size"
    log_warn "[${app_name}] Files dir: ${HOST_DATA_BASE_DIR}/${ns}/${data_host_sfx}. Place files here.";
    log_info "[${app_name}] Applying Deployment and Service"
    cat <<EOF | kubectl apply -n "$ns" -f - >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata: { name: ${app_name}-deployment, labels: { app: ${app_name}, managed-by: selfhost-deploy-script } }
spec: { replicas: 1, selector: { matchLabels: { app: ${app_name} } }, template: { metadata: { labels: { app: ${app_name} } }, spec: { volumes: [ { name: vcfg, persistentVolumeClaim: { claimName: ${cfg_pvc} } }, { name: vdata, persistentVolumeClaim: { claimName: ${data_pvc} } } ], containers: [ { name: ${app_name}, image: ${image}, ports: [ { containerPort: ${port}, name: http } ], volumeMounts: [ { name: vcfg, mountPath: /database }, { name: vdata, mountPath: /srv } ], args: ["--database=/database/filebrowser.db", "--root=/srv"] } ] } } }
---
apiVersion: v1
kind: Service
metadata: { name: ${app_name}-service, labels: { managed-by: selfhost-deploy-script } }
spec: { selector: { app: ${app_name} }, ports: [ { name: http, protocol: TCP, port: ${port}, targetPort: ${port} } ], type: NodePort }
EOF
    log_info "[${app_name}] Waiting for deployment..."; if kubectl wait --for=condition=available --timeout=300s deployment/${app_name}-deployment -n "$ns"; then
        success_msg "[${app_name}] Deployment successful!"; local node_port=$(kubectl get svc ${app_name}-service -n "$ns" -o=jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || echo "N/A");
        if [[ "$node_port" != "N/A" ]] && [[ -n "$NODE_IP" ]]; then local access_url="http://${NODE_IP}:${node_port}"; echo -e "${GREEN}--> Access ${app_name} at: ${BOLD}${CYAN}${access_url}${RESET}${RESET}"; echo -e "${YELLOW}    Default login: ${BOLD}admin / admin${RESET}${YELLOW} - CHANGE IMMEDIATELY!${RESET}"; else log_warn "[${app_name}] Could not get NodePort/IP."; fi
    else log_warn "[${app_name}] Deployment failed."; fi
}

# --- Uninstall Functions ---
detect_installed_apps() {
    log_info "Detecting potentially installed apps (checking namespaces)..."
    declare -g -a detected_apps # Make array global for selection later
    detected_apps=()
    local found_count=0
    for display_name in "${!app_metadata[@]}"; do
        local meta_string="${app_metadata[$display_name]}"
        local namespace=$(echo "$meta_string" | cut -d';' -f1)
        # Also check for our label on the namespace for more certainty
        if kubectl get namespace "$namespace" -L managed-by=selfhost-deploy-script -o name > /dev/null 2>&1; then
            log_info "Found managed namespace: ${BOLD}${namespace}${RESET} (App: ${display_name})"
            detected_apps+=("$display_name") # Store display name
            found_count=$((found_count + 1))
        elif kubectl get namespace "$namespace" -o name > /dev/null 2>&1; then
             log_warn "Found namespace ${BOLD}${namespace}${RESET} (App: ${display_name}) but it lacks 'managed-by=selfhost-deploy-script' label. Including anyway, but use caution during uninstall."
             detected_apps+=("$display_name") # Store display name
             found_count=$((found_count + 1))
        fi
    done
    if [ $found_count -eq 0 ]; then log_info "No application namespaces managed by this script were detected."; return 1; fi
    return 0
}

uninstall_selected_apps() {
    local passed_array_name="$1"
    # FIX: Use a different local name for the nameref
    local -n apps_to_uninstall_ref="${passed_array_name}"

    if [ ${#apps_to_uninstall_ref[@]} -eq 0 ]; then
        log_info "No applications selected for uninstallation."
        return
    fi

    log_step "Starting Uninstallation of Selected Applications (${#apps_to_uninstall_ref[@]} apps)"

    local app_count=0
    local total_apps=${#apps_to_uninstall_ref[@]}
    for app_display_name in "${apps_to_uninstall_ref[@]}"; do
        app_count=$((app_count + 1))
        log_info "Processing uninstall for app ${app_count} of ${total_apps}: ${BOLD}${app_display_name}${RESET}"
        local meta_string="${app_metadata[$app_display_name]}"
        if [ -z "$meta_string" ]; then log_warn "No metadata for '${app_display_name}'. Skipping."; continue; fi

        local namespace=$(echo "$meta_string" | cut -d';' -f1)
        local pv_suffixes_str=$(echo "$meta_string" | cut -d';' -f3)

        # 1. Confirm K8s Resource Deletion
        read -p "$(echo -e "${YELLOW}❓ Delete ALL K8s resources in namespace ${BOLD}${namespace}${RESET}${YELLOW} for ${BOLD}${app_display_name}${RESET}${YELLOW}? [y/N]: ${RESET}")" confirm_k8s
        if [[ ! "$confirm_k8s" =~ ^[Yy]$ ]]; then
            log_info "[${app_display_name}] Skipping Kubernetes resource deletion."
        else
            # Delete associated PVs first (if any) - This might help release claims before NS delete
            if [ -n "$pv_suffixes_str" ]; then
                log_info "[${app_display_name}] Attempting to delete associated PersistentVolumes..."
                IFS=',' read -r -a pv_suffixes <<< "$pv_suffixes_str"
                for pv_suffix in "${pv_suffixes[@]}"; do
                    local pv_name="${namespace}-${pv_suffix}-pv"
                    log_info "[${app_display_name}] Deleting PV ${BOLD}${pv_name}${RESET}..."
                    if kubectl delete pv "$pv_name" --ignore-not-found=true --timeout=30s; then
                       success_msg "[${app_display_name}] Deleted PV ${pv_name}."
                    else log_warn "[${app_display_name}] Failed/Timeout deleting PV ${pv_name} (may be bound or already gone)."; fi
                done
            fi

            log_info "[${app_display_name}] Deleting Namespace ${BOLD}${namespace}${RESET} (wait=false)..."
            if kubectl delete namespace "$namespace" --ignore-not-found=true --wait=false; then
                success_msg "[${app_display_name}] Namespace deletion initiated."
                log_info "[${app_display_name}] Note: Namespace termination can take time in the background."
            else log_warn "[${app_display_name}] Failed to initiate namespace deletion."; fi
        fi # End K8s resource deletion

        # 2. Confirm Host Data Deletion
        local host_data_path="${HOST_DATA_BASE_DIR}/${namespace}"
        if [ -d "$host_data_path" ]; then
            echo # Add newline
            read -p "$(echo -e "${RED}${BOLD}❓ PERMANENTLY DELETE host data for ${app_display_name} at ${CYAN}${host_data_path}${RESET}${RED}? Cannot be undone! [y/N]: ${RESET}")" confirm_host_data
            if [[ "$confirm_host_data" =~ ^[Yy]$ ]]; then
                log_warn "[${app_display_name}] Deleting host data directory ${BOLD}${host_data_path}${RESET}..."
                if rm -rf "$host_data_path"; then success_msg "[${app_display_name}] Host data directory deleted.";
                else log_warn "[${app_display_name}] Failed to delete host data directory: $host_data_path"; fi # Warn, don't exit
            else log_info "[${app_display_name}] Skipping host data deletion."; fi
        else log_info "[${app_display_name}] Host data directory ${host_data_path} not found, skipping deletion."; fi # End Host data deletion

        success_msg "Finished uninstall process for ${app_display_name}."
        echo
    done
}


# --- Main Execution ---
log_step "Self-Hosted App Deployment / Uninstallation Script"
# Basic command checks needed for core functionality
check_command kubectl
check_command cut
check_command sort
check_command printf
check_command date
if ! command -v mapfile &> /dev/null && ! command -v readarray &> /dev/null; then error_exit "Requires 'mapfile' or 'readarray' command (Bash 4+)."; fi


# --- App Definitions and Metadata ---
# Metadata stores "namespace;pvc_names_comma_sep;pv_suffixes_comma_sep"
# Used for install (function mapping) and uninstall (finding resources)
declare -A app_install_funcs
declare -A app_metadata
# App Display Name -> Install Function
app_install_funcs["Portainer"]="deploy_portainer"
app_metadata["Portainer"]="portainer;portainer-data-pvc;data"
app_install_funcs["Nextcloud (SQLite)"]="deploy_nextcloud"
app_metadata["Nextcloud (SQLite)"]="nextcloud;nextcloud-data-pvc;data"
app_install_funcs["Gitea (SQLite)"]="deploy_gitea"
app_metadata["Gitea (SQLite)"]="gitea;gitea-data-pvc;data"
app_install_funcs["Vaultwarden (Bitwarden Server)"]="deploy_vaultwarden"
app_metadata["Vaultwarden (Bitwarden Server)"]="vaultwarden;vw-data-pvc;data"
app_install_funcs["Uptime Kuma (Monitoring)"]="deploy_uptime_kuma"
app_metadata["Uptime Kuma (Monitoring)"]="uptime-kuma;uk-data-pvc;data"
app_install_funcs["Jellyfin (Media Server)"]="deploy_jellyfin"
app_metadata["Jellyfin (Media Server)"]="jellyfin;jf-config-pvc,jf-media-pvc;config,media"
app_install_funcs["Home Assistant"]="deploy_home_assistant"
app_metadata["Home Assistant"]="home-assistant;ha-config-pvc;config"
app_install_funcs["File Browser"]="deploy_filebrowser"
app_metadata["File Browser"]="filebrowser;fb-config-pvc,fb-data-pvc;config,files"


# --- Mode Selection ---
SCRIPT_MODE=""
echo -e "${BOLD}Choose Operation Mode:${RESET}"
echo -e "  [${CYAN}i${RESET}] ${BOLD}Install${RESET} new applications"
echo -e "  [${CYAN}u${RESET}] ${BOLD}Uninstall${RESET} existing applications"
echo -e "  [${CYAN}q${RESET}] ${BOLD}Quit${RESET}"
while true; do
    read -p "$(echo -e "${CYAN}Enter mode (i/u/q) [q]: ${RESET}")" mode_choice; mode_choice=${mode_choice:-q}; mode_choice=$(echo "$mode_choice" | tr '[:upper:]' '[:lower:]')
    case "$mode_choice" in
        i) SCRIPT_MODE="install"; break ;; u) SCRIPT_MODE="uninstall"; break ;; q) log_info "Exiting script."; exit 0 ;; *) log_warn "Invalid choice." ;;
    esac
done

# --- Execution Flow ---
check_kubectl # Check connection after mode selection

# Auto-detect Node IP (needed for install instructions)
if [ "$SCRIPT_MODE" == "install" ]; then
    if [ -z "$NODE_IP" ]; then
        log_info "Attempting to auto-detect Node IP address..."; NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)
        [ -z "$NODE_IP" ] && NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="ExternalIP")].address}' 2>/dev/null || true)
        [ -z "$NODE_IP" ] && NODE_IP=$(hostname -I | awk '{print $1}')
        if [ -n "$NODE_IP" ]; then log_info "Auto-detected Node IP: ${BOLD}${NODE_IP}${RESET}"; else log_warn "Failed to auto-detect Node IP."; fi
    else log_info "Using manually specified Node IP: ${BOLD}${NODE_IP}${RESET}"; fi; echo
fi

# --- INSTALL MODE ---
if [ "$SCRIPT_MODE" == "install" ]; then
    available_apps=(); for key in "${!app_install_funcs[@]}"; do available_apps+=("$key"); done
    IFS=$'\n' sorted_apps=($(sort <<<"${available_apps[*]}")); unset IFS
    log_step "Select Applications to Install"
    echo -e "The following applications can be installed:"; declare -a selected_apps=(); declare -a temp_selected_apps=()
    for i in "${!sorted_apps[@]}"; do printf "  [%2d] %s\n" $((i+1)) "${sorted_apps[i]}"; done
    echo -e "Enter numbers (e.g., '1 3 5'), or '${BOLD}a${RESET}' for all, or '${BOLD}n${RESET}' for none:"
    read -p "$(echo -e "${CYAN}Your choices: ${RESET}")" user_choice
    if [[ "$user_choice" =~ ^[Aa]([Ll][Ll])?$ ]]; then log_info "Selecting all."; selected_apps=("${sorted_apps[@]}");
    elif [[ "$user_choice" =~ ^[Nn]([Oo][Nn][Ee]?)?$ ]] || [[ -z "$user_choice" ]]; then log_info "None selected."; selected_apps=();
    else for num in $user_choice; do if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -ge 1 ] && [ "$num" -le "${#sorted_apps[@]}" ]; then index=$((num-1)); temp_selected_apps+=("${sorted_apps[index]}"); else log_warn "Ignoring: $num"; fi; done
         declare -a unique_selected_apps; mapfile -t unique_selected_apps < <(printf "%s\n" "${temp_selected_apps[@]}" | sort -u); selected_apps=("${unique_selected_apps[@]}"); unset temp_selected_apps unique_selected_apps; fi
    if [ ${#selected_apps[@]} -eq 0 ]; then log_info "No applications selected."; else
        log_step "Starting Deployment (${#selected_apps[@]} apps)"; log_warn "Using ${BOLD}hostPath${RESET}${YELLOW} storage in ${CYAN}${HOST_DATA_BASE_DIR}${RESET}${YELLOW}. ${RED}${BOLD}INSECURE - DEMO ONLY.${RESET}"
        app_count=0; total_apps=${#selected_apps[@]}; for app_display_name in "${selected_apps[@]}"; do app_count=$((app_count + 1))
            log_info "Deploying app ${app_count}/${total_apps}: ${BOLD}${app_display_name}${RESET}"; app_func_name="${app_install_funcs[$app_display_name]}"
            if [ -n "$app_func_name" ] && declare -f "$app_func_name" > /dev/null; then "$app_func_name"; echo; else log_warn "Install func missing for '${app_display_name}'."; fi
        done; success_msg "Finished deployment attempts."
    fi
# --- UNINSTALL MODE ---
elif [ "$SCRIPT_MODE" == "uninstall" ]; then
    declare -g -a detected_apps # Needs to be global for detect function
    if ! detect_installed_apps; then log_info "Exiting uninstall mode."; else
        log_step "Select Applications to Uninstall"
        echo -e "Detected applications (managed by script):"; declare -a apps_to_uninstall=(); declare -a temp_selected_apps=()
        IFS=$'\n' sorted_detected_apps=($(sort <<<"${detected_apps[*]}")); unset IFS
        for i in "${!sorted_detected_apps[@]}"; do printf "  [%2d] %s\n" $((i+1)) "${sorted_detected_apps[i]}"; done
        echo -e "Enter numbers to uninstall (e.g., '1 3'), '${BOLD}a${RESET}' for all detected, '${BOLD}n${RESET}' for none:"
        read -p "$(echo -e "${CYAN}Your choices: ${RESET}")" user_choice
        if [[ "$user_choice" =~ ^[Aa]([Ll][Ll])?$ ]]; then log_info "Selecting all detected for uninstall."; apps_to_uninstall=("${sorted_detected_apps[@]}");
        elif [[ "$user_choice" =~ ^[Nn]([Oo][Nn][Ee]?)?$ ]] || [[ -z "$user_choice" ]]; then log_info "None selected for uninstall."; apps_to_uninstall=();
        else for num in $user_choice; do if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -ge 1 ] && [ "$num" -le "${#sorted_detected_apps[@]}" ]; then index=$((num-1)); temp_selected_apps+=("${sorted_detected_apps[index]}"); else log_warn "Ignoring: $num"; fi; done
             declare -a unique_selected_apps; mapfile -t unique_selected_apps < <(printf "%s\n" "${temp_selected_apps[@]}" | sort -u); apps_to_uninstall=("${unique_selected_apps[@]}"); unset temp_selected_apps unique_selected_apps; fi
        # Perform uninstall
        uninstall_selected_apps apps_to_uninstall # Pass array NAME
    fi
fi

# --- Script End ---
SCRIPT_END_TIME=$(date +%s)
DURATION=$((SCRIPT_END_TIME - SCRIPT_START_TIME))
MINUTES=$((DURATION / 60))
SECONDS=$((DURATION % 60))
echo -e "\n${BLUE}--------------------------------------------------${RESET}"
log_info "Script finished in ${BOLD}${MINUTES} minutes and ${SECONDS} seconds${RESET}."
echo -e "${BLUE}${BOLD}##################################################${RESET}"

exit 0
