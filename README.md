## Microstack MAAS + Sunbeam Lab

Automated deployment of Canonical OpenStack (Sunbeam) on top of MAAS-managed
virtual machines, all running inside a single LXD container. Based on
[nobuto-m/quick-maas](https://github.com/nobuto-m/quick-maas/).

## Architecture

```
Bare metal host (64 GB RAM recommended)
└── LXD Container "microstack" (10.0.9.11)
    ├── MAAS 3.5 (region + rack controller)
    ├── libvirt/KVM
    │   ├── VM "compute-1" (16 vCPU, 48 GB, 2x100 GB, 7 NICs)
    │   │   └── control + compute + storage
    │   ├── VM "juju" (2 vCPU, 4 GB, 50 GB, 7 NICs)
    │   │   └── Juju controller
    │   └── VM "sunbeam" (2 vCPU, 4 GB, 50 GB, 7 NICs)
    │       └── Sunbeam infra (clusterd)
    └── Sunbeam client (openstack snap)
```

Total VM resources: 20 vCPUs, 56 GB RAM, 300 GB disk.

## Network Topology (7 bridges, 6 MAAS spaces)

Full traffic isolation using MAAS spaces. Each Sunbeam network gets its own
bridge, subnet, and MAAS space. The external network is an isolated L2 bridge
managed entirely by Neutron/OVS (not in MAAS).

```
Bridge      Subnet              MAAS Space             NIC     Purpose
─────────   ──────────────────  ─────────────────────  ──────  ────────────────────────
mgmt        192.168.151.0/24    space-management       enp1s0  Management
internal    192.168.152.0/24    space-internal         enp2s0  Internal API, AMQP
data        192.168.153.0/24    space-data             enp3s0  Migration, VM traffic
storage     192.168.154.0/24    space-storage          enp4s0  Ceph client access
stcluster   192.168.155.0/24    space-storage-cluster  enp5s0  Ceph replication
public      192.168.171.0/24    space-public           enp6s0  API endpoints (Traefik)
external    192.168.172.0/24    (none — Neutron only)  enp7s0  Floating IPs (provider net)
```

### IP Layout Per MAAS-Managed Subnet

| Range       | Purpose                                    |
|-------------|--------------------------------------------|
| `.1`        | Gateway (bridge IP, NAT)                   |
| `.2-.100`   | Reserved (infrastructure)                  |
| `.101-.120` | Sunbeam IP pools (internal, public, storage only) |
| `.201-.254` | DHCP (PXE boot, commissioning)             |

### Sunbeam IP Pool Placement

| Label                    | Subnet   | Range          | Purpose                    |
|--------------------------|----------|----------------|----------------------------|
| `mycloud-internal-api`   | internal | `.101-.120`    | Internal LoadBalancer IPs  |
| `mycloud-public-api`     | public   | `.101-.120`    | Public LoadBalancer IPs    |
| `mycloud-storage-ippool` | storage  | `.101-.110`    | Storage MetalLB pool       |

### External Network (Floating IPs)

The external bridge is an isolated L2 bridge (no IP, no NAT, no MAAS management).
Neutron creates a flat provider network on `physnet1` mapped to `enp7s0` via the
`neutron:physnet1` MAAS NIC tag. Floating IP allocation pool: `.100-.200`.

## Prerequisites

### 1. SSH config (local machine)

```
Host microstack-demo
    Hostname 10.0.9.11
    User ubuntu
    ProxyJump demo-baremetal

Host demo-baremetal
    Hostname <GLOBAL_IP_ADDRESS>
    User ubuntu
```

### 2. Enable nested KVM

```bash
sudo rmmod kvm_intel
cat <<EOF | sudo tee /etc/modprobe.d/nested-kvm-intel.conf
options kvm_intel nested=1
EOF
sudo modprobe kvm_intel

# Verify (should return "Y")
cat /sys/module/kvm_intel/parameters/nested
```

### 3. Initialize LXD

```bash
cat <<EOF | sudo lxd init --preseed
config: {}
networks:
- config:
    ipv4.address: 10.0.9.1/24
    ipv4.nat: "true"
    ipv4.dhcp.ranges: 10.0.9.51-10.0.9.200
    ipv6.address: none
  name: lxdbr0
  type: ""
storage_pools:
- config: {}
  name: default
  driver: dir
profiles:
- config: {}
  devices:
    eth0:
      name: eth0
      network: lxdbr0
      type: nic
    root:
      path: /
      pool: default
      type: disk
  name: default
cluster: null
EOF
```

## Run

```bash
./run.sh
```

To override defaults, set environment variables in `user-script.sh` or
export them before running (note: cloud-init reads `user-script.sh` as-is,
so edit the file directly for persistent changes).

## Configuration

All configuration is at the top of `user-script.sh`. Key variables:

### Channels & Versions

| Variable | Default | Description |
|---|---|---|
| `SNAP_CHANNEL` | `2024.1/edge` | OpenStack snap channel |
| `MAAS_PPA` | `ppa:maas/3.5` | MAAS PPA |

### VM Resources

| Variable | Default | Description |
|---|---|---|
| `COMPUTE_CPUS` | `16` | Compute node vCPUs |
| `COMPUTE_RAM_MB` | `49152` | Compute node RAM (48 GB) |
| `COMPUTE_DISK_GB` | `100` | Compute OS disk size |
| `COMPUTE_CEPH_DISK_GB` | `100` | Compute Ceph OSD disk size |
| `JUJU_CPUS` | `2` | Juju controller vCPUs |
| `JUJU_RAM_MB` | `4096` | Juju controller RAM (4 GB) |
| `JUJU_DISK_GB` | `50` | Juju controller disk size |
| `SUNBEAM_CPUS` | `2` | Sunbeam infra vCPUs |
| `SUNBEAM_RAM_MB` | `4096` | Sunbeam infra RAM (4 GB) |
| `SUNBEAM_DISK_GB` | `50` | Sunbeam infra disk size |
| `DISK_FORMAT` | `raw` | Disk format (`raw` or `qcow2`) |
| `NUM_COMPUTE` | `1` | Number of compute VMs |

### Networking

| Variable | Default | Description |
|---|---|---|
| `MGMT_SUBNET_PREFIX` | `192.168.151` | Management network |
| `INTERNAL_SUBNET_PREFIX` | `192.168.152` | Internal API network |
| `DATA_SUBNET_PREFIX` | `192.168.153` | Data/migration network |
| `STORAGE_SUBNET_PREFIX` | `192.168.154` | Ceph client network |
| `STCLUSTER_SUBNET_PREFIX` | `192.168.155` | Ceph replication network |
| `PUBLIC_SUBNET_PREFIX` | `192.168.171` | Public API network |
| `EXTERNAL_SUBNET_PREFIX` | `192.168.172` | Floating IP network (Neutron) |
| `LXD_IP` | `10.0.9.11` | LXD container static IP |

### Feature Flags

| Variable | Default | Description |
|---|---|---|
| `ENABLE_VAULT` | `true` | HashiCorp Vault |
| `ENABLE_SECRETS` | `true` | Barbican (requires Vault) |
| `ENABLE_LOADBALANCER` | `true` | Octavia (OVN provider) |
| `ENABLE_DNS` | `true` | Designate + Bind |
| `ENABLE_ORCHESTRATION` | `true` | Heat |
| `ENABLE_TELEMETRY` | `true` | Ceilometer + Gnocchi + Aodh |
| `ENABLE_OBSERVABILITY` | `true` | Embedded Grafana + Prometheus + Loki |
| `ENABLE_RESOURCE_OPT` | `true` | Watcher |
| `ENABLE_IMAGES_SYNC` | `true` | Auto-sync Ubuntu LTS images |
| `ENABLE_SHARED_FS` | `true` | Manila + CephFS (feature gate) |
| `ENABLE_TLS` | `false` | TLS via Vault (generates self-signed CA) |
| `ENABLE_VALIDATION` | `true` | Tempest (run last) |
| `ENABLE_BAREMETAL` | `false` | Ironic (needs physical hardware) |
| `ENABLE_CAAS` | `false` | Magnum (needs external CAPI cluster) |
| `ENABLE_INSTANCE_RECOVERY` | `false` | Masakari (needs 2+ compute nodes) |
| `ENABLE_LDAP` | `false` | Keystone LDAP (needs external LDAP) |
| `ENABLE_PRO` | `false` | Ubuntu Pro (needs token in `PRO_TOKEN`) |

### Feature Dependency Order

```
1. vault ─────┬──> 2. secrets (barbican)
              └──> 11. tls (optional)
3. loadbalancer
4. dns
5. orchestration
6. telemetry ──┬──> 7. observability (dashboards)
               └──> 8. resource-optimization (metrics)
9. images-sync
10. shared-filesystem (feature gate)
12. validation (last)
```

## Host-Side Variables (`run.sh`)

| Variable | Default | Description |
|---|---|---|
| `CONTAINER_NAME` | `microstack` | LXD container name |
| `LXD_IP` | `10.0.9.11` | Container static IP |
| `SSH_PROXY_PORT` | `10911` | Host port forwarded to container SSH |
| `LXD_IMAGE` | `ubuntu:jammy` | Base LXD image |

## Access

SSH:

```bash
ssh microstack-demo
```

Web browser (via sshuttle):

```bash
sshuttle -r microstack-demo -N
```

MAAS UI: `http://10.0.9.11:5240/MAAS` (ubuntu/ubuntu)

Horizon: check `sunbeam dashboard-url` inside the container.

Grafana: check `sunbeam observability dashboard-url` inside the container.

## Destroy & Rebuild

```bash
lxc delete --force microstack
./run.sh
```

## Features Not Enabled By Default

| Feature | Why | How to Enable |
|---|---|---|
| Instance Recovery | Needs 2+ compute nodes | Set `NUM_COMPUTE=2`, `ENABLE_INSTANCE_RECOVERY=true` (needs more RAM) |
| CaaS (Magnum) | Needs external CAPI management cluster | Set `ENABLE_CAAS=true` + provide CAPI kubeconfig post-deploy |
| Baremetal (Ironic) | Needs physical hardware and switch config | Set `ENABLE_BAREMETAL=true` (charms deploy but no hardware) |
| Ubuntu Pro | Needs subscription token | Set `ENABLE_PRO=true`, `PRO_TOKEN=<token>` |
| LDAP | Needs external LDAP server | Set `ENABLE_LDAP=true` + configure domains post-deploy |
| TLS | Complex CA setup, may break other features | Set `ENABLE_TLS=true` (generates self-signed CA) |
