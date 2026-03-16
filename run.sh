#!/bin/bash

set -e
set -u

cd "$(dirname "$0")"

# ============================================================================
# CONFIGURATION
# ============================================================================
CONTAINER_NAME="${CONTAINER_NAME:-microstack}"
LXD_IP="${LXD_IP:-10.0.9.11}"
SSH_PROXY_PORT="${SSH_PROXY_PORT:-10911}"
LXD_IMAGE="${LXD_IMAGE:-ubuntu:jammy}"

# ============================================================================
# LXD Profile
# ============================================================================
lxc profile create "$CONTAINER_NAME" 2>/dev/null || true
lxc profile device add "$CONTAINER_NAME" kvm unix-char path=/dev/kvm 2>/dev/null || true
lxc profile device add "$CONTAINER_NAME" vhost-net unix-char path=/dev/vhost-net mode=0600 2>/dev/null || true
lxc profile set "$CONTAINER_NAME" security.nesting true
lxc profile set "$CONTAINER_NAME" boot.autostart false

# ============================================================================
# Launch Container
# ============================================================================
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
