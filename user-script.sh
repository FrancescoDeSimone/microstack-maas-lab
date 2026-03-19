#!/bin/bash

set -e
set -u
set -x

# ============================================================================
# CONFIGURATION - Override any variable via environment before running
# ============================================================================

# -- Snap / Channel --
SNAP_CHANNEL="${SNAP_CHANNEL:-2024.1/stable}"
MAAS_PPA="${MAAS_PPA:-ppa:maas/3.5}"

# -- Deployment --
DEPLOYMENT_NAME="${DEPLOYMENT_NAME:-mycloud}"
MAAS_ADMIN_USER="${MAAS_ADMIN_USER:-ubuntu}"
MAAS_ADMIN_PASS="${MAAS_ADMIN_PASS:-ubuntu}"
NUM_COMPUTE="${NUM_COMPUTE:-1}"

# -- VM Resources: Compute (control + compute + storage) --
COMPUTE_CPUS="${COMPUTE_CPUS:-16}"
COMPUTE_RAM_MB="${COMPUTE_RAM_MB:-32768}"           # 48 GB
COMPUTE_DISK_GB="${COMPUTE_DISK_GB:-100}"           # OS disk
COMPUTE_CEPH_DISK_GB="${COMPUTE_CEPH_DISK_GB:-100}" # Ceph OSD disk
DISK_FORMAT="${DISK_FORMAT:-raw}"                   # raw or qcow2

# -- VM Resources: Juju Controller --
JUJU_CPUS="${JUJU_CPUS:-2}"
JUJU_RAM_MB="${JUJU_RAM_MB:-4096}" # 4 GB
JUJU_DISK_GB="${JUJU_DISK_GB:-50}"

# -- VM Resources: Sunbeam Infra (clusterd) --
SUNBEAM_CPUS="${SUNBEAM_CPUS:-2}"
SUNBEAM_RAM_MB="${SUNBEAM_RAM_MB:-4096}" # 4 GB
SUNBEAM_DISK_GB="${SUNBEAM_DISK_GB:-50}"

# -- Networking: 6-space traffic isolation + external provider network --
# Each Sunbeam network gets its own bridge, subnet, and MAAS space.
# NIC order per VM: enp1s0=mgmt, enp2s0=internal, enp3s0=data,
#                   enp4s0=storage, enp5s0=stcluster, enp6s0=public,
#                   enp7s0=external
MGMT_SUBNET_PREFIX="${MGMT_SUBNET_PREFIX:-192.168.151}"           # management
INTERNAL_SUBNET_PREFIX="${INTERNAL_SUBNET_PREFIX:-192.168.152}"   # internal (API, AMQP)
DATA_SUBNET_PREFIX="${DATA_SUBNET_PREFIX:-192.168.153}"           # data (migration, VM traffic)
STORAGE_SUBNET_PREFIX="${STORAGE_SUBNET_PREFIX:-192.168.154}"     # storage (Ceph client)
STCLUSTER_SUBNET_PREFIX="${STCLUSTER_SUBNET_PREFIX:-192.168.155}" # storage-cluster (Ceph replication)
PUBLIC_SUBNET_PREFIX="${PUBLIC_SUBNET_PREFIX:-192.168.171}"       # public (API endpoints via Traefik)
EXTERNAL_SUBNET_PREFIX="${EXTERNAL_SUBNET_PREFIX:-192.168.172}"   # external (floating IPs, Neutron provider)
LXD_IP="${LXD_IP:-10.0.9.11}"
PROXY_IP="${PROXY_IP:-10.0.9.10}"
ENABLE_PROXY="${ENABLE_PROXY:-true}"
MAAS_IMAGE_STREAM="${MAAS_IMAGE_STREAM:-stable}"

# -- MAAS IP Range Layout (per-subnet, uniform) --
# .1         = gateway (bridge IP)
# .2-.100    = reserved (infrastructure)
# .101-.120  = Sunbeam IP pools (only on internal, public, storage)
# .201-.254  = DHCP (PXE / commissioning)
RESERVED_START="${RESERVED_START:-2}"
RESERVED_END="${RESERVED_END:-100}"
DHCP_START="${DHCP_START:-201}"
DHCP_END="${DHCP_END:-254}"

# -- External network (floating IPs) -- used in sunbeam configure manifest --
EXTERNAL_POOL_START="${EXTERNAL_POOL_START:-100}"
EXTERNAL_POOL_END="${EXTERNAL_POOL_END:-200}"

# -- Feature Flags (set to "true" to enable) --
ENABLE_VAULT="${ENABLE_VAULT:-true}"
ENABLE_SECRETS="${ENABLE_SECRETS:-true}" # Requires: vault
ENABLE_LOADBALANCER="${ENABLE_LOADBALANCER:-true}"
ENABLE_DNS="${ENABLE_DNS:-true}"
ENABLE_ORCHESTRATION="${ENABLE_ORCHESTRATION:-true}"
ENABLE_TELEMETRY="${ENABLE_TELEMETRY:-true}"
ENABLE_OBSERVABILITY="${ENABLE_OBSERVABILITY:-true}"
ENABLE_RESOURCE_OPT="${ENABLE_RESOURCE_OPT:-true}"
ENABLE_IMAGES_SYNC="${ENABLE_IMAGES_SYNC:-true}"
ENABLE_SHARED_FS="${ENABLE_SHARED_FS:-true}" # Feature gate + storage role
ENABLE_TLS="${ENABLE_TLS:-false}"            # Complex, off by default
ENABLE_VALIDATION="${ENABLE_VALIDATION:-false}"
# -- Skipped by default (require external dependencies) --
ENABLE_BAREMETAL="${ENABLE_BAREMETAL:-false}"                 # Needs real hardware + switch config
ENABLE_CAAS="${ENABLE_CAAS:-false}"                           # Needs external CAPI mgmt cluster
ENABLE_INSTANCE_RECOVERY="${ENABLE_INSTANCE_RECOVERY:-false}" # Needs 2+ compute nodes
ENABLE_LDAP="${ENABLE_LDAP:-false}"                           # Needs external LDAP server
ENABLE_PRO="${ENABLE_PRO:-false}"                             # Needs Ubuntu Pro token
PRO_TOKEN="${PRO_TOKEN:-}"

# DNS nameserver FQDN for Designate (must end with a dot)
DNS_NAMESERVER="${DNS_NAMESERVER:-ns1.${DEPLOYMENT_NAME}.local.}"

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

function cleanup() {
	# Copy (not move) critical state to ubuntu's home for convenience.
	# Keep originals under /root so sunbeam/juju keep working as root.
	cp -a /root/.maascli.db ~ubuntu/ 2>/dev/null || true
	cp -a /root/.local ~ubuntu/ 2>/dev/null || true
	cp -a /root/.kube ~ubuntu/ 2>/dev/null || true
	cp -a /root/.ssh/id_ed25519 /root/.ssh/id_ed25519.pub ~ubuntu/.ssh/ 2>/dev/null || true
	cp -a /root/vault-keys ~ubuntu/ 2>/dev/null || true
	cp -a /root/snap ~ubuntu/ 2>/dev/null || true
	chown -f ubuntu:ubuntu -R ~ubuntu || true
}

function log() {
	echo ""
	echo "========================================================================"
	echo ">>> $*"
	echo "========================================================================"
	echo ""
}

function create_libvirt_network() {
	# Create a virsh-managed network (bridge).
	# Usage: create_libvirt_network <name> [<subnet_prefix>]
	# With prefix: NAT bridge with IP at <prefix>.1/24
	# Without prefix: isolated L2 bridge (no IP, no NAT, invisible to MAAS)
	local name="$1"
	local prefix="${2:-}"
	if [[ -n "$prefix" ]]; then
		cat <<-EOF | virsh net-define /dev/stdin
			<network>
			  <name>${name}</name>
			  <bridge name='${name}' stp='off'/>
			  <forward mode='nat'/>
			  <ip address='${prefix}.1' netmask='255.255.255.0'/>
			</network>
		EOF
	else
		cat <<-EOF | virsh net-define /dev/stdin
			<network>
			  <name>${name}</name>
			  <bridge name='${name}' stp='off'/>
			</network>
		EOF
	fi
	virsh net-autostart "$name"
	virsh net-start "$name"
}

function configure_maas_subnet() {
	# Configure a MAAS-managed subnet with gateway, DNS, IP ranges, DHCP, and space.
	# Usage: configure_maas_subnet <subnet_prefix> <space_name>
	local prefix="$1"
	local space_name="$2"
	local cidr="${prefix}.0/24"

	maas admin subnet update "$cidr" \
		gateway_ip="${prefix}.1" \
		dns_servers="${MGMT_SUBNET_PREFIX}.1"

	local fabric
	fabric=$(maas admin subnets read | jq -r \
		".[] | select(.cidr==\"${cidr}\").vlan.fabric")

	maas admin ipranges create type=reserved \
		start_ip="${prefix}.${RESERVED_START}" \
		end_ip="${prefix}.${RESERVED_END}"
	maas admin ipranges create type=dynamic \
		start_ip="${prefix}.${DHCP_START}" \
		end_ip="${prefix}.${DHCP_END}"

	maas admin vlan update "$fabric" 0 dhcp_on=true primary_rack="$HOSTNAME"

	# Create space and assign the VLAN to it
	maas admin spaces create name="$space_name" 2>/dev/null || true
	local fabric_id
	fabric_id=$(maas admin subnets read | jq -r \
		".[] | select(.cidr==\"${cidr}\").vlan.fabric_id")
	maas admin vlan update "$fabric_id" 0 space="$space_name"
}

WAIT_MACHINE_TIMEOUT="${WAIT_MACHINE_TIMEOUT:-1800}"

function wait_for_machine() {
	local hostname="$1"
	local target_status="${2:-Ready}"
	local timeout="${3:-$WAIT_MACHINE_TIMEOUT}"
	local elapsed=0
	log "Waiting for machine '$hostname' to reach status '$target_status' (timeout: ${timeout}s)..."
	while true; do
		status=$(maas admin machines read | jq -r ".[] | select(.hostname == \"$hostname\") | .status_name")
		if [[ "$status" == "$target_status" ]]; then
			echo "Machine '$hostname' is $target_status!"
			return 0
		fi
		elapsed=$((elapsed + 15))
		if [[ $elapsed -ge $timeout ]]; then
			log "ERROR: Timeout waiting for '$hostname' to reach status '$target_status' after ${timeout}s"
			log "Current status: $status"
			log "Run 'maas admin events \$(maas admin nodes read | jq -r \".[] | select(.hostname == \\\"$hostname\\\") | .system_id\")' for details"
			return 1
		fi
		echo "  '$hostname' current status: $status (waiting for $target_status, ${elapsed}s elapsed)..."
		sleep 15
	done
}

function create_vm() {
	local name="$1"
	local cpus="$2"
	local ram_mb="$3"
	shift 3
	# Remaining args are disk sizes in GB
	local disk_args=()
	for disk_gb in "$@"; do
		disk_args+=(--disk "size=$disk_gb,format=$DISK_FORMAT,target.rotation_rate=1,target.bus=scsi,cache=unsafe")
	done

	log "Creating VM '$name': ${cpus} vCPUs, ${ram_mb} MB RAM, disks: $*"

	# 7 NICs: one per bridge (6 Sunbeam spaces + 1 external provider)
	# NIC order determines naming: enp1s0..enp7s0
	virt-install \
		--import --noreboot \
		--name "$name" \
		--osinfo ubuntujammy \
		--boot network,hd \
		--vcpus "cores=$cpus" \
		--cpu host-passthrough,cache.mode=passthrough \
		--memory "$ram_mb" \
		"${disk_args[@]}" \
		--network network=mgmt \
		--network network=internal \
		--network network=data \
		--network network=storage \
		--network network=stcluster \
		--network network=public \
		--network network=external

	# Register in MAAS using the first MAC (enp1s0 = mgmt network)
	local mac
	mac="$(virsh dumpxml "$name" | xmllint --xpath 'string(//mac/@address)' -)"
	maas admin machines create \
		hostname="$name" \
		architecture=amd64 \
		mac_addresses="$mac" \
		power_type=virsh \
		power_parameters_power_address='qemu+ssh://root@127.0.0.1/system' \
		power_parameters_power_id="$name"
}

function ensure_tag() {
	local tag="$1"
	maas admin tags create name="$tag" 2>/dev/null || true
}

function tag_machine() {
	local hostname="$1"
	shift
	local system_id
	system_id=$(maas admin nodes read | jq -r ".[] | select(.hostname == \"$hostname\") | .system_id")
	for tag in "$@"; do
		ensure_tag "$tag"
		maas admin tag update-nodes "$tag" add="$system_id"
	done
}

function tag_block_device() {
	local hostname="$1"
	local device_path="$2"
	local tag="$3"
	local system_id
	system_id=$(maas admin nodes read | jq -r ".[] | select(.hostname == \"$hostname\") | .system_id")
	local block_device_id
	block_device_id=$(maas admin block-devices read "$system_id" | jq -r ".[] | select(.path == \"$device_path\") | .id")
	maas admin block-device add-tag "$system_id" "$block_device_id" tag="$tag"
}

function tag_interface() {
	local hostname="$1"
	local iface_name="$2"
	local tag="$3"
	local system_id
	system_id=$(maas admin nodes read | jq -r ".[] | select(.hostname == \"$hostname\") | .system_id")
	local interface_id
	interface_id=$(maas admin interfaces read "$system_id" | jq -r ".[] | select(.name == \"$iface_name\") | .id")
	maas admin interface add-tag "$system_id" "$interface_id" tag="$tag"
}

function set_nics_auto_dhcp() {
	# After commissioning, non-boot NICs default to link_up (no IP).
	# Juju only reports interfaces with an IP address, so Sunbeam's
	# cluster deploy fails with "Node X has no interface in Y space".
	# Fix: switch each Sunbeam-managed NIC (enp2s0-enp6s0) to auto (DHCP)
	# so they get IPs during MAAS deployment. enp7s0 (external) stays
	# link_up — it's a Neutron provider NIC with no MAAS-managed IP.
	local hostname="$1"
	local system_id
	system_id=$(maas admin nodes read | jq -r ".[] | select(.hostname == \"$hostname\") | .system_id")

	local interfaces_json
	interfaces_json=$(maas admin interfaces read "$system_id")

	# Non-boot NICs that should get DHCP (all except enp1s0 boot and enp7s0 external)
	local nics_to_auto=("enp2s0" "enp3s0" "enp4s0" "enp5s0" "enp6s0")

	for nic_name in "${nics_to_auto[@]}"; do
		local iface_id link_id subnet_id
		iface_id=$(echo "$interfaces_json" | jq -r ".[] | select(.name == \"$nic_name\") | .id")
		if [[ -z "$iface_id" || "$iface_id" == "null" ]]; then
			echo "  WARNING: NIC '$nic_name' not found on '$hostname', skipping"
			continue
		fi

		# Get the current link ID (to unlink it) and subnet ID
		link_id=$(echo "$interfaces_json" | jq -r ".[] | select(.name == \"$nic_name\") | .links[0].id")
		subnet_id=$(echo "$interfaces_json" | jq -r ".[] | select(.name == \"$nic_name\") | .links[0].subnet.id")

		# Unlink current link_up mode
		if [[ -n "$link_id" && "$link_id" != "null" ]]; then
			maas admin interface unlink-subnet "$system_id" "$iface_id" id="$link_id"
		fi

		# Re-link with auto (DHCP) mode
		if [[ -n "$subnet_id" && "$subnet_id" != "null" ]]; then
			maas admin interface link-subnet "$system_id" "$iface_id" mode=auto subnet="$subnet_id"
			echo "  Set $nic_name (iface $iface_id) to auto/DHCP on subnet $subnet_id"
		else
			echo "  WARNING: No subnet found for NIC '$nic_name' on '$hostname', skipping auto mode"
		fi
	done
}

function enable_feature() {
	local flag_var="$1"
	local feature_name="$2"
	shift 2
	# Remaining args are the sunbeam command
	if [[ "${!flag_var}" == "true" ]]; then
		log "Enabling feature: $feature_name"
		"$@"
		echo "Feature '$feature_name' enabled successfully."
	else
		echo "Skipping feature: $feature_name (${flag_var}=false)"
	fi
}

# ============================================================================
# MAIN DEPLOYMENT
# ============================================================================

trap cleanup SIGHUP SIGINT SIGTERM EXIT

# try not to kill some commands by session management
# it seems like a race condition with MAAS jobs in root user and snapped
# juju command's systemd scope
# LP: #1921876, LP: #2058030
loginctl enable-linger root

export DEBIAN_FRONTEND=noninteractive
mkdir -p /root/.local/share/juju/ssh/ # LP: #2029515
cd ~/

# ============================================================================
# PHASE 1: System Setup
# ============================================================================
log "Phase 1: System Setup"

# Proxy (optional squid-deb-proxy in LXD)
if host squid-deb-proxy.lxd >/dev/null 2>&1; then
	http_proxy="http://$(dig +short squid-deb-proxy.lxd):8000/"
	echo "Acquire::http::Proxy \"${http_proxy}\";" >/etc/apt/apt.conf
fi

# PPA
apt-add-repository -y "$MAAS_PPA"
apt-get update

# Utilities
eatmydata apt-get install -y tree jq

# KVM setup
eatmydata apt-get install -y libvirt-daemon-system
eatmydata apt-get install -y virtinst --no-install-recommends

cat >>/etc/libvirt/qemu.conf <<EOF

# Avoid the error in LXD containers:
# Unable to set XATTR trusted.libvirt.security.dac on
# /var/lib/libvirt/qemu/domain-*: Operation not permitted
remember_owner = 0
EOF

systemctl restart libvirtd.service

# ============================================================================
# PHASE 2: Network Configuration (7 bridges)
# ============================================================================
log "Phase 2: Network Configuration"

virsh net-destroy default
virsh net-autostart --disable default

virsh pool-define-as default dir --target /var/lib/libvirt/images
virsh pool-autostart default
virsh pool-start default

# 6 Sunbeam space networks (NAT bridges with IP)
create_libvirt_network mgmt "$MGMT_SUBNET_PREFIX"
create_libvirt_network internal "$INTERNAL_SUBNET_PREFIX"
create_libvirt_network data "$DATA_SUBNET_PREFIX"
create_libvirt_network storage "$STORAGE_SUBNET_PREFIX"
create_libvirt_network stcluster "$STCLUSTER_SUBNET_PREFIX"
create_libvirt_network public "$PUBLIC_SUBNET_PREFIX"

# External provider network (isolated L2 bridge — no IP, not in MAAS)
# Neutron/OVS maps physnet1 to this bridge for floating IPs.
create_libvirt_network external

# ============================================================================
# Wait for local MAAS image mirror (if proxy enabled)
# ============================================================================
if [[ "$ENABLE_PROXY" == "true" ]]; then
	log "Waiting for local MAAS image mirror to sync..."

	MAX_WAIT=1200
	WAITED=0
	while ! curl -sf "http://${PROXY_IP}/images/mirror-ready" >/dev/null 2>&1; do
		if [[ $WAITED -ge $MAX_WAIT ]]; then
			log "WARNING: Mirror not ready after ${MAX_WAIT}s, using remote"
			break
		fi
		echo "  Waiting for mirror... (${WAITED}s)"
		sleep 30
		WAITED=$((WAITED + 30))
	done

	if curl -sf "http://${PROXY_IP}/images/mirror-ready" >/dev/null 2>&1; then
		log "Local image mirror ready, will use for boot-resources"
	fi
fi

# ============================================================================
# PHASE 3: MAAS Installation & Configuration
# ============================================================================
log "Phase 3: MAAS Installation & Configuration"

echo "maas-region-controller maas/default-maas-url string ${MGMT_SUBNET_PREFIX}.1" |
	debconf-set-selections
eatmydata apt-get install -y maas

# Create admin user
maas createadmin \
	--username "$MAAS_ADMIN_USER" \
	--password "$MAAS_ADMIN_PASS" \
	--email "${MAAS_ADMIN_USER}@localhost.localdomain"

# LP: #2031842
sleep 30
maas login admin "http://localhost:5240/MAAS" "$(maas apikey --username "$MAAS_ADMIN_USER")"

ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N ''
maas admin sshkeys create key="$(cat ~/.ssh/id_ed25519.pub)"

maas admin maas set-config name=enable_analytics value=false
maas admin maas set-config name=release_notifications value=false
maas admin maas set-config name=maas_name value="$DEPLOYMENT_NAME"
maas admin maas set-config name=kernel_opts value='console=tty0 console=ttyS0,115200n8'
maas admin maas set-config name=completed_intro value=true

# ---- Configure 6 MAAS subnets (one per Sunbeam space) ----
# Each gets: gateway, DNS, reserved range, DHCP range, space assignment.
# The external network is NOT configured in MAAS (Neutron-only).
configure_maas_subnet "$MGMT_SUBNET_PREFIX" space-management
configure_maas_subnet "$INTERNAL_SUBNET_PREFIX" space-internal
configure_maas_subnet "$DATA_SUBNET_PREFIX" space-data
configure_maas_subnet "$STORAGE_SUBNET_PREFIX" space-storage
configure_maas_subnet "$STCLUSTER_SUBNET_PREFIX" space-storage-cluster
configure_maas_subnet "$PUBLIC_SUBNET_PREFIX" space-public

# ---- Boot images ----
if [[ "$ENABLE_PROXY" == "true" ]] && curl -sf "http://${PROXY_IP}/images/mirror-ready" >/dev/null 2>&1; then
	log "Using local image mirror: http://${PROXY_IP}/maas/images/ephemeral-v3/${MAAS_IMAGE_STREAM}"
	maas admin boot-source update 1 url="http://${PROXY_IP}/maas/images/ephemeral-v3/${MAAS_IMAGE_STREAM}"
fi
maas admin boot-source-selections create 1 os=ubuntu release=noble arches=amd64 subarches='*' labels='*'
maas admin boot-resources import

log "Waiting for boot images to finish importing..."
time while [ "$(maas admin boot-resources is-importing)" = 'true' ]; do
	sleep 15
done

# ============================================================================
# PHASE 4: KVM Pod & VM Creation
# ============================================================================
log "Phase 4: KVM Pod & VM Creation"

# SSH key exchange for virsh power management
sudo -u maas -H ssh-keygen -t ed25519 -f ~maas/.ssh/id_ed25519 -N ''
install -m 0600 ~maas/.ssh/id_ed25519.pub /root/.ssh/authorized_keys

# Register KVM host in MAAS for UI demo purpose
# ("pod compose" is not going to be used)
maas admin pods create \
	type=virsh \
	cpu_over_commit_ratio=10 \
	memory_over_commit_ratio=1.5 \
	name=localhost \
	power_address='qemu+ssh://root@127.0.0.1/system'

# ---- Create compute VMs ----
for i in $(seq 1 "$NUM_COMPUTE"); do
	create_vm "compute-$i" "$COMPUTE_CPUS" "$COMPUTE_RAM_MB" \
		"$COMPUTE_DISK_GB" "$COMPUTE_CEPH_DISK_GB"
done

# ---- Create Juju controller VM ----
create_vm "juju" "$JUJU_CPUS" "$JUJU_RAM_MB" "$JUJU_DISK_GB"

# ---- Create Sunbeam infra VM ----
create_vm "sunbeam" "$SUNBEAM_CPUS" "$SUNBEAM_RAM_MB" "$SUNBEAM_DISK_GB"

# ============================================================================
# PHASE 5: Start VMs and Trigger Commissioning
# ============================================================================
log "Phase 5: Starting VMs and Triggering Commissioning"

# Start all VMs - they will PXE boot and MAAS will commission them
for vm in compute-1 juju sunbeam; do
	log "Starting VM: $vm"
	virsh start "$vm" || log "WARNING: Failed to start $vm"
done

# Trigger commissioning for all machines
# Skip networking/storage tests — these are ephemeral nested VMs that don't need
# full hardware validation. --enable-ssh allows post-commissioning access.
log "Triggering commissioning for all machines..."
for vm in compute-1 juju sunbeam; do
	system_id=$(maas admin nodes read | jq -r ".[] | select(.hostname == \"$vm\") | .system_id")
	if [[ -n "$system_id" && "$system_id" != "null" ]]; then
		log "Commissioning $vm (system_id: $system_id)"
		maas admin machine commission "$system_id" \
			--skip-networking --skip-storage --enable-ssh ||
			log "WARNING: Commissioning failed for $vm"
	else
		log "WARNING: Could not find system_id for $vm"
	fi
done

# ============================================================================
# PHASE 6: IP Reservations for Sunbeam
# ============================================================================
log "Phase 6: IP Reservations"

# Sunbeam looks for reserved IP ranges by label (comment) in the correct
# MAAS space. These ranges are used for MetalLB IP pools.

# Internal API pool — in the INTERNAL space (for internal LoadBalancer IPs)
maas admin ipranges create type=reserved \
	start_ip="${INTERNAL_SUBNET_PREFIX}.101" \
	end_ip="${INTERNAL_SUBNET_PREFIX}.120" \
	comment="${DEPLOYMENT_NAME}-internal-api"

# Public API pool — in the PUBLIC space (for public-facing LoadBalancer IPs)
maas admin ipranges create type=reserved \
	start_ip="${PUBLIC_SUBNET_PREFIX}.101" \
	end_ip="${PUBLIC_SUBNET_PREFIX}.120" \
	comment="${DEPLOYMENT_NAME}-public-api"

# Storage IP pool — in the STORAGE space (optional dedicated storage MetalLB pool)
maas admin ipranges create type=reserved \
	start_ip="${STORAGE_SUBNET_PREFIX}.101" \
	end_ip="${STORAGE_SUBNET_PREFIX}.110" \
	comment="${DEPLOYMENT_NAME}-storage-ippool"

# ============================================================================
# PHASE 7: Wait for Commissioning & Apply Tags
# ============================================================================
log "Phase 7: Commissioning & Tagging"

log "TIP: Commissioning typically takes 10-20 minutes. If stuck, check:"
log "  - VMs are powered on: virsh list --all"
log "  - Networks are active: virsh net-list --all"
log "  - MAAS events: maas admin events <system_id>"
log "  - DHCP leases: virsh net-dhcp-leases mgmt"

# ---- Compute nodes ----
for i in $(seq 1 "$NUM_COMPUTE"); do
	wait_for_machine "compute-$i"
	tag_machine "compute-$i" \
		"openstack-${DEPLOYMENT_NAME}" "control" "compute" "storage"
	tag_block_device "compute-$i" "/dev/disk/by-dname/sdb" "ceph"
	# Tag the external NIC (enp7s0) for Neutron provider network mapping.
	# Sunbeam reads this tag to build OVS bridge-mapping: br-physnet1:physnet1:enp7s0
	tag_interface "compute-$i" "enp7s0" "neutron:physnet1"
	# Set non-boot NICs to auto/DHCP so they get IPs during MAAS deploy.
	# Without this, Juju only sees the boot NIC and Sunbeam cluster deploy
	# fails with "Node X has no interface in Y space".
	set_nics_auto_dhcp "compute-$i"
done

# ---- Juju controller ----
wait_for_machine "juju"
tag_machine "juju" "juju-controller" "openstack-${DEPLOYMENT_NAME}"
set_nics_auto_dhcp "juju"

# ---- Sunbeam infra ----
wait_for_machine "sunbeam"
tag_machine "sunbeam" "openstack-${DEPLOYMENT_NAME}" "sunbeam"
set_nics_auto_dhcp "sunbeam"

# ============================================================================
# PHASE 8: Sunbeam Base Deployment
# ============================================================================
log "Phase 8: Sunbeam Base Deployment"

snap install openstack --channel "$SNAP_CHANNEL"
sunbeam prepare-node-script --client | bash -x

apikey=$(maas apikey --username="$MAAS_ADMIN_USER")
sunbeam deployment add maas "$DEPLOYMENT_NAME" "$apikey" "http://${LXD_IP}:5240/MAAS"

# Map all 6 Sunbeam cloud networks to their MAAS spaces
sunbeam deployment space map \
	space-management:management \
	space-internal:internal \
	space-data:data \
	space-storage:storage \
	space-storage-cluster:storage-cluster \
	space-public:public

validate_output=$(sunbeam deployment validate)
if echo "$validate_output" | grep -q "FAIL"; then
	echo "Validation FAILED. Output:"
	echo "$validate_output"
	exit 1
else
	echo "Validation passed."
fi

sunbeam cluster bootstrap --accept-defaults
sunbeam cluster deploy --accept-defaults

log "Base deployment complete!"

# ============================================================================
# PHASE 7a: LXD Environment Fixes (pre-configure)
# ============================================================================
log "Phase 7a: LXD Environment Fixes (pre-configure)"

# Discover compute-1's management IP (DHCP-assigned by MAAS)
COMPUTE1_SYSTEM_ID=$(maas admin nodes read | jq -r '.[] | select(.hostname == "compute-1") | .system_id')
COMPUTE1_MGMT_IP=$(maas admin interfaces read "$COMPUTE1_SYSTEM_ID" | jq -r '
	.[] | select(.name == "enp1s0") | .links[] | select(.ip_address != null) | .ip_address' | head -1)
echo "compute-1 management IP: $COMPUTE1_MGMT_IP"

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

# --- Fix 2: Pod-to-Ceph routing ---
# K8s pods (10.1.0.x) connect to Ceph mon on the storage subnet (enp4s0).
# Kernel policy routing sends the SYN-ACK out enp4s0 instead of back through
# cilium_host to the pod. This rule ensures pod-destined traffic always uses
# the main routing table, fixing the return path.
log "Fix 2: Adding pod-to-Ceph routing rule on compute-1"
ssh $SSH_OPTS ubuntu@"$COMPUTE1_MGMT_IP" \
	"sudo ip rule add to 10.1.0.0/24 lookup main prio 100 2>/dev/null || true"
echo "Pod-to-Ceph routing rule added on compute-1."

# --- Fix 3: iptables DNAT for MetalLB VIP reachability ---
# Canonical K8s uses cilium with Device Mode: veth. eBPF only attaches to veth
# interfaces, NOT physical NICs. MetalLB VIPs are unreachable from outside the
# node. We create iptables DNAT rules on the LXD container to redirect VIP
# traffic to compute-1's NodePorts.
log "Fix 3: Creating iptables DNAT rules for MetalLB VIPs"

# Helper: create DNAT rules for a given traefik service
create_traefik_dnat() {
	local svc_name="$1"
	local vip

	vip=$(ssh $SSH_OPTS ubuntu@"$COMPUTE1_MGMT_IP" \
		"sudo k8s kubectl get svc -n openstack ${svc_name} \
		 -o jsonpath='{.status.loadBalancer.ingress[0].ip}'" 2>/dev/null || true)

	if [[ -z "$vip" ]]; then
		echo "  ${svc_name}: no VIP found, skipping"
		return
	fi
	echo "  ${svc_name} VIP: $vip"

	local np_http np_https
	np_http=$(ssh $SSH_OPTS ubuntu@"$COMPUTE1_MGMT_IP" \
		"sudo k8s kubectl get svc -n openstack ${svc_name} \
		 -o jsonpath='{.spec.ports[?(@.port==80)].nodePort}'" 2>/dev/null || true)
	np_https=$(ssh $SSH_OPTS ubuntu@"$COMPUTE1_MGMT_IP" \
		"sudo k8s kubectl get svc -n openstack ${svc_name} \
		 -o jsonpath='{.spec.ports[?(@.port==443)].nodePort}'" 2>/dev/null || true)

	if [[ -n "$np_http" ]]; then
		iptables -t nat -A OUTPUT -d "$vip" -p tcp --dport 80 \
			-j DNAT --to-destination "${COMPUTE1_MGMT_IP}:${np_http}"
		echo "  DNAT: ${vip}:80 -> ${COMPUTE1_MGMT_IP}:${np_http}"
	fi
	if [[ -n "$np_https" ]]; then
		iptables -t nat -A OUTPUT -d "$vip" -p tcp --dport 443 \
			-j DNAT --to-destination "${COMPUTE1_MGMT_IP}:${np_https}"
		echo "  DNAT: ${vip}:443 -> ${COMPUTE1_MGMT_IP}:${np_https}"
	fi
}

create_traefik_dnat "traefik-public-lb"
create_traefik_dnat "traefik-lb"
create_traefik_dnat "traefik-rgw-lb"

log "Phase 7a complete — LXD environment fixes applied."

# ============================================================================
# PHASE 7b: Cloud Configuration (external network, demo tenant)
# ============================================================================
log "Phase 7b: Cloud Configuration (sunbeam configure)"

# Generate manifest for sunbeam configure.
# This creates: demo user/project, external provider network on physnet1,
# router, security group rules, and tenant subnet.
# The external network uses the dedicated external bridge (enp7s0).
cat >/root/configure-manifest.yaml <<EOF
core:
  config:
    user:
      run_demo_setup: true
      username: demo
      password: demo
      cidr: 192.168.0.0/24
      nameservers: "${MGMT_SUBNET_PREFIX}.1"
      security_group_rules: true
      remote_access_location: remote
    external-networks:
      physnet1:
        cidr: "${EXTERNAL_SUBNET_PREFIX}.0/24"
        gateway: "${EXTERNAL_SUBNET_PREFIX}.1"
        range: "${EXTERNAL_SUBNET_PREFIX}.${EXTERNAL_POOL_START}-${EXTERNAL_SUBNET_PREFIX}.${EXTERNAL_POOL_END}"
        network_type: flat
        segmentation_id: 0
EOF

sunbeam configure --accept-defaults -m /root/configure-manifest.yaml

log "Cloud configuration complete — external network and demo tenant created."

# ============================================================================
# PHASE 7c: LXD Environment Fixes (post-configure)
# ============================================================================
log "Phase 7c: External network access (br-ex IP + Neutron port)"

# --- Fix 4: br-ex IP + Neutron port for external network access ---
# The tempest pod and the LXD host need to reach floating IPs on the external
# subnet (192.168.172.0/24). Without an IP on br-ex, traffic can't be routed.
# Without a Neutron port, OVN anti-spoofing drops the traffic.

# Step 1: Add IP on br-ex on compute-1
ssh $SSH_OPTS ubuntu@"$COMPUTE1_MGMT_IP" \
	"sudo ip addr add ${EXTERNAL_SUBNET_PREFIX}.2/24 dev br-ex 2>/dev/null || true"
echo "Added ${EXTERNAL_SUBNET_PREFIX}.2/24 on br-ex on compute-1."

# Step 2: Get br-ex MAC address from compute-1
BREX_MAC=$(ssh $SSH_OPTS ubuntu@"$COMPUTE1_MGMT_IP" \
	"ip link show br-ex | grep -oP 'link/ether \K[0-9a-f:]+'")
echo "br-ex MAC: $BREX_MAC"

# Step 3: Create Neutron port on external-network with port-security disabled
eval "$(sunbeam openrc)"

openstack port create \
	--network external-network \
	--fixed-ip subnet=external-subnet,ip-address="${EXTERNAL_SUBNET_PREFIX}.2" \
	--disable-port-security \
	--no-security-group \
	host-external-port -f json | tee /tmp/host-external-port.json

# Update the MAC address to match br-ex
openstack port set host-external-port --mac-address "$BREX_MAC"

# Bind the port to compute-1 (OVN needs this for localnet routing).
# Setting binding:host_id and binding:profile requires system-scoped admin
# in Caracal+ (new RBAC enforce_scope). Switch to system scope temporarily.
COMPUTE1_FQDN=$(maas admin nodes read | jq -r '.[] | select(.hostname == "compute-1") | .fqdn')
(
	export OS_SYSTEM_SCOPE=all
	unset OS_PROJECT_NAME OS_PROJECT_DOMAIN_NAME
	openstack port set host-external-port \
		--host "$COMPUTE1_FQDN" \
		--binding-profile '{"bridge_mappings": "physnet1:br-physnet1"}'
) || echo "WARNING: Could not set port binding (needs system-admin). Port-security is disabled, traffic may still work."

echo "Neutron port 'host-external-port' created and bound to compute-1."

# Step 4: Add route on LXD container to reach external subnet via compute-1
ip route add "${EXTERNAL_SUBNET_PREFIX}.0/24" via "$COMPUTE1_MGMT_IP" 2>/dev/null || true
echo "Route added: ${EXTERNAL_SUBNET_PREFIX}.0/24 via $COMPUTE1_MGMT_IP"

log "Phase 7c complete — external network access configured."

# ============================================================================
# PHASE 9: Feature Enablement
# ============================================================================
log "Phase 9: Feature Enablement"

# ---- 1. Vault (prerequisite for Secrets, TLS) ----
if [[ "$ENABLE_VAULT" == "true" ]]; then
	log "Enabling Vault..."
	sunbeam enable vault

	# Initialize with 1 key share and 1 threshold (lab simplicity)
	mkdir -p /root/vault-keys
	sunbeam vault init 1 1 2>&1 | tee /root/vault-keys/vault-init-output.txt

	# Parse unseal key and root token from init output
	# Actual output format from `sunbeam vault init 1 1`:
	#   Unseal keys:
	#   <base64-key>
	#
	#   Root token: <token>
	VAULT_UNSEAL_KEY=$(awk '/^Unseal keys:/{found=1; next} found && /^[A-Za-z0-9+\/=]+$/{print; exit}' \
		/root/vault-keys/vault-init-output.txt)
	VAULT_ROOT_TOKEN=$(grep -oP '^Root token: \K.*' /root/vault-keys/vault-init-output.txt)

	# Save keys separately for convenience
	echo "$VAULT_UNSEAL_KEY" >/root/vault-keys/unseal-key.txt
	echo "$VAULT_ROOT_TOKEN" >/root/vault-keys/root-token.txt

	# Unseal the vault (pass key as positional arg; `-` stdin requires a terminal)
	sunbeam vault unseal "$VAULT_UNSEAL_KEY"

	# Authorize the charm (pass token as positional arg)
	sunbeam vault authorize-charm "$VAULT_ROOT_TOKEN"

	# Wait for vault to settle (juju update-status cycle)
	log "Waiting for Vault to settle..."
	sleep 60

	sunbeam vault status || true
	echo "Vault enabled and initialized."
fi

# ---- 2. Secrets / Barbican (requires Vault) ----
if [[ "$ENABLE_SECRETS" == "true" ]]; then
	if [[ "$ENABLE_VAULT" != "true" ]]; then
		echo "WARNING: Secrets requires Vault. Skipping."
	else
		log "Enabling feature: Secrets (Barbican)"
		sunbeam enable secrets
		echo "Feature 'Secrets (Barbican)' enabled successfully."
	fi
fi

# ---- 3. Load Balancer / Octavia (OVN provider) ----
enable_feature ENABLE_LOADBALANCER "Load Balancer (Octavia)" \
	sunbeam enable loadbalancer

# ---- 4. DNS / Designate ----
if [[ "$ENABLE_DNS" == "true" ]]; then
	log "Enabling feature: DNS (Designate)"
	sunbeam enable dns "$DNS_NAMESERVER"
	echo "Feature 'DNS (Designate)' enabled successfully."
fi

# ---- 5. Orchestration / Heat ----
enable_feature ENABLE_ORCHESTRATION "Orchestration (Heat)" \
	sunbeam enable orchestration

# ---- 6. Telemetry / Ceilometer + Gnocchi + Aodh ----
enable_feature ENABLE_TELEMETRY "Telemetry (Ceilometer/Gnocchi/Aodh)" \
	sunbeam enable telemetry

# ---- 7. Observability (embedded Grafana + Prometheus + Loki) ----
if [[ "$ENABLE_OBSERVABILITY" == "true" ]]; then
	log "Enabling feature: Observability (embedded)"
	sunbeam enable observability embedded
	echo "Feature 'Observability (embedded)' enabled successfully."
fi

# ---- 8. Resource Optimization / Watcher ----
enable_feature ENABLE_RESOURCE_OPT "Resource Optimization (Watcher)" \
	sunbeam enable resource-optimization

# ---- 9. Images Sync ----
enable_feature ENABLE_IMAGES_SYNC "Images Sync" \
	sunbeam enable images-sync

# ---- 10. Shared Filesystem / Manila (feature gate + storage role) ----
if [[ "$ENABLE_SHARED_FS" == "true" ]]; then
	log "Enabling feature: Shared Filesystem (Manila)"
	sudo snap set openstack feature.shared-filesystem=true
	sunbeam enable shared-filesystem
	echo "Feature 'Shared Filesystem (Manila)' enabled successfully."
fi

# ---- 11. TLS via Vault (optional, off by default) ----
if [[ "$ENABLE_TLS" == "true" ]]; then
	if [[ "$ENABLE_VAULT" != "true" ]]; then
		echo "WARNING: TLS (Vault method) requires Vault. Skipping."
	else
		log "Enabling feature: TLS (Vault method)"
		# Generate a self-signed CA for the lab
		mkdir -p /root/tls-ca
		openssl req -x509 -newkey rsa:4096 -keyout /root/tls-ca/ca-key.pem \
			-out /root/tls-ca/ca-cert.pem -sha256 -days 3650 -nodes \
			-subj "/C=US/ST=Lab/L=Lab/O=Sunbeam-Lab/CN=${DEPLOYMENT_NAME}-ca"

		CA_B64=$(base64 -w0 /root/tls-ca/ca-cert.pem)

		# For self-signed CA, omit --ca-chain
		sunbeam enable tls vault --ca "$CA_B64"
		echo "Feature 'TLS (Vault method)' enabled successfully."
		echo "NOTE: CSRs may need to be signed. Check: sunbeam tls vault list_outstanding_csrs"
	fi
fi

# ---- 12. Ubuntu Pro (optional, off by default) ----
if [[ "$ENABLE_PRO" == "true" && -n "$PRO_TOKEN" ]]; then
	enable_feature ENABLE_PRO "Ubuntu Pro" \
		sunbeam enable pro "$PRO_TOKEN"
fi

# ---- 13. Baremetal / Ironic (optional, off by default) ----
if [[ "$ENABLE_BAREMETAL" == "true" ]]; then
	log "Enabling feature: Baremetal (Ironic)"
	sudo snap set openstack feature.baremetal=true
	sunbeam enable baremetal
	echo "Feature 'Baremetal (Ironic)' enabled (charms deployed, no physical hardware configured)."
fi

# ---- 14. CaaS / Magnum (optional, off by default) ----
# NOTE: Requires external CAPI management cluster kubeconfig.
# Cannot be fully automated without it.
if [[ "$ENABLE_CAAS" == "true" ]]; then
	if [[ "$ENABLE_SECRETS" != "true" || "$ENABLE_LOADBALANCER" != "true" ]]; then
		echo "WARNING: CaaS requires Secrets + Load Balancer. Skipping."
	else
		enable_feature ENABLE_CAAS "Containers as a Service (Magnum)" \
			sunbeam enable caas
	fi
fi

# ---- 15. Instance Recovery / Masakari (optional, off by default) ----
# NOTE: Requires 2+ compute nodes. With NUM_COMPUTE=1 this will not work.
if [[ "$ENABLE_INSTANCE_RECOVERY" == "true" ]]; then
	if [[ "$NUM_COMPUTE" -lt 2 ]]; then
		echo "WARNING: Instance Recovery requires 2+ compute nodes (NUM_COMPUTE=$NUM_COMPUTE). Skipping."
	else
		enable_feature ENABLE_INSTANCE_RECOVERY "Instance Recovery (Masakari)" \
			sunbeam enable instance-recovery
	fi
fi

# ---- 16. LDAP Integration (optional, off by default) ----
# NOTE: Requires an external LDAP server.
if [[ "$ENABLE_LDAP" == "true" ]]; then
	log "Enabling feature: LDAP Integration"
	sunbeam enable ldap
	echo "LDAP feature enabled. Configure domains with: sunbeam ldap add-domain ..."
fi

# ---- 17. Validation / Tempest (run last to validate all features) ----
enable_feature ENABLE_VALIDATION "Validation (Tempest)" \
	sunbeam enable validation

# ============================================================================
# PHASE 10: MAAS DNS Entries for Traefik Endpoints
# ============================================================================
log "Phase 10: MAAS DNS Entries for Traefik"

# Create DNS A records in MAAS for traefik LoadBalancer service IPs.
# This lets API endpoints be accessible by hostname via MAAS DNS.
MAAS_DOMAIN=$(maas admin domains read | jq -r '.[0].name')

# Get traefik public endpoint IP from K8s (MetalLB-assigned)
TRAEFIK_PUBLIC_IP=$(sunbeam openrc | grep OS_AUTH_URL | sed -E 's|.*://([0-9.]+).*|\1|') || true
if [[ -n "$TRAEFIK_PUBLIC_IP" ]]; then
	maas admin dnsresources create fqdn="api.${MAAS_DOMAIN}" ip_addresses="$TRAEFIK_PUBLIC_IP" 2>/dev/null || true
	maas admin dnsresources create fqdn="horizon.${MAAS_DOMAIN}" ip_addresses="$TRAEFIK_PUBLIC_IP" 2>/dev/null || true
	echo "Created DNS records: api.${MAAS_DOMAIN} -> $TRAEFIK_PUBLIC_IP"
else
	echo "WARNING: Could not determine traefik public IP for DNS records."
fi

# ============================================================================
# DONE
# ============================================================================
log "Deployment Complete!"

echo ""
echo "============================================================"
echo " Sunbeam deployment: $DEPLOYMENT_NAME"
echo " Snap channel:       $SNAP_CHANNEL"
echo " MAAS URL:           http://${LXD_IP}:5240/MAAS"
echo " MAAS credentials:   $MAAS_ADMIN_USER / $MAAS_ADMIN_PASS"
echo "============================================================"
echo ""
echo "Network topology (7 bridges, 6 MAAS spaces):"
printf "  %-12s %-22s %-22s %s\n" "Bridge" "Subnet" "Space" "Purpose"
printf "  %-12s %-22s %-22s %s\n" "mgmt" "${MGMT_SUBNET_PREFIX}.0/24" "space-management" "Management"
printf "  %-12s %-22s %-22s %s\n" "internal" "${INTERNAL_SUBNET_PREFIX}.0/24" "space-internal" "Internal API, AMQP"
printf "  %-12s %-22s %-22s %s\n" "data" "${DATA_SUBNET_PREFIX}.0/24" "space-data" "Migration, VM data"
printf "  %-12s %-22s %-22s %s\n" "storage" "${STORAGE_SUBNET_PREFIX}.0/24" "space-storage" "Ceph client"
printf "  %-12s %-22s %-22s %s\n" "stcluster" "${STCLUSTER_SUBNET_PREFIX}.0/24" "space-storage-cluster" "Ceph replication"
printf "  %-12s %-22s %-22s %s\n" "public" "${PUBLIC_SUBNET_PREFIX}.0/24" "space-public" "API endpoints"
printf "  %-12s %-22s %-22s %s\n" "external" "${EXTERNAL_SUBNET_PREFIX}.0/24" "(none)" "Floating IPs"
echo ""
echo "Enabled features:"
for feat in VAULT SECRETS LOADBALANCER DNS ORCHESTRATION TELEMETRY \
	OBSERVABILITY RESOURCE_OPT IMAGES_SYNC SHARED_FS TLS \
	VALIDATION BAREMETAL CAAS INSTANCE_RECOVERY LDAP PRO; do
	var="ENABLE_$feat"
	printf "  %-25s %s\n" "$feat" "${!var}"
done
echo ""
if [[ "$ENABLE_VAULT" == "true" && -f /root/vault-keys/root-token.txt ]]; then
	echo "Vault unseal key:  $(cat /root/vault-keys/unseal-key.txt)"
	echo "Vault root token:  $(cat /root/vault-keys/root-token.txt)"
	echo ""
fi
echo "Observability dashboard: sunbeam observability dashboard-url"
echo "Run tempest refstack:    sunbeam validation run refstack"
echo ""
