# Proxmox K0s Lab

IaC for a K0s Kubernetes cluster on Proxmox VE 8.4.

## Architecture

- **Host:** Ryzen 7 5800U, 64GB RAM, 512GB NVMe
- **Network:** Isolated 10.0.33.0/24 with NAT to upstream
- **Cluster:** 1 controller + 2 workers on Debian 12

## Scripts

| Script | Purpose |
|--------|---------|
| `debian12-template.sh` | Create Debian 12 cloud-init VM template |
| `net-snat-bridge.sh` | Create isolated bridge (vmbr1) with NAT |
| `k0s-cluster-vms.sh` | Provision 3 K0s node VMs |
| `k0s-install.sh` | Bootstrap K0s cluster via k0sctl |
| `k0s-flat.sh` | Test VM on flat network (optional) |

## Usage

```bash
# 1. Create template (once)
bash debian12-template.sh

# 2. Create isolated network
bash net-snat-bridge.sh create

# 3. Provision VMs
bash k0s-cluster-vms.sh create

# 4. Install K0s
bash k0s-install.sh install

# 5. Access cluster
export KUBECONFIG=$(pwd)/kubeconfig
kubectl config view
kubectl get no
kubectl get po -A

```

## Teardown

```bash
bash k0s-install.sh reset
bash k0s-cluster-vms.sh destroy
bash net-snat-bridge.sh destroy
```

---

