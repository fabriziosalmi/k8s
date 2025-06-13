#!/bin/bash

# Script to check system compatibility for k8s management scripts
# Ensures all prerequisites are met before running the main scripts

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
log_error() { echo -e "${RED}${BOLD}❌ ERROR:${RESET}${RED} $1${RESET}"; }
success_msg() { echo -e "${GREEN}✅ SUCCESS:${RESET} $1"; }

check_bash_version() {
    local required_major=4
    local bash_version
    local bash_major
    
    if [[ -n "${BASH_VERSION:-}" ]]; then
        bash_version="$BASH_VERSION"
        bash_major="${bash_version%%.*}"
        
        log_info "Detected Bash version: $bash_version"
        
        if [[ "$bash_major" -ge "$required_major" ]]; then
            success_msg "Bash version is compatible (>= 4.0)"
            return 0
        else
            log_error "Bash version $bash_version is too old. Required: >= 4.0"
            log_error "The manage.sh script uses 'mapfile' which requires Bash 4+"
            return 1
        fi
    else
        log_error "Could not determine Bash version"
        return 1
    fi
}

check_required_commands() {
    local commands=(
        "curl" "gpg" "awk" "sed" "grep" "sort" "head" "tail" "wc" "cut" 
        "printf" "date" "id" "tee" "modprobe" "sysctl" "systemctl" 
        "dpkg-query" "apt-get" "apt-mark" "hostname" "swapoff"
    )
    
    local missing_commands=()
    
    log_info "Checking required system commands..."
    
    for cmd in "${commands[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_commands+=("$cmd")
        fi
    done
    
    if [[ ${#missing_commands[@]} -eq 0 ]]; then
        success_msg "All required system commands are available"
        return 0
    else
        log_error "Missing required commands: ${missing_commands[*]}"
        log_error "Please install the missing commands before proceeding"
        return 1
    fi
}

check_optional_commands() {
    local commands=("jq" "ufw")
    
    log_info "Checking optional commands..."
    
    for cmd in "${commands[@]}"; do
        if command -v "$cmd" &> /dev/null; then
            success_msg "$cmd is available"
        else
            log_warn "$cmd is not installed but optional"
            case "$cmd" in
                "jq")
                    echo "  Install with: sudo apt-get update && sudo apt-get install -y jq"
                    echo "  Used for: Better JSON parsing in scripts"
                    ;;
                "ufw")
                    echo "  Install with: sudo apt-get update && sudo apt-get install -y ufw"
                    echo "  Used for: Automatic firewall rule setup"
                    ;;
            esac
        fi
    done
}

check_os_compatibility() {
    log_info "Checking OS compatibility..."
    
    if [[ ! -f /etc/os-release ]]; then
        log_error "Cannot determine OS. /etc/os-release not found"
        return 1
    fi
    
    source /etc/os-release
    
    case "$ID" in
        "ubuntu"|"debian")
            success_msg "OS is compatible: $PRETTY_NAME"
            return 0
            ;;
        *)
            log_warn "OS may not be fully compatible: $PRETTY_NAME"
            log_warn "Scripts are designed for Debian/Ubuntu systems"
            return 1
            ;;
    esac
}

check_root_access() {
    log_info "Checking root access..."
    
    if [[ $EUID -eq 0 ]]; then
        success_msg "Running as root"
        return 0
    elif sudo -n true 2>/dev/null; then
        success_msg "Sudo access available"
        return 0
    else
        log_error "Root access or sudo required for system operations"
        log_error "Run with sudo or ensure your user has sudo privileges"
        return 1
    fi
}

check_system_resources() {
    log_info "Checking system resources..."
    
    # Check CPU cores
    local cpu_cores
    cpu_cores=$(nproc)
    if [[ "$cpu_cores" -ge 2 ]]; then
        success_msg "CPU cores: $cpu_cores (recommended: 2+)"
    else
        log_warn "CPU cores: $cpu_cores (recommended: 2+)"
    fi
    
    # Check memory
    local mem_gb
    mem_gb=$(awk '/MemTotal/ {printf "%.1f", $2/1024/1024}' /proc/meminfo)
    if (( $(echo "$mem_gb >= 4.0" | bc -l) )); then
        success_msg "Memory: ${mem_gb}GB (recommended: 4GB+)"
    else
        log_warn "Memory: ${mem_gb}GB (recommended: 4GB+)"
    fi
    
    # Check disk space
    local disk_gb
    disk_gb=$(df / | awk 'NR==2 {printf "%.1f", $4/1024/1024}')
    if (( $(echo "$disk_gb >= 20.0" | bc -l) )); then
        success_msg "Available disk space: ${disk_gb}GB (recommended: 20GB+)"
    else
        log_warn "Available disk space: ${disk_gb}GB (recommended: 20GB+)"
    fi
}

main() {
    echo -e "${CYAN}${BOLD}=== Kubernetes Scripts Compatibility Check ===${RESET}\n"
    
    local checks_passed=0
    local total_checks=5
    
    if check_bash_version; then ((checks_passed++)); fi
    echo
    
    if check_os_compatibility; then ((checks_passed++)); fi
    echo
    
    if check_root_access; then ((checks_passed++)); fi
    echo
    
    if check_required_commands; then ((checks_passed++)); fi
    echo
    
    check_optional_commands
    echo
    
    check_system_resources
    echo
    
    echo -e "${CYAN}${BOLD}=== Summary ===${RESET}"
    echo "Critical checks passed: $checks_passed/$total_checks"
    
    if [[ "$checks_passed" -eq "$total_checks" ]]; then
        success_msg "System is ready for Kubernetes script execution!"
        exit 0
    else
        log_error "Some critical checks failed. Please address the issues above."
        exit 1
    fi
}

# Check if bc is available for numeric comparisons
if ! command -v bc &> /dev/null; then
    log_warn "bc (calculator) not available. Installing for system resource checks..."
    if [[ $EUID -eq 0 ]] || sudo -n true 2>/dev/null; then
        apt-get update -qq && apt-get install -y bc &>/dev/null || log_warn "Could not install bc"
    fi
fi

main "$@"
