#!/bin/bash

set -e
set -u

cd "$(dirname "$0")"

lxc profile create microstack 2>/dev/null || true
lxc profile device add microstack kvm unix-char path=/dev/kvm 2>/dev/null || true
lxc profile device add microstack vhost-net unix-char path=/dev/vhost-net mode=0600 2>/dev/null || true
lxc profile set microstack security.nesting true
lxc profile set microstack boot.autostart false

lxc init ubuntu:jammy microstack \
    -p default -p microstack \
    -c user.user-data="$(cat user-script.sh)"

lxc network attach lxdbr0 microstack eth0 eth0
lxc config device set microstack eth0 ipv4.address 10.0.9.11
lxc config device add microstack proxy-ssh proxy \
    listen=tcp:0.0.0.0:10911 connect=tcp:127.0.0.1:22

lxc start microstack

sleep 15

lxc file push -p --uid 1000 --gid 1000 --mode 0600 ~/.ssh/authorized_keys microstack/home/ubuntu/.ssh/

if which ts >/dev/null; then
    lxc exec -t microstack -- tail -f -n+1 /var/log/cloud-init-output.log | ts
else
    lxc exec -t microstack -- tail -f -n+1 /var/log/cloud-init-output.log
fi
