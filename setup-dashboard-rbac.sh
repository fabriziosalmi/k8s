#!/bin/bash

# Kubernetes Dashboard RBAC Configuration
# This creates a more restrictive role for the dashboard instead of cluster-admin

# Create a custom ClusterRole with minimal required permissions for dashboard viewing
cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: dashboard-viewer
rules:
# Basic read access to common resources
- apiGroups: [""]
  resources: ["nodes", "pods", "services", "endpoints", "persistentvolumes", "persistentvolumeclaims", "configmaps", "secrets", "namespaces"]
  verbs: ["get", "list", "watch"]
- apiGroups: [""]
  resources: ["pods/log", "pods/status"]
  verbs: ["get", "list"]
# Apps API group
- apiGroups: ["apps"]
  resources: ["deployments", "replicasets", "daemonsets", "statefulsets"]
  verbs: ["get", "list", "watch"]
# Extensions API group
- apiGroups: ["extensions"]
  resources: ["deployments", "replicasets", "ingresses"]
  verbs: ["get", "list", "watch"]
# Networking API group
- apiGroups: ["networking.k8s.io"]
  resources: ["ingresses", "networkpolicies"]
  verbs: ["get", "list", "watch"]
# Storage API group
- apiGroups: ["storage.k8s.io"]
  resources: ["storageclasses", "volumeattachments"]
  verbs: ["get", "list", "watch"]
# Metrics API group
- apiGroups: ["metrics.k8s.io"]
  resources: ["pods", "nodes"]
  verbs: ["get", "list"]
# Batch API group
- apiGroups: ["batch"]
  resources: ["jobs", "cronjobs"]
  verbs: ["get", "list", "watch"]
# RBAC API group (read-only)
- apiGroups: ["rbac.authorization.k8s.io"]
  resources: ["roles", "rolebindings", "clusterroles", "clusterrolebindings"]
  verbs: ["get", "list", "watch"]
# Event access
- apiGroups: [""]
  resources: ["events"]
  verbs: ["get", "list", "watch"]
EOF

echo "✅ Created dashboard-viewer ClusterRole with minimal required permissions"
