#!/bin/bash

set -e
set -u
set -x

trap cleanup SIGHUP SIGINT SIGTERM EXIT

function cleanup () {
    mv /root/.maascli.db ~ubuntu/ || true
    mv /root/.local ~ubuntu/ || true
    mv /root/.kube ~ubuntu/ || true
    mv /root/.ssh/id_* ~ubuntu/.ssh/ || true
    mv /root/* ~ubuntu/ || true
    chown -f ubuntu:ubuntu -R ~ubuntu
}

# try not to kill some commands by session management
# it seems like a race condition with MAAS jobs in root user and snapped
# juju command's systemd scope
# LP: #1921876, LP: #2058030
loginctl enable-linger root

export DEBIAN_FRONTEND=noninteractive
mkdir -p /root/.local/share/juju/ssh/ # LP: #2029515
cd ~/

MAAS_PPA='ppa:maas/3.5'

# proxy
if host squid-deb-proxy.lxd >/dev/null; then
    http_proxy="http://$(dig +short squid-deb-proxy.lxd):8000/"
    echo "Acquire::http::Proxy \"${http_proxy}\";" > /etc/apt/apt.conf
fi

# ppa
apt-add-repository -y "$MAAS_PPA"

apt-get update

# utils
eatmydata apt-get install -y tree jq

# KVM setup
eatmydata apt-get install -y libvirt-daemon-system
eatmydata apt-get install -y virtinst --no-install-recommends

cat >> /etc/libvirt/qemu.conf <<EOF

# Avoid the error in LXD containers:
# Unable to set XATTR trusted.libvirt.security.dac on
# /var/lib/libvirt/qemu/domain-*: Operation not permitted
remember_owner = 0
EOF

systemctl restart libvirtd.service

virsh net-destroy default
virsh net-autostart --disable default

virsh pool-define-as default dir --target /var/lib/libvirt/images
virsh pool-autostart default
virsh pool-start default

cat <<EOF | virsh net-define /dev/stdin
<network>
  <name>maas</name>
  <bridge name='maas' stp='off'/>
  <forward mode='nat'/>
  <ip address='192.168.151.1' netmask='255.255.255.0'/>
</network>
EOF
virsh net-autostart maas
virsh net-start maas


cat <<EOF | virsh net-define /dev/stdin
<network>
  <name>public</name>
  <bridge name='public' stp='off'/>
  <forward mode='nat'/>
  <ip address='192.168.171.1' netmask='255.255.255.0'/>
</network>
EOF
virsh net-autostart public
virsh net-start public

# maas package install
echo maas-region-controller maas/default-maas-url string 192.168.151.1 \
    | debconf-set-selections
eatmydata apt-get install -y maas

# maas login as ubuntu/ubuntu
maas createadmin --username ubuntu --password ubuntu \
    --email ubuntu@localhost.localdomain

# LP: #2031842
sleep 30
maas login admin http://localhost:5240/MAAS "$(maas apikey --username ubuntu)"

ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N ''
maas admin sshkeys create key="$(cat ~/.ssh/id_ed25519.pub)"

maas admin maas set-config name=enable_analytics value=false
maas admin maas set-config name=release_notifications value=false
maas admin maas set-config name=maas_name value='Demo'
maas admin maas set-config name=kernel_opts value='console=tty0 console=ttyS0,115200n8'
maas admin maas set-config name=completed_intro value=true

# configure network / DHCP
maas admin subnet update 192.168.151.0/24 \
    gateway_ip=192.168.151.1 \
    dns_servers=192.168.151.1

maas admin subnet update 192.168.171.0/24 \
    gateway_ip=192.168.171.1 \
    dns_servers=192.168.171.1

fabric=$(maas admin subnets read | jq -r \
    '.[] | select(.cidr=="192.168.151.0/24").vlan.fabric')
maas admin ipranges create type=reserved \
    start_ip=192.168.151.1 end_ip=192.168.151.100
maas admin ipranges create type=dynamic \
    start_ip=192.168.151.201 end_ip=192.168.151.254
maas admin vlan update "$fabric" 0 dhcp_on=true primary_rack="$HOSTNAME"

fabric=$(maas admin subnets read | jq -r \
    '.[] | select(.cidr=="192.168.171.0/24").vlan.fabric')
maas admin ipranges create type=reserved \
    start_ip=192.168.171.1 end_ip=192.168.171.100
maas admin ipranges create type=dynamic \
    start_ip=192.168.171.201 end_ip=192.168.171.254
maas admin vlan update "$fabric" 0 dhcp_on=true primary_rack="$HOSTNAME"

maas admin spaces create name=space-first
fabric_id=$(maas admin subnets read | jq -r '.[] | select(.cidr=="192.168.151.0/24").vlan.fabric_id')
maas admin vlan update "$fabric_id" 0 space=space-first


maas admin spaces create name=space-second
fabric_id=$(maas admin subnets read | jq -r '.[] | select(.cidr=="192.168.171.0/24").vlan.fabric_id')
maas admin vlan update "$fabric_id" 0 space=space-second

maas admin boot-source-selections create 1 os=ubuntu release=noble arches=amd64 subarches='*' labels='*'
maas admin boot-resources import

# wait image
time while [ "$(maas admin boot-resources is-importing)" = 'true' ]; do
    sleep 15
done

#sleep 120

# MAAS Pod
sudo -u maas -H ssh-keygen -t ed25519 -f ~maas/.ssh/id_ed25519 -N ''
install -m 0600 ~maas/.ssh/id_ed25519.pub /root/.ssh/authorized_keys

# "pod compose" is not going to be used
# but register the KVM host just for the UI demo purpose
maas admin pods create \
    type=virsh \
    cpu_over_commit_ratio=10 \
    memory_over_commit_ratio=1.5 \
    name=localhost \
    power_address='qemu+ssh://root@127.0.0.1/system'


# compose machines
num_machines=1
for i in $(seq 1 "$num_machines"); do
    # TODO: --boot uefi
    # Starting vTPM manufacturing as swtpm:swtpm
    # swtpm process terminated unexpectedly.
    # Could not start the TPM 2.
    # An error occurred. Authoring the TPM state failed.
    virt-install \
        --import --noreboot \
        --name "compute-$i"\
        --osinfo ubuntujammy \
        --boot network,hd \
        --vcpus cores=16 \
        --cpu host-passthrough,cache.mode=passthrough \
        --memory 16384 \
        --disk size=600,format=raw,target.rotation_rate=1,target.bus=scsi,cache=unsafe \
        --disk size=600,format=raw,target.rotation_rate=1,target.bus=scsi,cache=unsafe \
        --network network=maas \
        --network network=public 

    maas admin machines create \
        hostname="compute-$i" \
        architecture=amd64 \
        mac_addresses="$(virsh dumpxml "compute-$i" | xmllint --xpath 'string(//mac/@address)' -)" \
        power_type=virsh \
        power_parameters_power_address='qemu+ssh://root@127.0.0.1/system' \
        power_parameters_power_id="compute-$i"
done


#juju
virt-install \
    --import --noreboot \
    --name "juju"\
    --osinfo ubuntujammy \
    --boot network,hd \
    --vcpus cores=2 \
    --cpu host-passthrough,cache.mode=passthrough \
    --memory 4096 \
    --disk size=600,format=raw,target.rotation_rate=1,target.bus=scsi,cache=unsafe \
    --network network=maas \
    --network network=public 

maas admin machines create \
    hostname="juju" \
    architecture=amd64 \
    mac_addresses="$(virsh dumpxml "juju" | xmllint --xpath 'string(//mac/@address)' -)" \
    power_type=virsh \
    power_parameters_power_address='qemu+ssh://root@127.0.0.1/system' \
    power_parameters_power_id="juju"

#sunbeam


virt-install \
    --import --noreboot \
    --name "sunbeam"\
    --osinfo ubuntujammy \
    --boot network,hd \
    --vcpus cores=2 \
    --cpu host-passthrough,cache.mode=passthrough \
    --memory 4096 \
    --disk size=600,format=raw,target.rotation_rate=1,target.bus=scsi,cache=unsafe \
    --network network=maas \
    --network network=public 

maas admin machines create \
    hostname="sunbeam" \
    architecture=amd64 \
    mac_addresses="$(virsh dumpxml "sunbeam" | xmllint --xpath 'string(//mac/@address)' -)" \
    power_type=virsh \
    power_parameters_power_address='qemu+ssh://root@127.0.0.1/system' \
    power_parameters_power_id="sunbeam"

maas admin ipranges create type=reserved \
    start_ip="192.168.151.101" end_ip=192.168.151.105 \
    comment='mycloud-internal-api'

maas admin ipranges create type=reserved \
    start_ip="192.168.151.106" end_ip=192.168.151.115 \
    comment='mycloud-public-api'


#TAGS
## COMPUTE
while true; do
	status=$(maas admin machines read | jq -r ".[] | select(.hostname == \"compute-$i\") | .status_name")
	if [[ "$status" == "Ready" ]]; then
	    echo "Machine $i is ready!"
	    break
	fi
	echo "Waiting for machine $i to be commissioned (current status: $status)..."
	sleep 15
done

TAGS=(
      "openstack-mycloud"
      "control"
      "compute"
      "storage"
	)


for tag in ${TAGS[@]}; do
	set +eu
	maas admin tags create name=$tag
	set -eu
done

for i in $(seq 1 "$num_machines"); do
	system_id=$(maas admin nodes read | jq -r ".[] | select(.hostname == \"compute-$i\") | .system_id")
	block_device_id=$(maas admin block-devices read $system_id | jq -r '.[] | select(.path == "/dev/disk/by-dname/sdb") | .id')
	interface_id=$(maas admin interfaces read $system_id | jq -r '.[] | select(.name == "enp2s0") | .id')
	for tag in ${TAGS[@]}; do
		maas admin block-device add-tag $system_id $block_device_id tag="ceph"
		maas admin interface add-tag $system_id $interface_id tag="neutron:physnet1"
		maas admin tag update-nodes $tag add=$system_id
	done
done
#JUJU
while true; do
    status=$(maas admin machines read | jq -r ".[] | select(.hostname == \"juju\") | .status_name")
    if [[ "$status" == "Ready" ]]; then
        echo "Machine juju is ready!"
        break
    fi
    echo "Waiting for machine juju to be commissioned (current status: $status)..."
    sleep 15
done
TAGS=(
	"juju-controller"
	"openstack-mycloud"
	)
for tag in ${TAGS[@]}; do
	set +eu
	maas admin tags create name=$tag
	set -eu
done
system_id=$(maas admin  nodes read | jq -r '.[] | select(.hostname == "juju") | .system_id')
for tag in ${TAGS[@]}; do
	maas admin tag update-nodes $tag add=$system_id
done
# SUNBEAM
while true; do
    status=$(maas admin machines read | jq -r ".[] | select(.hostname == \"sunbeam\") | .status_name")
    if [[ "$status" == "Ready" ]]; then
        echo "Machine sunbeam is ready!"
        break
    fi
    echo "Waiting for machine sunbeam to be commissioned (current status: $status)..."
    sleep 15
done
TAGS=(
	"openstack-mycloud" 
	"sunbeam"
	)

for tag in ${TAGS[@]}; do 
	set +eu
	maas admin tags create name=$tag
	set -eu
done	
system_id=$(maas admin  nodes read | jq -r '.[] | select(.hostname == "sunbeam") | .system_id')
for tag in ${TAGS[@]}; do 
	maas admin tag update-nodes $tag add=$system_id
done	


sudo snap install openstack --channel 2024.1/edge
sunbeam prepare-node-script --client | bash -x
sunbeam deployment add maas mycloud $(sudo maas apikey --username=ubuntu)  http://10.0.9.11:5240/MAAS
sunbeam deployment space map space-first
validate_output=$(sunbeam deployment validate)
# Check if the validation output contains 'FAIL'
if echo "$validate_output" | grep -q "FAIL"; then
    echo "Validation failed. Exiting..."
    exit 1
else
    echo "Validation passed. Continuing..."
fi
sunbeam cluster bootstrap --accept-defaults
sunbeam cluster deploy --accept-defaults
