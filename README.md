# Kubernetes Homelab Scripts 🛠️ (k8s)

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![GitHub last commit](https://img.shields.io/github/last-commit/fabriziosalmi/k8s.svg)](https://github.com/fabriziosalmi/k8s/commits/main)

Welcome! This repository (`fabriziosalmi/k8s`) hosts a suite of Bash scripts meticulously crafted to simplify the setup, management, and monitoring of a single-node Kubernetes cluster. Ideal for homelab enthusiasts, testing environments, or anyone looking to quickly bootstrap a K8s instance. 

> [!WARNING]
> You will be up & running in less than 2 minutes 🚀

---

## ✨ Overview

These scripts aim to automate common, often repetitive, tasks involved in running a Kubernetes cluster and self-hosted applications:

*   🚀 **[`install.sh`](install.sh):** Your starting point! Automates the setup of a Kubernetes `v1.29.0` cluster (configurable) on a single Debian/Ubuntu node using `kubeadm`. Handles prerequisites, container runtime (`containerd`), core components, networking (Calico), and optional extras like the Kubernetes Dashboard and a Caddy example.
*   ⚙️ **[`manage.sh`](manage.sh):** An interactive application manager. Deploy or uninstall a curated list of popular self-hosted applications (Portainer, Nextcloud, Gitea, etc.) with basic `hostPath` persistence. Perfect for quick demos or simple single-node setups.
*   📊 **[`monitor.sh`](monitor.sh):** A command-line dashboard providing a real-time health check and status overview of your cluster. See node status, resource usage (requires Metrics Server), control plane health, core addons, application summaries, and recent events at a glance.

---

## 📋 Prerequisites

Before diving in, ensure your environment meets these requirements:

1.  **🐧 Operating System:** Debian or Ubuntu-based Linux distribution (tested on Ubuntu). Scripts use `apt-get`.
2.  **💻 Architecture:** Primarily designed for `amd64`. Manifests (like Calico) might need adjustment for other architectures (e.g., ARM).
3.  **🔑 Root Access:**
    *   `install.sh` **must** be run via `sudo`.
    *   `manage.sh` needs permissions to create directories under `/srv/k8s-apps-data` (default). Run as root (`sudo`) or adjust permissions on this path beforehand.
4.  **🌐 Internet Connection:** Required by `install.sh` for downloading packages and manifests.
5.  **💪 System Resources:** Adequate CPU (2+ cores recommended), RAM (4GB+ recommended), and disk space for Kubernetes and your desired applications.
6.  **🐚 Bash:** Version 4 or later (uses `mapfile`/`readarray`). Check with `bash --version`.
7.  **🛠️ Required Tools:**
    *   Standard GNU/Linux utilities: `curl`, `gpg`, `awk`, `sed`, `grep`, `sort`, `head`, `tail`, `wc`, `cut`, `printf`, `date`, `id`, `tee`, `modprobe`, `sysctl`, `systemctl`, `dpkg-query`, `apt-get`, `apt-mark`, `hostname`.
    *   `jq`: **Highly recommended** for reliable JSON parsing (`install.sh`, `monitor.sh`). Scripts have fallbacks but `jq` is preferred. Install via `sudo apt-get update && sudo apt-get install -y jq`.
8.  **☸️ `kubectl`:** The Kubernetes command-line tool. `install.sh` handles its installation. For `manage.sh` and `monitor.sh`, ensure `kubectl` is installed and configured (`~/.kube/config` or `KUBECONFIG` env var) to connect to your cluster. Verify with `kubectl cluster-info`.
9.  **(Optional) Metrics Server:** Needed by `monitor.sh` to show Node Resource Usage. If not detected, `monitor.sh` will provide installation instructions.

---

## 🚀 Script Details

### 1. `install.sh` - Cluster Installation

This script bootstraps your single-node Kubernetes cluster.

**Key Features:**

*   ✅ System checks and preparation (swap, kernel modules, sysctl).
*   📦 Installs `containerd` runtime.
*   ⚙️ Installs specific, configurable versions of `kubelet`, `kubeadm`, `kubectl`.
*   🔄 Detects existing installations and offers safe options (reset, modify, exit).
*   ☸️ Initializes the cluster via `kubeadm init`.
*   🔑 Configures `kubectl` access for root and provides instructions for regular users.
*   🌐 Installs Calico CNI for cluster networking.
*   🎯 Untaints the control-plane node for workload scheduling (single-node focus).
*   **(Optional)** Installs Kubernetes Dashboard & Caddy example.
*   **(Optional)** Creates Dashboard admin user & provides access token.
*   **(Optional)** Configures NodePort access for Dashboard/Caddy.

**Configuration (`install.sh` Top Section):**

| Variable                | Default      | Description                                                              |
| :---------------------- | :----------- | :----------------------------------------------------------------------- |
| `K8S_VERSION`           | `1.29.0`     | Kubernetes version to install.                                           |
| `CALICO_VERSION`        | `v3.27.2`    | Calico CNI version to install.                                           |
| `DASHBOARD_VERSION`     | `v2.7.0`     | Kubernetes Dashboard version.                                            |
| `INSTALL_DASHBOARD`     | `true`       | Set to `false` to skip Dashboard installation.                           |
| `INSTALL_CADDY`         | `true`       | Set to `false` to skip the Caddy example deployment.                     |
| `DASHBOARD_SERVICE_TYPE`| `NodePort`   | Set to `ClusterIP` to only expose Dashboard within the cluster (use `kubectl proxy`). |

**Usage:**

```bash
# 1. Make the script executable
chmod +x install.sh

# 2. Run as root
sudo ./install.sh
```

⚠️ **Important:** Read the prompts carefully, especially if an existing installation is detected. The `reset` option is **DESTRUCTIVE** to existing cluster configurations on the node. Review the script code before execution.

### 2. `manage.sh` - Application Management

Deploy and manage common self-hosted applications interactively.

**Key Features:**

*   ✨ Interactive Install/Uninstall menu.
*   📚 Manages apps like: Portainer, Nextcloud, Gitea, Vaultwarden, Uptime Kuma, Jellyfin, Home Assistant, File Browser.
*   📦 Creates necessary Kubernetes resources (Namespace, Deployment, Service, PV, PVC).
*   🔗 Provides NodePort access URLs upon successful installation.
*   🗑️ Uninstall mode detects managed apps and allows selective removal.
*   ❓ Prompts for confirmation before deleting K8s resources and host data.

**💾 WARNING - Storage Limitation:**

> This script utilizes **`hostPath` PersistentVolumes** by default, storing data directly on the node's filesystem (typically under `/srv/k8s-apps-data/<namespace>/`).
>
> *   🚨 **INSECURE:** Permissions can be problematic, and data is not isolated.
> *   🔒 **NODE LOCK-IN:** Data is tied to this specific node and won't migrate.
> *   💥 **NOT FOR PRODUCTION:** Lacks features of proper storage solutions (snapshots, dynamic provisioning, etc.).
>
> This approach is chosen for **simplicity in a single-node homelab/testing setup ONLY**. For anything more serious, implement a proper StorageClass (e.g., `local-path-provisioner`, NFS, Ceph, cloud provider storage).

**Configuration (`manage.sh` Top Section):**

*   `HOST_DATA_BASE_DIR`: Change the base path on the host node where application data directories will be created. Default: `/srv/k8s-apps-data`.

**Usage:**

1.  Ensure `kubectl` is configured and can connect to your cluster.
2.  Ensure the user running the script has write permissions to `HOST_DATA_BASE_DIR` **or** run the script with `sudo`.

```bash
# 1. Make the script executable
chmod +x manage.sh

# 2. Run the script
# If HOST_DATA_BASE_DIR requires root:
sudo ./manage.sh
# Otherwise:
./manage.sh
```

Follow the on-screen menus. Be **extremely careful** during the uninstall process, especially when asked about deleting host data, as this action is **irreversible**.

### 3. `monitor.sh` - Cluster Monitoring Dashboard

Get a quick, comprehensive status overview of your cluster directly in the terminal.

**Key Features:**

*   ℹ️ **Cluster Info:** API endpoint, K8s server version.
*   💻 **Node Status:** Detailed list including readiness, roles, IPs, OS, Kubelet version.
*   **(Optional) 📈 Resource Usage:** Node CPU & Memory utilization summary (requires Metrics Server).
*   ❤️ **Control Plane Health:** Checks crucial health endpoints (`/readyz`, `/healthz`).
*   🔌 **Core Addons:** Status checks for CoreDNS and Calico.
*   📦 **Application Overview:** Pod counts (Running, Pending, Failed, Succeeded) and Deployment readiness per non-system namespace.
*   ⚠️ **Recent Events:** Lists the latest Warning/Error events cluster-wide.
*   🎨 Color-coded output for quick identification of potential issues.

**Configuration (`monitor.sh` Top Section):**

*   `EXCLUDE_NAMESPACES`: An array of namespaces (e.g., `"kube-system"`, `"calico-system"`) to hide from the "Application Namespace Overview" section. Add any other system/infra namespaces here.

**Usage:**

1.  Ensure `kubectl` is configured and can connect to your cluster.

```bash
# 1. Make the script executable
chmod +x monitor.sh

# 2. Run the script
./monitor.sh
```

---

## 📜 Disclaimer

These scripts are powerful tools provided **as-is** for educational and homelab purposes. They modify system configurations, manage packages, interact with Kubernetes, and potentially delete data.

*   🛑 **REVIEW THE CODE:** Understand what each script does before running it.
*   ⚠️ **USE WITH CAUTION:** Especially destructive options like `kubeadm reset` or data deletion during uninstalls.
*   💾 **BACKUP:** Always back up critical data before performing major operations.
*   🚫 **NOT PRODUCTION-READY:** The storage approach in `manage.sh` (`hostPath`) is unsuitable for production.
*   ❓ **NO WARRANTY:** The author provides no guarantees and is not responsible for any damage or data loss resulting from the use of these scripts.

---

## 💡 Future Improvements (TODO)

*   Add more applications to `manage.sh`.
*   Integrate `local-path-provisioner` as an optional, more robust storage solution in `install.sh` and `manage.sh`.
*   Support for other CNIs (e.g., Flannel, Cilium) in `install.sh`.
*   Parameterize more options via command-line arguments instead of editing scripts.
*   Improve error handling and reporting.
*   Add basic backup/restore helpers to `manage.sh`.

---

## 🤝 Contributing

Contributions, suggestions, and bug reports are welcome! Please feel free to open an Issue or Pull Request on the [GitHub repository](https://github.com/fabriziosalmi/k8s).

---

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details (assuming you add an MIT license file).
