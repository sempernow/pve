#!/usr/bin/env bash
set -e

# === k0s-install.sh - Install K0s cluster using k0sctl ===
###########################################################
# This script does the following:
# - Install k0sctl on pve
# - Generate cluster config
# - SSH into each node, install k0s
# - Bootstrap the cluster
# - Fetch kubeconfig
###########################################################

K0SCTL_BIN=k0sctl-linux-amd64
K0SCTL_VER=v0.28.0
#K0S_VER='v1.34.2+k0s.0' # Don't declare
K0SCTL_URL=https://github.com/k0sproject/k0sctl/releases/download/$K0SCTL_VER/$K0SCTL_BIN
CLUSTER_NAME="k0s-lab"
K0SCTL_CONFIG="k0sctl.yaml"
SSH_USER="k0s"
SSH_KEY="~/.ssh/id_ed25519"

CONTROLLER="10.0.33.11"
WORKERS="10.0.33.12 10.0.33.13"

# --- Install k0sctl if missing ---
install_k0sctl() {
    if command -v k0sctl &>/dev/null; then
        echo "ℹ️ k0sctl already installed: $(k0sctl version)"
        return
    fi

    echo "🚧 Installing k0sctl..."
    wget $K0SCTL_URL &&
		install $K0SCTL_BIN /usr/local/bin/k0sctl &&
			rm -f $K0SCTL_BIN || {
    			echo "⚠️  Download failed."
				return 11
			}
}

# --- Generate k0sctl.yaml ---
generate_config() {
    echo "🚧 Generating $K0SCTL_CONFIG..."
    tee "$K0SCTL_CONFIG" <<-EOF
	apiVersion: k0sctl.k0sproject.io/v1beta1
	kind: Cluster
	metadata:
	  name: $CLUSTER_NAME
	spec:
	  #k0s:
	    #version: $K0S_VER
	  hosts:
	    - role: controller+worker
	      ssh:
	        address: $CONTROLLER
	        user: $SSH_USER
	        keyPath: $SSH_KEY
	      installFlags:
	        - --disable-components=metrics-server
	    - role: worker
	      ssh:
	        address: $(echo $WORKERS | awk '{print $1}')
	        user: $SSH_USER
	        keyPath: $SSH_KEY
	    - role: worker
	      ssh:
	        address: $(echo $WORKERS | awk '{print $2}')
	        user: $SSH_USER
	        keyPath: $SSH_KEY
	EOF
    echo "ℹ️ Config written to $K0SCTL_CONFIG"
}

# --- Main ---
case "${1:-install}" in
    install)
        install_k0sctl || exit $?
        generate_config
        echo ""
        echo "🚧 Applying cluster configuration..."
        k0sctl apply --config "$K0SCTL_CONFIG"
        echo ""
        echo "🚧 Fetching kubeconfig..."
        k0sctl kubeconfig --config "$K0SCTL_CONFIG" > kubeconfig
        echo "ℹ️ Kubeconfig written to ./kubeconfig"
        echo ""
        echo "ℹ️ Test with:"
        echo "  export KUBECONFIG=\$(pwd)/kubeconfig"
        echo "  kubectl get nodes"
        ;;
    kubeconfig)
        k0sctl kubeconfig --config "$K0SCTL_CONFIG"
        ;;
    reset)
        echo "🚧 Resetting cluster (removes k0s from all nodes)..."
        k0sctl reset --config "$K0SCTL_CONFIG"
        rm -f kubeconfig
        ;;
    status)
        export KUBECONFIG="$(pwd)/kubeconfig"
        kubectl get nodes -o wide
        ;;
    *)
        echo "ℹ️ Usage: $0 {install|kubeconfig|reset|status}"
        exit 1
        ;;
esac