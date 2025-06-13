#!/bin/bash

# Enable strict error handling
set -euo pipefail

# --- Configuration ---
# Add namespaces here that you want to exclude from the Application Overview
EXCLUDE_NAMESPACES=("kube-system" "kube-public" "kube-node-lease" "local-path-storage" "kube-flannel" "calico-system" "tigera-operator") # Added common CNI/operator namespaces

# --- Terminal Colors ---
RESET='\033[0m'; BOLD='\033[1m'; DIM='\033[2m'; RED='\033[0;31m'; LRED='\033[1;31m';
GREEN='\033[0;32m'; LGREEN='\033[1;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m';
MAGENTA='\033[0;35m'; CYAN='\033[0;36m'; LGRAY='\033[0;37m'; WHITE='\033[1;37m';

# --- State ---
METRICS_AVAILABLE=false

# --- Helper Functions ---
print_header() { echo -e "\n${BLUE}${BOLD}=== $1 ===${RESET}"; }
print_subheader() { echo -e "${MAGENTA}--- $1 ---${RESET}"; }
log_warn() { echo -e "${YELLOW}${BOLD}⚠️ WARNING:${RESET}${YELLOW} $1${RESET}"; }
log_error() { echo -e "${RED}${BOLD}❌ ERROR:${RESET}${RED} $1${RESET}"; } # Added Error log
log_info() { echo -e "${CYAN}ℹ️ INFO:${RESET} $1"; }
check_command() { if ! command -v "$1" &> /dev/null; then log_warn "Command '${BOLD}$1${RESET}${YELLOW}' not found. Some features might be unavailable."; return 1; fi; return 0; }
check_kubectl() { if ! kubectl cluster-info > /dev/null 2>&1; then log_error "Cannot connect to Kubernetes cluster via kubectl."; exit 1; fi; }

print_status() {
    local status="$1"; local expected_status="${2:-Ready}"; local ok_color="${LGREEN}"; local fail_color="${LRED}"
    # Handle the case where status might be "True" or "False" from custom-columns (Node Ready condition)
    if [[ "$status" == "True" ]]; then status="Ready"; fi
    if [[ "$status" == "False" ]]; then status="NotReady"; fi

    if [[ "$status" == "$expected_status" ]]; then echo -e "${ok_color}${status}${RESET}"; else echo -e "${fail_color}${status}${RESET}"; fi
}

check_metrics_server() {
    if kubectl get apiservice v1beta1.metrics.k8s.io -o name > /dev/null 2>&1; then
        # Check if top nodes actually returns data (can take a moment after install)
        if kubectl top nodes --no-headers 2>/dev/null | head -n 1 | grep -q '[0-9]'; then
             METRICS_AVAILABLE=true; log_info "Metrics Server detected and reporting.";
        else
             METRICS_AVAILABLE=false; log_warn "Metrics Server API found, but 'kubectl top nodes' failed or returned no data. Metrics may be starting or unhealthy.";
        fi
    else
        METRICS_AVAILABLE=false; log_warn "Metrics Server API service (v1beta1.metrics.k8s.io) not found. Resource usage stats skipped.";
        log_warn "Install: kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml";
    fi
}

# --- Initial Checks ---
check_command kubectl; check_command awk; check_command sed; check_command grep; check_command sort; check_command head; check_command tail; check_command wc; check_command cut; check_command printf; check_command date
# Optional: check_command jq
check_kubectl
check_metrics_server

# --- Cluster Overview ---
print_header "Cluster Overview"
K8S_SERVER_VERSION=""; K8S_VERSION_JSON=""
if K8S_VERSION_JSON=$(kubectl version -o json 2>/dev/null); then
    if check_command jq; then K8S_SERVER_VERSION=$(echo "$K8S_VERSION_JSON" | jq -r .serverVersion.gitVersion 2>/dev/null); fi
    # Fallback parsing if jq failed or not present
    if [ -z "$K8S_SERVER_VERSION" ]; then K8S_SERVER_VERSION=$(echo "$K8S_VERSION_JSON" | grep '"gitVersion":' | head -n1 | sed -e 's/.*: *"//' -e 's/",?//'); fi
fi
# Final fallback if JSON failed
if [ -z "$K8S_SERVER_VERSION" ]; then K8S_SERVER_VERSION=$(kubectl version 2>/dev/null | grep 'Server Version:' | awk '{print $3}'); fi
K8S_API_ENDPOINT=$(kubectl cluster-info 2>/dev/null | grep 'Kubernetes control plane' | awk '/is running at/ {print $NF}')
echo -e " ${BOLD}API Endpoint:${RESET}\t${CYAN}${K8S_API_ENDPOINT:-N/A}${RESET}"
echo -e " ${BOLD}Server Version:${RESET}\t${CYAN}${K8S_SERVER_VERSION:-N/A}${RESET}"

# --- Node Status ---
print_header "Node Status"
# Use custom-columns; note the escaped dot in the label selector
NODE_OUTPUT_LINES=$(kubectl get nodes -o 'custom-columns=NAME:.metadata.name,STATUS:.status.conditions[?(@.type=="Ready")].status,ROLES:.metadata.labels."kubernetes\.io/role",VERSION:.status.nodeInfo.kubeletVersion,INTERNAL-IP:.status.addresses[?(@.type=="InternalIP")].address,OS-IMAGE:.status.nodeInfo.osImage' --no-headers 2>/dev/null)

if [ -z "$NODE_OUTPUT_LINES" ]; then
    log_warn "No nodes found or failed to get node information."
else
    NUM_NODES=$(echo "$NODE_OUTPUT_LINES" | wc -l)
    # Count lines where the second column (STATUS, which is 'True' or 'False') is "True"
    NUM_READY=$(echo "$NODE_OUTPUT_LINES" | awk '$2 == "True"' | wc -l)
    NUM_NOT_READY=$((NUM_NODES - NUM_READY))
    STATUS_COLOR="${LGREEN}"; [[ "$NUM_NOT_READY" -gt 0 ]] && STATUS_COLOR="${LRED}"
    echo -e " ${BOLD}Total Nodes:${RESET}\t${NUM_NODES} (${LGREEN}${NUM_READY} Ready${RESET}, ${STATUS_COLOR}${NUM_NOT_READY} NotReady${RESET})"

    # Pre-fetch metrics if available
    declare -A NODE_CPU_USAGE NODE_MEM_USAGE CPU_PERCENT MEM_PERCENT
    if $METRICS_AVAILABLE; then
         while IFS= read -r line; do
            # Skip lines that don't have the expected number of fields (e.g., header if --no-headers failed, or error messages)
            [[ $(echo "$line" | wc -w) -lt 5 ]] && continue
            name=$(echo "$line" | awk '{print $1}'); cpu=$(echo "$line" | awk '{print $2}'); cpu_p=$(echo "$line" | awk '{print $3}'); mem=$(echo "$line" | awk '{print $4}'); mem_p=$(echo "$line" | awk '{print $5}')
            # Ensure keys are set even if values are empty momentarily
            NODE_CPU_USAGE["$name"]="${cpu:-N/A}"; CPU_PERCENT["$name"]="${cpu_p%\%}"; NODE_MEM_USAGE["$name"]="${mem:-N/A}"; MEM_PERCENT["$name"]="${mem_p%\%}"
        done < <(kubectl top nodes --no-headers 2>/dev/null)
    fi

    print_subheader "Node Details"
    # Adjust padding slightly for potentially longer colored status
    printf " ${BOLD}%-25s %-18s %-20s %-15s %-15s %-30s${RESET}" "NAME" "STATUS" "ROLES" "VERSION" "INTERNAL-IP" "OS-IMAGE"
    if $METRICS_AVAILABLE; then printf " ${BOLD}%-10s %-5s %-8s %-5s${RESET}" "CPU(c)" "CPU%" "MEM(Mi)" "MEM%"; fi
    printf "\n"

    echo "$NODE_OUTPUT_LINES" | while IFS= read -r line; do
        # Use awk to extract fields robustly, OS Image is everything after field 5
        name=$(echo "$line" | awk '{print $1}')
        status_val=$(echo "$line" | awk '{print $2}')
        roles=$(echo "$line" | awk '{print $3}')
        version=$(echo "$line" | awk '{print $4}')
        internal_ip=$(echo "$line" | awk '{print $5}')
        # This awk command reassigns fields 1-5 to empty strings, then prints the rest ($0),
        # which effectively gives fields 6 onwards. sed removes leading space.
        os_image=$(echo "$line" | awk '{ $1=$2=$3=$4=$5=""; print $0 }' | sed 's/^[ \t]*//')

        status_colored=$(print_status "$status_val") # print_status handles True/False -> Ready/NotReady + Color
        [[ "$roles" == "<none>" || -z "$roles" ]] && roles="<worker>" # Handle no role label or empty role field

        # Truncate OS Image if needed, printf %.30s handles the rest
        os_image_display="${os_image}"
        # printf handles width limiting, but let's truncate os_image slightly earlier if very long
        # if [ ${#os_image_display} -gt 30 ]; then os_image_display="${os_image_display:0:27}..."; fi

        # Note: Color codes affect alignment; widths below are approximate visual guides.
        printf " %-25s %-18b %-20s %-15s %-15s %-30.30s" "$name" "$status_colored" "$roles" "$version" "$internal_ip" "$os_image_display"

        if $METRICS_AVAILABLE; then
            # Use parameter expansion ${VAR:-Default} for safety, though pre-fetch loop tries to set N/A
            cpu_val="${NODE_CPU_USAGE[$name]:-N/A}"; cpu_p_val="${CPU_PERCENT[$name]:-N/A}"
            mem_val="${NODE_MEM_USAGE[$name]:-N/A}"; mem_p_val="${MEM_PERCENT[$name]:-N/A}"
            # Add '%' suffix only if value is not N/A
            [[ "$cpu_p_val" != "N/A" ]] && cpu_p_disp="${cpu_p_val}%" || cpu_p_disp="N/A"
            [[ "$mem_p_val" != "N/A" ]] && mem_p_disp="${mem_p_val}%" || mem_p_disp="N/A"
            printf " %-10s %-5s %-8s %-5s" "$cpu_val" "$cpu_p_disp" "$mem_val" "$mem_p_disp"
        fi
        printf "\n"
    done
fi

# --- Control Plane Health ---
print_header "Control Plane Health"
# Use verbose readyz endpoint first
HEALTH_OUTPUT=$(kubectl get --raw='/readyz?verbose' 2>/dev/null); HEALTH_STATUS="Unknown"
if [[ -n "$HEALTH_OUTPUT" ]]; then
    # Exclude specific known "informational" non-ready items if needed, e.g., 'informer-sync'
    # UNHEALTHY_LINES=$(echo "$HEALTH_OUTPUT" | grep '\[-\]' | grep -v 'informer-sync') # Example exclusion
    UNHEALTHY_LINES=$(echo "$HEALTH_OUTPUT" | grep '\[-\]')
    if [[ -n "$UNHEALTHY_LINES" ]]; then
        HEALTH_STATUS="Unhealthy"; echo -e "${LRED}${BOLD}❌ /readyz reports unhealthy components:${RESET}"; echo "$UNHEALTHY_LINES" | sed 's/^/  /';
    elif echo "$HEALTH_OUTPUT" | grep -q "\[+\]"; then HEALTH_STATUS="Healthy"; echo -e "${LGREEN}✅ /readyz reports healthy.${RESET}";
    # Handle case where output exists but has no [+] or [-] (unlikely but possible)
    else log_warn "Could not determine health from /readyz output. Output present but format unexpected."; echo "$HEALTH_OUTPUT"; fi
else # Fallback checks if /readyz failed
    HEALTH_OUTPUT=$(kubectl get --raw='/healthz' 2>/dev/null)
    if [[ "$HEALTH_OUTPUT" == "ok" ]]; then HEALTH_STATUS="Healthy"; echo -e "${LGREEN}✅ /healthz reports healthy.${RESET}"; log_info "(Use '/readyz?verbose' for component details if available)";
    else
        # healthz failed or returned non-"ok", try componentstatuses (often deprecated/removed, but worth a try)
        log_warn "Could not fetch health via /readyz or /healthz. Checking componentstatuses (may be deprecated)...";
        if CS_OUTPUT=$(kubectl get componentstatuses --no-headers 2>/dev/null); then
            if echo "$CS_OUTPUT" | grep -vq 'Healthy'; then # Check if any line is not Healthy
                 HEALTH_STATUS="Unhealthy"; echo -e "${LRED}${BOLD}❌ Componentstatuses report unhealthy:${RESET}"; echo "$CS_OUTPUT" | grep -v 'Healthy' | sed 's/^/  /';
            elif echo "$CS_OUTPUT" | grep -q 'Healthy'; then # Check if at least one healthy component was found
                 HEALTH_STATUS="Healthy"; echo -e "${LGREEN}✅ Componentstatuses report healthy.${RESET}";
            else # Command succeeded but returned no lines (e.g., API disabled)
                 log_warn "Got empty response from componentstatuses. Health status remains Unknown.";
            fi
        else log_warn "Cannot get componentstatuses API. Health check inconclusive."; fi
    fi
fi

# --- Core Addon Status ---
print_header "Core Addon Status"

# CoreDNS Check (kube-system namespace assumed)
print_subheader "CoreDNS"
# Try Deployment first (common) then DaemonSet (less common)
DNS_READY=0; DNS_TOTAL=0; DNS_TYPE="Deployment"; DNS_STATUS="N/A"
if kubectl get deployment coredns -n kube-system -o jsonpath='{.status.readyReplicas}/{.status.replicas}' > /dev/null 2>&1; then
    DNS_STATUS=$(kubectl get deployment coredns -n kube-system -o jsonpath='{.status.readyReplicas}/{.status.replicas}' 2>/dev/null)
elif kubectl get daemonset coredns -n kube-system -o jsonpath='{.status.numberReady}/{.status.desiredNumberScheduled}' > /dev/null 2>&1; then
    DNS_TYPE="DaemonSet"
    DNS_STATUS=$(kubectl get daemonset coredns -n kube-system -o jsonpath='{.status.numberReady}/{.status.desiredNumberScheduled}' 2>/dev/null)
else
    DNS_STATUS="N/A (Not Found)"
fi

if [[ "$DNS_STATUS" =~ ^[0-9]+/[0-9]+$ ]]; then # Check format is "X/Y"
    DNS_READY=$(echo "$DNS_STATUS" | cut -d'/' -f1)
    DNS_TOTAL=$(echo "$DNS_STATUS" | cut -d'/' -f2)
    if [[ "$DNS_READY" -gt 0 ]] && [[ "$DNS_READY" -eq "$DNS_TOTAL" ]]; then
        echo -e " ${LGREEN}✅ CoreDNS ${DNS_TYPE} ready (${DNS_STATUS} replicas/pods).${RESET}";
    else
        echo -e " ${LRED}❌ CoreDNS ${DNS_TYPE} status: ${DNS_STATUS} ready${RESET}";
        kubectl get pods -n kube-system -l k8s-app=kube-dns --no-headers 2>/dev/null | awk '{printf "   Pod: %-40s Status: %-10s Restarts: %s\n", $1, $3, $4}';
    fi
elif [[ "$DNS_STATUS" == "N/A (Not Found)" ]]; then
     log_warn "CoreDNS Deployment/DaemonSet not found in kube-system namespace."
else
     log_warn "Could not parse CoreDNS status: ${DNS_STATUS}"
fi


# CNI Check (Example: Calico in kube-system or calico-system)
# Adapt the namespace and labels/names if using a different CNI (Flannel, Cilium, etc.)
print_subheader "CNI (Calico Example)"
CALICO_NS="kube-system" # Default, try calico-system if not found
if ! kubectl get namespace "$CALICO_NS" > /dev/null 2>&1; then
    if kubectl get namespace "calico-system" > /dev/null 2>&1; then
        CALICO_NS="calico-system"
        log_info "Detected Calico components in 'calico-system' namespace."
    elif kubectl get namespace "tigera-operator" > /dev/null 2>&1; then
         # If using Tigera Operator, resources might be in tigera-operator or managed differently
         log_info "Detected 'tigera-operator' namespace. Calico health might be managed by the operator."
         # Attempt checks in tigera-operator as a guess, might need adjustment
         CALICO_NS="tigera-operator" # Adjust if operator manages resources elsewhere
         # Note: A better check might involve checking the Operator's status itself
    else
        log_warn "Neither 'kube-system' nor 'calico-system' found. Skipping Calico check or adapt script for your CNI setup."
        CALICO_NS="" # Ensure skip below
    fi
fi

if [[ -n "$CALICO_NS" ]]; then
    # Check calico-node DaemonSet
    CALICO_NODE_STATUS=$(kubectl get daemonset calico-node -n "$CALICO_NS" -o jsonpath='{.status.numberReady}/{.status.desiredNumberScheduled}' 2>/dev/null || echo "N/A")
    CALICO_NODE_READY=0; CALICO_NODE_DESIRED=0
    if [[ "$CALICO_NODE_STATUS" =~ ^[0-9]+/[0-9]+$ ]]; then
        CALICO_NODE_READY=$(echo "$CALICO_NODE_STATUS" | cut -d'/' -f1)
        CALICO_NODE_DESIRED=$(echo "$CALICO_NODE_STATUS" | cut -d'/' -f2)
    elif [[ "$CALICO_NODE_STATUS" == "N/A" ]]; then
         log_warn "Calico DaemonSet 'calico-node' not found in namespace '${CALICO_NS}'."
    fi

    # Check calico-kube-controllers Deployment
    CALICO_CTRL_STATUS=$(kubectl get deployment calico-kube-controllers -n "$CALICO_NS" -o jsonpath='{.status.readyReplicas}/{.status.replicas}' 2>/dev/null || echo "N/A")
    CALICO_CTRL_READY=0; CALICO_CTRL_TOTAL=0
    if [[ "$CALICO_CTRL_STATUS" =~ ^[0-9]+/[0-9]+$ ]]; then
        CALICO_CTRL_READY=$(echo "$CALICO_CTRL_STATUS" | cut -d'/' -f1)
        CALICO_CTRL_TOTAL=$(echo "$CALICO_CTRL_STATUS" | cut -d'/' -f2)
    elif [[ "$CALICO_CTRL_STATUS" == "N/A" ]]; then
        log_warn "Calico Deployment 'calico-kube-controllers' not found in namespace '${CALICO_NS}'."
    fi

    # Assess overall Calico health based on checks
    CALICO_OK=true
    [[ "$CALICO_NODE_STATUS" == "N/A" && "$CALICO_CTRL_STATUS" == "N/A" ]] && CALICO_OK=false # Both missing
    # Consider healthy if at least one component is found and healthy, or if both are found and healthy
    NODE_HEALTHY=false; CTRL_HEALTHY=false
    [[ "$CALICO_NODE_DESIRED" -gt 0 && "$CALICO_NODE_READY" -eq "$CALICO_NODE_DESIRED" ]] && NODE_HEALTHY=true
    [[ "$CALICO_CTRL_TOTAL" -gt 0 && "$CALICO_CTRL_READY" -eq "$CALICO_CTRL_TOTAL" ]] && CTRL_HEALTHY=true

    # Report based on findings
    if [[ "$CALICO_NODE_STATUS" != "N/A" || "$CALICO_CTRL_STATUS" != "N/A" ]]; then # Only report if something was found
        if ($NODE_HEALTHY || [[ "$CALICO_NODE_STATUS" == "N/A" ]]) && ($CTRL_HEALTHY || [[ "$CALICO_CTRL_STATUS" == "N/A" ]]); then
             echo -e " ${LGREEN}✅ Calico components appear healthy (Nodes: ${CALICO_NODE_STATUS:-Not Found}, Controllers: ${CALICO_CTRL_STATUS:-Not Found}).${RESET}";
        else
            echo -e " ${LRED}❌ Calico status issues detected in namespace '${CALICO_NS}':${RESET}";
            [[ "$CALICO_NODE_STATUS" != "N/A" ]] && echo -e "   DaemonSet 'calico-node': ${CALICO_NODE_STATUS} Ready/Desired"
            [[ "$CALICO_CTRL_STATUS" != "N/A" ]] && echo -e "   Deployment 'calico-kube-controllers': ${CALICO_CTRL_STATUS} Ready/Total"
            # Show problem pods only if issues detected
            kubectl get pods -n "$CALICO_NS" -l 'k8s-app in (calico-node, calico-kube-controllers)' --field-selector=status.phase!=Running,status.phase!=Succeeded --no-headers 2>/dev/null | awk '{printf "   Problem Pod: %-40s Status: %-10s\n", $1, $3}';
        fi
    fi # End if something was found
fi # End if Calico namespace exists

# --- Application Namespace Overview ---
print_header "Application Namespace Overview"
ALL_NAMESPACES=$(kubectl get ns -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)
APPS_FOUND_COUNT=0
if [ -z "$ALL_NAMESPACES" ]; then log_warn "Failed to retrieve namespaces."; else
    printf " ${BOLD}%-30s %-10s %-10s %-10s %-10s %-15s${RESET}\n" "NAMESPACE" "RUNNING" "PENDING" "FAILED" "SUCCEEDED" "DEPLOYMENTS"
    # Process namespaces; use process substitution to avoid losing APPS_FOUND_COUNT in subshell
    while IFS= read -r ns; do
        exclude=false; for excluded_ns in "${EXCLUDE_NAMESPACES[@]}"; do [[ "$ns" == "$excluded_ns" ]] && exclude=true && break; done; if $exclude; then continue; fi
        ((APPS_FOUND_COUNT++))

        # Get pod statuses for the namespace
        pod_statuses=$(kubectl get pods -n "$ns" --no-headers -o custom-columns=STATUS:.status.phase 2>/dev/null)

        # **FIXED**: Get counts, remove potential trailing newline from grep -c, default to 0
        running_pods=$(echo "$pod_statuses" | grep -cw "Running" | tr -d '\n')
        running_pods=${running_pods:-0}

        pending_pods=$(echo "$pod_statuses" | grep -cw "Pending" | tr -d '\n')
        pending_pods=${pending_pods:-0}

        failed_pods=$(echo "$pod_statuses" | grep -cw "Failed" | tr -d '\n')
        failed_pods=${failed_pods:-0}

        succeeded_pods=$(echo "$pod_statuses" | grep -cw "Succeeded" | tr -d '\n')
        succeeded_pods=${succeeded_pods:-0}

        # Get deployment status (Ready/Total), default to "0/0"
        deploy_status_raw=$(kubectl get deployments -n "$ns" --no-headers 2>/dev/null | awk '
            BEGIN { ready=0; total=0 } # Initialize counters
            {
                split($2, rep, "/"); # $2 is the READY column like "1/1"
                # Check if both parts look like numbers before adding
                if (rep[1] ~ /^[0-9]+$/ && rep[2] ~ /^[0-9]+$/) {
                    ready += rep[1];
                    total += rep[2];
                }
            }
            END {
                # Print the sum if any deployments were processed (NR>0), else print 0/0
                # Use printf to avoid trailing newline from print
                if (NR > 0) printf "%d/%d", ready, total; else printf "0/0";
            }' || echo "0/0") # Ensure output even if awk/kubectl fails

        # **FIXED**: Clean and parse deployment status robustly
        # Remove ALL whitespace (including potential newlines) from the status string
        deploy_status=$(echo "$deploy_status_raw" | tr -d '[:space:]')

        # Parse the cleaned status string
        ready_deps=$(echo "$deploy_status" | cut -d'/' -f1)
        total_deps=$(echo "$deploy_status" | cut -d'/' -f2)

        # Ensure values are numeric before arithmetic; default to 0 if not
        [[ ! "$ready_deps" =~ ^[0-9]+$ ]] && ready_deps=0
        [[ ! "$total_deps" =~ ^[0-9]+$ ]] && total_deps=0

        # Determine namespace color based on pod status
        ns_color="${GREEN}"; [[ "$pending_pods" -gt 0 ]] && ns_color="${YELLOW}"; [[ "$failed_pods" -gt 0 ]] && ns_color="${RED}"

        # Determine deployment status color using safe numeric comparisons
        dep_status_color="${GREEN}";
        if [[ "$total_deps" -eq 0 ]]; then
             dep_status_color="${LGRAY}" # Gray for 0/0 deployments
        elif [[ "$ready_deps" -lt "$total_deps" ]]; then
             dep_status_color="${YELLOW}" # Yellow if not all deployments are ready
        fi

        # Print the formatted line for the namespace
        # Use the original $deploy_status for display 'X/Y', not the cleaned numeric variables
        printf " ${ns_color}%-30s${RESET} %-10s %-10s %-10s %-10s ${dep_status_color}%-15s${RESET}\n" \
               "$ns" "$running_pods" "$pending_pods" "$failed_pods" "$succeeded_pods" "$deploy_status"
    done < <(echo "$ALL_NAMESPACES") # Use process substitution to read namespaces
fi

# Check the counter *after* the loop finishes
if [[ $APPS_FOUND_COUNT -eq 0 ]]; then
    log_info "No application namespaces found (excluding system namespaces like ${EXCLUDE_NAMESPACES[*]})."
fi

# Check the counter *after* the loop finishes
if [[ $APPS_FOUND_COUNT -eq 0 ]]; then
    log_info "No application namespaces found (excluding system namespaces like ${EXCLUDE_NAMESPACES[*]})."
fi

# --- Resource Usage Summary (Cluster Wide - Nodes) ---
if $METRICS_AVAILABLE; then
    print_header "Cluster Resource Usage (Nodes)"
    # Use awk to process kubectl top nodes output
    TOP_NODES_OUTPUT=$(kubectl top nodes --no-headers 2>/dev/null)
    if [[ -n "$TOP_NODES_OUTPUT" ]]; then
        echo "$TOP_NODES_OUTPUT" | awk '
        BEGIN { t_cpu=0; t_mem=0; n=0 }
        {
            # CPU processing: remove 'm' suffix
            cpu=$2; sub(/m$/,"",cpu); t_cpu+=cpu;

            # Memory processing: convert Gi/Ki to Mi
            mem=$4; unit="Mi"; # Default unit
            if(match(mem,/Gi/)){ mem_val=substr(mem, 1, RLENGTH-2); mem=mem_val*1024; }
            else if(match(mem,/Ki/)){ mem_val=substr(mem, 1, RLENGTH-2); mem=mem_val/1024; }
            else { sub(/Mi/,"",mem); } # Assume Mi if no Gi/Ki suffix
            t_mem+=mem;
            n++; # Count nodes processed
        }
        END {
            if(n>0){
                printf " ${BOLD}%-20s %-15s %-15s${RESET}\n","RESOURCE","TOTAL USAGE","AVG PER NODE";
                # Format CPU with 'm' suffix
                printf " %-20s %-15s %-15s\n","CPU (Cores)", t_cpu "m", int(t_cpu/n) "m";
                # Format Memory, convert total back to GiB if large enough for readability
                if (t_mem > 2048) { t_mem_disp = sprintf("%.1f GiB", t_mem/1024); avg_mem_disp = sprintf("%.1f MiB", t_mem/n) } # Show total GiB, avg MiB
                else { t_mem_disp = int(t_mem) " MiB"; avg_mem_disp = int(t_mem/n) " MiB" } # Show both MiB
                printf " %-20s %-15s %-15s\n","Memory", t_mem_disp, avg_mem_disp;
            } else { print "  No node metrics available (kubectl top nodes returned no processable data)."; }
        }'
    else
        log_warn "kubectl top nodes returned no data, cannot calculate cluster resource usage."
    fi
else
    print_header "Cluster Resource Usage (Nodes)"; log_info "Skipped. Install metrics-server for node resource usage."
fi

# --- Recent Events ---
print_header "Recent Warning/Error Events (Last 10)"
# Define columns for events
EVENT_COLS="LAST_SEEN:.lastTimestamp,TYPE:.type,REASON:.reason,NAMESPACE:.metadata.namespace,OBJECT:.involvedObject.kind/.involvedObject.name,MESSAGE:.message"
# Get last 10 non-Normal events across all namespaces, sorted by time
# Using sort-by='.metadata.creationTimestamp' might be slightly more reliable than lastTimestamp sometimes
EVENTS=$(kubectl get events --sort-by='.lastTimestamp' --field-selector type!=Normal -A -o custom-columns="${EVENT_COLS}" --no-headers 2>/dev/null | tail -n 10)

if [ -n "$EVENTS" ]; then
    printf " ${BOLD}%-26s %-10s %-18s %-20s %-30s %s${RESET}\n" "LAST_SEEN" "TYPE" "REASON" "NAMESPACE" "OBJECT" "MESSAGE"
    echo "$EVENTS" | while IFS= read -r line; do
        # Extract fields using awk, message is the rest of the line
        last_seen=$(echo "$line" | awk '{print $1}')
        type=$(echo "$line" | awk '{print $2}')
        reason=$(echo "$line" | awk '{print $3}')
        namespace=$(echo "$line" | awk '{print $4}')
        object=$(echo "$line" | awk '{print $5}')
        # **FIXED**: Simpler message extraction
        message=$(echo "$line" | awk '{ $1=$2=$3=$4=$5=""; print $0 }' | sed 's/^[ \t]*//')

        # Determine color based on Type or Reason
        color="${YELLOW}"; # Default to Warning color
        if [[ "$type" == *"Error"* || "$reason" == *"Failed"* || "$reason" == *"Error"* || "$reason" == *"Unhealthy"* ]]; then
            color="${LRED}"; # Use Error color for more severe events
        fi

        # Truncate message if too long for display cleanly
        if [ ${#message} -gt 80 ]; then message="${message:0:77}..."; fi
        # Truncate object name if needed (printf %.30s handles this too)
        # if [ ${#object} -gt 30 ]; then object="${object:0:27}..."; fi

        # Use printf for formatted output
        # Using %b for the fields with color codes to interpret escapes (might help alignment slightly)
        printf " ${color}%-26s %-10s %-18s %-20s %-30.30s %s${RESET}\n" \
               "$last_seen" "$type" "$reason" "$namespace" "$object" "$message"
    done
else
    log_info "No recent Warning or Error events found."
fi

echo -e "\n${BLUE}${BOLD}=== Monitoring Complete (`date`) ===${RESET}"
exit 0
