#!/bin/bash

set -e
set -u

cd "$(dirname "$0")"

# ============================================================================
# CONFIGURATION
# ============================================================================
CONTAINER_NAME="${CONTAINER_NAME:-microstack}"
PROXY_CONTAINER_NAME="${PROXY_CONTAINER_NAME:-proxy-cache}"
LXD_IP="${LXD_IP:-10.0.9.11}"
PROXY_IP="${PROXY_IP:-10.0.9.10}"
SSH_PROXY_PORT="${SSH_PROXY_PORT:-10911}"
LXD_IMAGE="${LXD_IMAGE:-ubuntu:jammy}"
ENABLE_PROXY="${ENABLE_PROXY:-true}"
MAAS_IMAGE_STREAM="${MAAS_IMAGE_STREAM:-stable}"
MAAS_IMAGE_RELEASES="${MAAS_IMAGE_RELEASES:-jammy,noble}"

# ============================================================================
# LXD Profile
# ============================================================================
lxc profile create "$CONTAINER_NAME" 2>/dev/null || true
lxc profile device add "$CONTAINER_NAME" kvm unix-char path=/dev/kvm 2>/dev/null || true
lxc profile device add "$CONTAINER_NAME" vhost-net unix-char path=/dev/vhost-net mode=0600 2>/dev/null || true
lxc profile set "$CONTAINER_NAME" security.nesting true
lxc profile set "$CONTAINER_NAME" boot.autostart false

# ============================================================================
# Launch Proxy Container (optional)
# ============================================================================
if [[ "$ENABLE_PROXY" == "true" ]]; then
	# Check if proxy container already exists and is running
	if lxc info "$PROXY_CONTAINER_NAME" >/dev/null 2>&1; then
		if lxc info "$PROXY_CONTAINER_NAME" | grep -qi "Status: running"; then
			echo "==> Proxy container '$PROXY_CONTAINER_NAME' already running"
		else
			echo "==> Proxy container '$PROXY_CONTAINER_NAME' exists but stopped, starting..."
			lxc start "$PROXY_CONTAINER_NAME"
			sleep 5
		fi
	else
		echo "==> Launching proxy cache container..."

		# Cloud-init user-data for proxy container
		cat >/tmp/proxy-user-data.yaml <<EOF
#cloud-config
package_update: true
packages:
  - squid-deb-proxy
  - squid
  - simplestreams
  - nginx
runcmd:
  # Configure squid to allow the LXD network
  - |
    cat > /etc/squid/conf.d/deb-proxy.conf <<'SQUID'
    acl LXD_NET src 10.0.9.0/24
    http_access allow LXD_NET
    http_port 8000
    cache_dir ufs /var/spool/squid 5000 16 256
    maximum_object_size 4096 MB
    cache_swap_low 90
    cache_swap_high 95
    SQUID
  # Restart squid to apply config
  - systemctl restart squid
  - systemctl enable squid

  # Setup nginx for MAAS images
  - mkdir -p /var/www/html/maas/images/ephemeral-v3/${MAAS_IMAGE_STREAM}
  - chown -R www-data:www-data /var/www/html/maas

  # Configure nginx to serve /images from /var/www/html/maas/images
  - |
    cat > /etc/nginx/sites-available/maas-images <<'NGINX'
    server {
        listen 80;
        server_name _;
        root /var/www/html;
        location /images/ {
            alias /var/www/html/maas/images/;
            autoindex on;
        }
    }
    NGINX
  - rm -f /etc/nginx/sites-enabled/default
  - ln -sf /etc/nginx/sites-available/maas-images /etc/nginx/sites-enabled/
  - systemctl restart nginx
  - systemctl enable nginx

  # Create image sync script
  - |
    cat > /usr/local/bin/sync-maas-images.sh <<'SYNC'
    #!/bin/bash
    set -e
    KEYRING=/usr/share/keyrings/ubuntu-cloudimage-keyring.gpg
    IMAGE_DIR=/var/www/html/maas/images/ephemeral-v3/${MAAS_IMAGE_STREAM}
    IMAGE_SRC=https://images.maas.io/ephemeral-v3/${MAAS_IMAGE_STREAM}
    
    echo "==> Starting MAAS image mirror sync..."
    
    # Build filter for releases
    RELEASE_FILTER=$(echo "${MAAS_IMAGE_RELEASES}" | tr ',' '|' | sed 's/|/\\|/g')
    
    # Mirror images
    sstream-mirror --keyring=\$KEYRING \$IMAGE_SRC \$IMAGE_DIR \
        "arch=amd64" "release~(\${RELEASE_FILTER})" --max=1 --progress || true
    
    # Also mirror bootloaders and kernels
    sstream-mirror --keyring=\$KEYRING \$IMAGE_SRC \$IMAGE_DIR \
        "arch=amd64" "type=bootloader" --max=1 --progress || true
    
    # Create ready marker
    touch /var/www/html/maas/images/mirror-ready
    echo "==> MAAS image mirror sync complete"
    SYNC
  - chmod +x /usr/local/bin/sync-maas-images.sh

  # Start image sync in background
  - nohup /usr/local/bin/sync-maas-images.sh > /var/log/maas-mirror.log 2>&1 &
  - echo "MAAS image sync started in background"
EOF

		lxc init "$LXD_IMAGE" "$PROXY_CONTAINER_NAME" \
			-p default \
			-c user.user-data="$(cat /tmp/proxy-user-data.yaml)"

		lxc network attach lxdbr0 "$PROXY_CONTAINER_NAME" eth0 eth0
		lxc config device set "$PROXY_CONTAINER_NAME" eth0 ipv4.address "$PROXY_IP"

		lxc start "$PROXY_CONTAINER_NAME"
		sleep 15

		echo "Proxy cache container '$PROXY_CONTAINER_NAME' started at $PROXY_IP"
	fi
fi

# ============================================================================
# Launch Container
# ============================================================================
if lxc info "$CONTAINER_NAME" >/dev/null 2>&1; then
	if lxc info "$CONTAINER_NAME" | grep -qi "Status: running"; then
		echo "==> Container '$CONTAINER_NAME' already running"
	else
		echo "==> Container '$CONTAINER_NAME' exists but stopped, starting..."
		lxc start "$CONTAINER_NAME"
		sleep 15
	fi
else
	echo "==> Creating and starting container '$CONTAINER_NAME'..."
	lxc init "$LXD_IMAGE" "$CONTAINER_NAME" \
		-p default -p "$CONTAINER_NAME" \
		-c user.user-data="$(cat user-script.sh)"

	lxc network attach lxdbr0 "$CONTAINER_NAME" eth0 eth0
	lxc config device set "$CONTAINER_NAME" eth0 ipv4.address "$LXD_IP"
	lxc config device add "$CONTAINER_NAME" proxy-ssh proxy \
		"listen=tcp:0.0.0.0:${SSH_PROXY_PORT}" connect=tcp:127.0.0.1:22

	lxc start "$CONTAINER_NAME"
	sleep 15

	# Push SSH keys into the container
	lxc file push -p --uid 1000 --gid 1000 --mode 0600 \
		~/.ssh/authorized_keys "${CONTAINER_NAME}/home/ubuntu/.ssh/"
fi

# ============================================================================
# Monitor cloud-init progress
# ============================================================================
while true; do
	status=$(lxc exec -t "$CONTAINER_NAME" -- cloud-init status | grep -oP '^status:\s+\K\w+')
	if [[ "$status" != "running" ]]; then
		notify-send "${CONTAINER_NAME} deployment" "Current status: $status" 2>/dev/null || true
		exit
	fi
	sleep 15
done &

if which ts >/dev/null 2>&1; then
	lxc exec -t "$CONTAINER_NAME" -- tail -f -n+1 /var/log/cloud-init-output.log | ts
else
	lxc exec -t "$CONTAINER_NAME" -- tail -f -n+1 /var/log/cloud-init-output.log
fi
