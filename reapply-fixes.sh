#!/bin/bash
# reapply-fixes.sh - Re-apply ephemeral fixes after container/VM restart
# Run inside the LXC container as root.
#
# This script re-applies all networking fixes that are lost on reboot:
#   Fix 2: Pod-to-Ceph routing rule on compute-1
#   Fix 3: iptables DNAT rules for MetalLB VIPs
#   Fix 4a: br-ex IP on compute-1
#   Fix 4b: External network route on container

set -eu

# ============================================================================
# Configuration (must match user-script.sh)
# ============================================================================
MGMT_SUBNET_PREFIX="${MGMT_SUBNET_PREFIX:-192.168.151}"
EXTERNAL_SUBNET_PREFIX="${EXTERNAL_SUBNET_PREFIX:-192.168.172}"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10"

# ============================================================================
# Discover compute-1 management IP
# ============================================================================
echo ">>> Discovering compute-1 management IP..."
COMPUTE1_SYSTEM_ID=$(maas admin nodes read | jq -r '.[] | select(.hostname == "compute-1") | .system_id')
COMPUTE1_MGMT_IP=$(maas admin interfaces read "$COMPUTE1_SYSTEM_ID" | jq -r '
    .[] | select(.name == "enp1s0") | .links[] | select(.ip_address != null) | .ip_address' | head -1)

if [ -z "$COMPUTE1_MGMT_IP" ]; then
	echo "ERROR: Could not determine compute-1 IP."
	exit 1
fi
echo "  compute-1 IP: $COMPUTE1_MGMT_IP"

# ============================================================================
# Fix 2: Pod-to-Ceph routing rule on compute-1
# ============================================================================
echo ">>> Fix 2: Pod-to-Ceph routing rule on compute-1..."
ssh $SSH_OPTS ubuntu@"$COMPUTE1_MGMT_IP" \
	"sudo ip rule add to 10.1.0.0/24 lookup main prio 100 2>/dev/null || true"
echo "  Done."

# ============================================================================
# Fix 3: iptables DNAT rules for MetalLB VIP reachability
# ============================================================================
echo ">>> Fix 3: Creating iptables DNAT rules for MetalLB VIPs..."

create_traefik_dnat() {
	local svc_name="$1"
	local vip np_http np_https

	vip=$(ssh $SSH_OPTS ubuntu@"$COMPUTE1_MGMT_IP" \
		"sudo k8s kubectl get svc -n openstack ${svc_name} \
         -o jsonpath='{.status.loadBalancer.ingress[0].ip}'" 2>/dev/null || true)

	if [ -z "$vip" ]; then
		echo "  ${svc_name}: no VIP found, skipping"
		return
	fi
	echo "  ${svc_name} VIP: $vip"

	np_http=$(ssh $SSH_OPTS ubuntu@"$COMPUTE1_MGMT_IP" \
		"sudo k8s kubectl get svc -n openstack ${svc_name} \
         -o 'jsonpath={.spec.ports[?(@.port==80)].nodePort}'" 2>/dev/null || true)
	np_https=$(ssh $SSH_OPTS ubuntu@"$COMPUTE1_MGMT_IP" \
		"sudo k8s kubectl get svc -n openstack ${svc_name} \
         -o 'jsonpath={.spec.ports[?(@.port==443)].nodePort}'" 2>/dev/null || true)

	if [ -n "$np_http" ]; then
		iptables -t nat -C OUTPUT -d "$vip" -p tcp --dport 80 \
			-j DNAT --to-destination "${COMPUTE1_MGMT_IP}:${np_http}" 2>/dev/null ||
			iptables -t nat -A OUTPUT -d "$vip" -p tcp --dport 80 \
				-j DNAT --to-destination "${COMPUTE1_MGMT_IP}:${np_http}"
		echo "    DNAT: ${vip}:80 -> ${COMPUTE1_MGMT_IP}:${np_http}"
	fi
	if [ -n "$np_https" ]; then
		iptables -t nat -C OUTPUT -d "$vip" -p tcp --dport 443 \
			-j DNAT --to-destination "${COMPUTE1_MGMT_IP}:${np_https}" 2>/dev/null ||
			iptables -t nat -A OUTPUT -d "$vip" -p tcp --dport 443 \
				-j DNAT --to-destination "${COMPUTE1_MGMT_IP}:${np_https}"
		echo "    DNAT: ${vip}:443 -> ${COMPUTE1_MGMT_IP}:${np_https}"
	fi
}

create_traefik_dnat "traefik-public-lb"
create_traefik_dnat "traefik-lb"
create_traefik_dnat "traefik-rgw-lb"

# ============================================================================
# Fix 4a: br-ex IP on compute-1
# ============================================================================
echo ">>> Fix 4a: br-ex IP on compute-1..."
ssh $SSH_OPTS ubuntu@"$COMPUTE1_MGMT_IP" \
	"sudo ip link set br-ex up 2>/dev/null || true; \
	 sudo ip addr add ${EXTERNAL_SUBNET_PREFIX}.2/24 dev br-ex 2>/dev/null || true"
echo "  Done."

# ============================================================================
# Fix 4b: External network route on container
# ============================================================================
echo ">>> Fix 4b: External network route on container..."
ip route add "${EXTERNAL_SUBNET_PREFIX}.0/24" via "$COMPUTE1_MGMT_IP" 2>/dev/null || true
echo "  Done."

echo ""
echo ">>> All fixes re-applied successfully."
