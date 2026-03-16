CONTAINER_NAME ?= microstack
LXD_IP         ?= 10.0.9.11
SSH_PROXY_PORT ?= 10911
LXD_IMAGE      ?= ubuntu:jammy

# Subnet prefixes (must match user-script.sh)
EXTERNAL_SUBNET_PREFIX ?= 192.168.172

SSH_OPTS := -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR

LIBVIRT_NETS := mgmt internal data storage stcluster public external

.PHONY: help deploy stop start restart status reapply-fixes \
        start-vms stop-vms start-networks wait-maas wait-compute-ssh \
        reboot-compute wait-k8s unseal-vault recover-juju wait-juju \
        ssh destroy

help: ## Show available targets
	@echo "MicroStack MAAS Lab - Container Lifecycle Management"
	@echo ""
	@echo "Usage: make <target>"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  %-24s %s\n", $$1, $$2}'
	@echo ""
	@echo "Typical workflow:"
	@echo "  make deploy    # first-time setup (creates container + runs cloud-init)"
	@echo "  make stop      # gracefully stop everything"
	@echo "  make start     # bring everything back up (networks, VMs, vault, Juju)"
	@echo "  make status    # check health of all components"

# ============================================================================
# DEPLOY (first-time only)
# ============================================================================

deploy: ## First-time deployment (creates container, runs cloud-init)
	./run.sh

# ============================================================================
# STOP - Graceful shutdown: VMs -> container
# ============================================================================

stop: stop-vms ## Gracefully stop VMs then the container
	@echo ">>> Stopping LXC container '$(CONTAINER_NAME)'..."
	lxc stop $(CONTAINER_NAME) --timeout 120
	@echo ">>> Container stopped."

stop-vms: ## Stop all libvirt VMs inside the container (graceful ACPI shutdown)
	@echo ">>> Shutting down VMs inside '$(CONTAINER_NAME)'..."
	@for vm in $$(lxc exec $(CONTAINER_NAME) -- virsh list --name --state-running 2>/dev/null); do \
		echo "  Shutting down VM: $$vm"; \
		lxc exec $(CONTAINER_NAME) -- virsh shutdown "$$vm" 2>/dev/null || true; \
	done
	@echo ">>> Waiting for VMs to power off (up to 120s)..."
	@timeout=120; elapsed=0; \
	while [ $$elapsed -lt $$timeout ]; do \
		running=$$(lxc exec $(CONTAINER_NAME) -- virsh list --name --state-running 2>/dev/null | grep -c . || true); \
		if [ "$$running" -eq 0 ]; then \
			echo ">>> All VMs are off."; \
			break; \
		fi; \
		echo "  $$running VM(s) still running ($$elapsed/$$timeout s)..."; \
		sleep 5; \
		elapsed=$$((elapsed + 5)); \
	done
	@# Force-off any stragglers
	@for vm in $$(lxc exec $(CONTAINER_NAME) -- virsh list --name --state-running 2>/dev/null); do \
		echo "  Force-stopping VM: $$vm"; \
		lxc exec $(CONTAINER_NAME) -- virsh destroy "$$vm" 2>/dev/null || true; \
	done

# ============================================================================
# START - Container -> networks -> services -> VMs -> fixes
# ============================================================================

start: ## Start container, VMs, and re-apply all ephemeral network fixes
	@echo ">>> Starting LXC container '$(CONTAINER_NAME)'..."
	@lxc start $(CONTAINER_NAME) 2>/dev/null || echo "  (container may already be running)"
	@echo ">>> Waiting for container to be ready..."
	@timeout=60; elapsed=0; \
	while [ $$elapsed -lt $$timeout ]; do \
		if lxc exec $(CONTAINER_NAME) -- systemctl is-system-running --wait 2>/dev/null | grep -qE 'running|degraded'; then \
			echo ">>> Container systemd is ready."; \
			break; \
		fi; \
		sleep 3; \
		elapsed=$$((elapsed + 3)); \
	done
	@$(MAKE) --no-print-directory start-networks
	@$(MAKE) --no-print-directory start-vms
	@$(MAKE) --no-print-directory wait-maas
	@$(MAKE) --no-print-directory wait-compute-ssh
	@$(MAKE) --no-print-directory reboot-compute
	@$(MAKE) --no-print-directory wait-compute-ssh
	@$(MAKE) --no-print-directory reapply-fixes
	@$(MAKE) --no-print-directory wait-k8s
	@$(MAKE) --no-print-directory unseal-vault
	@$(MAKE) --no-print-directory recover-juju
	@$(MAKE) --no-print-directory wait-juju
	@echo ""
	@echo ">>> Environment is ready!"
	@echo "    MAAS UI: http://$(LXD_IP):5240/MAAS"
	@echo "    SSH:     ssh into container or use 'make ssh'"

start-networks: ## Start libvirt networks (stops BIND to avoid port conflict)
	@echo ">>> Ensuring libvirtd is running..."
	@lxc exec $(CONTAINER_NAME) -- systemctl is-active --quiet libvirtd.service 2>/dev/null || \
		lxc exec $(CONTAINER_NAME) -- systemctl start libvirtd.service
	@echo ">>> Checking libvirt network state..."
	@needs_restart=false; \
	for net in $(LIBVIRT_NETS); do \
		if ! lxc exec $(CONTAINER_NAME) -- virsh net-info "$$net" 2>/dev/null | grep -q "Active:.*yes"; then \
			needs_restart=true; \
			break; \
		fi; \
	done; \
	if [ "$$needs_restart" = "true" ]; then \
		echo ">>> Some networks are inactive. Stopping BIND (named) to free port 53..."; \
		lxc exec $(CONTAINER_NAME) -- systemctl stop named.service 2>/dev/null || true; \
		sleep 2; \
		for net in $(LIBVIRT_NETS); do \
			if ! lxc exec $(CONTAINER_NAME) -- virsh net-info "$$net" 2>/dev/null | grep -q "Active:.*yes"; then \
				echo "  Starting libvirt network: $$net"; \
				lxc exec $(CONTAINER_NAME) -- virsh net-start "$$net" 2>/dev/null || \
					echo "  WARNING: Failed to start network $$net"; \
			else \
				echo "  Network $$net: already active"; \
			fi; \
		done; \
		echo ">>> Restarting BIND (named)..."; \
		lxc exec $(CONTAINER_NAME) -- systemctl start named.service; \
		echo ">>> Restarting MAAS rackd (to pick up new bridges)..."; \
		lxc exec $(CONTAINER_NAME) -- systemctl restart maas-rackd.service; \
	else \
		echo ">>> All libvirt networks are already active."; \
	fi
	@echo ">>> Waiting for MAAS regiond..."
	@timeout=90; elapsed=0; \
	while [ $$elapsed -lt $$timeout ]; do \
		if lxc exec $(CONTAINER_NAME) -- systemctl is-active --quiet maas-regiond.service 2>/dev/null; then \
			echo ">>> MAAS regiond is running."; \
			break; \
		fi; \
		sleep 3; \
		elapsed=$$((elapsed + 3)); \
	done
	@echo ">>> Waiting for MAAS rackd..."
	@timeout=90; elapsed=0; \
	while [ $$elapsed -lt $$timeout ]; do \
		if lxc exec $(CONTAINER_NAME) -- systemctl is-active --quiet maas-rackd.service 2>/dev/null; then \
			echo ">>> MAAS rackd is running."; \
			break; \
		fi; \
		sleep 3; \
		elapsed=$$((elapsed + 3)); \
	done

start-vms: ## Start all libvirt VMs inside the container
	@echo ">>> Starting VMs inside '$(CONTAINER_NAME)'..."
	@for vm in $$(lxc exec $(CONTAINER_NAME) -- virsh list --all --name 2>/dev/null); do \
		state=$$(lxc exec $(CONTAINER_NAME) -- virsh domstate "$$vm" 2>/dev/null || echo "unknown"); \
		if echo "$$state" | grep -q "shut off"; then \
			echo "  Starting VM: $$vm"; \
			lxc exec $(CONTAINER_NAME) -- virsh start "$$vm" 2>/dev/null || true; \
		else \
			echo "  VM $$vm: already $$state"; \
		fi; \
	done
	@echo ">>> VMs started. Waiting for services to come up..."

wait-maas: ## Wait for MAAS to recognize all machines as Deployed
	@echo ">>> Waiting for MAAS API to be reachable..."
	@timeout=120; elapsed=0; \
	while [ $$elapsed -lt $$timeout ]; do \
		if lxc exec $(CONTAINER_NAME) -- maas admin machines read 2>/dev/null | grep -q system_id; then \
			echo ">>> MAAS API is responding."; \
			break; \
		fi; \
		sleep 5; \
		elapsed=$$((elapsed + 5)); \
	done
	@echo ">>> Checking MAAS machine states..."
	@lxc exec $(CONTAINER_NAME) -- bash -c '\
		maas admin machines read 2>/dev/null | \
		jq -r ".[] | \"\(.hostname): \(.status_name)\"" \
	' || echo "  (could not query MAAS)"

wait-compute-ssh: ## Wait for compute-1 to be reachable via SSH
	@echo ">>> Discovering compute-1 management IP..."
	$(eval COMPUTE1_MGMT_IP := $(shell lxc exec $(CONTAINER_NAME) -- bash -c '\
		maas admin interfaces read $$(maas admin nodes read | \
		jq -r ".[] | select(.hostname == \"compute-1\") | .system_id") | \
		jq -r ".[] | select(.name == \"enp1s0\") | .links[] | select(.ip_address != null) | .ip_address" | head -1 \
	' 2>/dev/null))
	@if [ -z "$(COMPUTE1_MGMT_IP)" ]; then \
		echo "ERROR: Could not determine compute-1 IP."; \
		exit 1; \
	fi
	@echo "  compute-1 IP: $(COMPUTE1_MGMT_IP)"
	@echo ">>> Waiting for compute-1 SSH to be ready (up to 300s)..."
	@timeout=300; elapsed=0; \
	while [ $$elapsed -lt $$timeout ]; do \
		if lxc exec $(CONTAINER_NAME) -- ssh $(SSH_OPTS) -o ConnectTimeout=5 ubuntu@$(COMPUTE1_MGMT_IP) \
			"echo ok" >/dev/null 2>&1; then \
			echo ">>> compute-1 SSH is ready."; \
			break; \
		fi; \
		echo "  SSH not ready yet ($$elapsed/$$timeout s)..."; \
		sleep 10; \
		elapsed=$$((elapsed + 10)); \
	done; \
	if [ $$elapsed -ge $$timeout ]; then \
		echo "ERROR: compute-1 SSH not reachable after $${timeout}s"; \
		exit 1; \
	fi

reboot-compute: ## Reboot compute-1 VM (fixes Cilium BPF state after container restart)
	@echo ">>> Rebooting compute-1 to restore Cilium pod networking..."
	@lxc exec $(CONTAINER_NAME) -- virsh reboot compute-1
	@echo "  Waiting 30s for VM to begin rebooting..."
	@sleep 30

wait-k8s: ## Wait for Kubernetes pods to be running
	@echo ">>> Checking Kubernetes pod health on compute-1..."
	$(eval COMPUTE1_MGMT_IP := $(shell lxc exec $(CONTAINER_NAME) -- bash -c '\
		maas admin interfaces read $$(maas admin nodes read | \
		jq -r ".[] | select(.hostname == \"compute-1\") | .system_id") | \
		jq -r ".[] | select(.name == \"enp1s0\") | .links[] | select(.ip_address != null) | .ip_address" | head -1 \
	' 2>/dev/null))
	@echo ">>> Waiting for CoreDNS to be ready (up to 300s)..."
	@timeout=300; elapsed=0; \
	while [ $$elapsed -lt $$timeout ]; do \
		ready=$$(lxc exec $(CONTAINER_NAME) -- ssh $(SSH_OPTS) -o ConnectTimeout=5 ubuntu@$(COMPUTE1_MGMT_IP) \
			"sudo k8s kubectl get pods -n kube-system -l k8s-app=kube-dns --no-headers 2>/dev/null | grep '1/1.*Running'" 2>/dev/null || true); \
		if [ -n "$$ready" ]; then \
			echo ">>> CoreDNS is ready."; \
			break; \
		fi; \
		echo "  CoreDNS not ready yet ($$elapsed/$$timeout s)..."; \
		sleep 15; \
		elapsed=$$((elapsed + 15)); \
	done
	@echo ">>> K8s pod summary (kube-system):"
	@lxc exec $(CONTAINER_NAME) -- ssh $(SSH_OPTS) ubuntu@$(COMPUTE1_MGMT_IP) \
		"sudo k8s kubectl get pods -n kube-system --no-headers 2>/dev/null" 2>/dev/null || echo "  (could not query)"
	@echo ">>> K8s pod summary (openstack):"
	@lxc exec $(CONTAINER_NAME) -- ssh $(SSH_OPTS) ubuntu@$(COMPUTE1_MGMT_IP) \
		"sudo k8s kubectl get pods -n openstack --no-headers 2>/dev/null | awk '{print \$$3}' | sort | uniq -c | sort -rn" 2>/dev/null || echo "  (could not query)"

# ============================================================================
# REAPPLY FIXES - All ephemeral state that is lost on reboot
# ============================================================================

reapply-fixes: ## Re-apply all ephemeral fixes (iptables, routes, ip rules)
	@echo ">>> Pushing reapply-fixes.sh into the container..."
	@lxc file push reapply-fixes.sh $(CONTAINER_NAME)/root/reapply-fixes.sh --mode 0755
	@echo ">>> Running fixes inside the container..."
	@lxc exec $(CONTAINER_NAME) -- /root/reapply-fixes.sh

# ============================================================================
# VAULT UNSEAL - Vault seals itself on pod restart
# ============================================================================

VAULT_UNSEAL_KEY_PATH ?= /root/vault-keys/unseal-key.txt
VAULT_K8S_SVC_IP     ?= $(shell lxc exec $(CONTAINER_NAME) -- bash -c '\
	ssh $(SSH_OPTS) ubuntu@$$(maas admin interfaces read $$(maas admin nodes read | \
	jq -r ".[] | select(.hostname == \"compute-1\") | .system_id") | \
	jq -r ".[] | select(.name == \"enp1s0\") | .links[] | select(.ip_address != null) | .ip_address" | head -1) \
	"sudo k8s kubectl get svc vault -n openstack -o jsonpath={.spec.clusterIP}" 2>/dev/null' 2>/dev/null)

unseal-vault: ## Unseal Vault after restart (required for TLS certs)
	@echo ">>> Checking Vault seal status..."
	$(eval COMPUTE1_MGMT_IP := $(shell lxc exec $(CONTAINER_NAME) -- bash -c '\
		maas admin interfaces read $$(maas admin nodes read | \
		jq -r ".[] | select(.hostname == \"compute-1\") | .system_id") | \
		jq -r ".[] | select(.name == \"enp1s0\") | .links[] | select(.ip_address != null) | .ip_address" | head -1 \
	' 2>/dev/null))
	$(eval VAULT_SVC_IP := $(shell lxc exec $(CONTAINER_NAME) -- ssh $(SSH_OPTS) ubuntu@$(COMPUTE1_MGMT_IP) \
		"sudo k8s kubectl get svc vault -n openstack -o jsonpath='{.spec.clusterIP}'" 2>/dev/null))
	$(eval VAULT_KEY := $(shell lxc exec $(CONTAINER_NAME) -- cat $(VAULT_UNSEAL_KEY_PATH) 2>/dev/null))
	@if [ -z "$(VAULT_KEY)" ]; then \
		echo "WARNING: No unseal key found at $(VAULT_UNSEAL_KEY_PATH), skipping vault unseal."; \
		exit 0; \
	fi
	@sealed=$$(lxc exec $(CONTAINER_NAME) -- ssh $(SSH_OPTS) ubuntu@$(COMPUTE1_MGMT_IP) \
		"sudo k8s kubectl exec -n openstack vault-0 -c vault -- vault status -tls-skip-verify \
		-address=https://$(VAULT_SVC_IP):8200 -format=json 2>/dev/null" 2>/dev/null | \
		python3 -c "import sys,json; print(json.load(sys.stdin).get('sealed','unknown'))" 2>/dev/null || echo "unknown"); \
	if [ "$$sealed" = "true" ]; then \
		echo ">>> Vault is sealed. Unsealing..."; \
		lxc exec $(CONTAINER_NAME) -- ssh $(SSH_OPTS) ubuntu@$(COMPUTE1_MGMT_IP) \
			"sudo k8s kubectl exec -n openstack vault-0 -c vault -- vault operator unseal \
			-tls-skip-verify -address=https://$(VAULT_SVC_IP):8200 '$(VAULT_KEY)'" 2>/dev/null; \
		echo ">>> Vault unsealed. Triggering charm update..."; \
		sleep 5; \
		lxc exec $(CONTAINER_NAME) -- juju exec --unit vault/0 -- \
			"JUJU_DISPATCH_PATH=hooks/update-status ./dispatch" 2>/dev/null || true; \
		echo ">>> Waiting for vault/0 to become active (up to 60s)..."; \
		timeout=60; elapsed=0; \
		while [ $$elapsed -lt $$timeout ]; do \
			ws=$$(lxc exec $(CONTAINER_NAME) -- juju status vault --format short 2>&1 | grep 'vault/0' || true); \
			if echo "$$ws" | grep -q 'workload:active'; then \
				echo ">>> vault/0 is active."; \
				break; \
			fi; \
			sleep 5; \
			elapsed=$$((elapsed + 5)); \
		done; \
	elif [ "$$sealed" = "false" ]; then \
		echo ">>> Vault is already unsealed."; \
	else \
		echo "WARNING: Could not determine vault seal status (vault pod may still be starting). Retrying in 30s..."; \
		sleep 30; \
		sealed=$$(lxc exec $(CONTAINER_NAME) -- ssh $(SSH_OPTS) ubuntu@$(COMPUTE1_MGMT_IP) \
			"sudo k8s kubectl exec -n openstack vault-0 -c vault -- vault status -tls-skip-verify \
			-address=https://$(VAULT_SVC_IP):8200 -format=json 2>/dev/null" 2>/dev/null | \
			python3 -c "import sys,json; print(json.load(sys.stdin).get('sealed','unknown'))" 2>/dev/null || echo "unknown"); \
		if [ "$$sealed" = "true" ]; then \
			echo ">>> Vault is sealed. Unsealing..."; \
			lxc exec $(CONTAINER_NAME) -- ssh $(SSH_OPTS) ubuntu@$(COMPUTE1_MGMT_IP) \
				"sudo k8s kubectl exec -n openstack vault-0 -c vault -- vault operator unseal \
				-tls-skip-verify -address=https://$(VAULT_SVC_IP):8200 '$(VAULT_KEY)'" 2>/dev/null; \
			sleep 5; \
			lxc exec $(CONTAINER_NAME) -- juju exec --unit vault/0 -- \
				"JUJU_DISPATCH_PATH=hooks/update-status ./dispatch" 2>/dev/null || true; \
			echo ">>> Waiting for vault/0 to become active (up to 60s)..."; \
			timeout=60; elapsed=0; \
			while [ $$elapsed -lt $$timeout ]; do \
				ws=$$(lxc exec $(CONTAINER_NAME) -- juju status vault --format short 2>&1 | grep 'vault/0' || true); \
				if echo "$$ws" | grep -q 'workload:active'; then \
					echo ">>> vault/0 is active."; \
					break; \
				fi; \
				sleep 5; \
				elapsed=$$((elapsed + 5)); \
			done; \
		elif [ "$$sealed" = "false" ]; then \
			echo ">>> Vault is already unsealed."; \
		else \
			echo "WARNING: Could not determine vault status. You may need to run 'make unseal-vault' manually."; \
		fi; \
	fi

# ============================================================================
# JUJU RECOVERY - Fix broken charm units after pod restarts
# ============================================================================

recover-juju: ## Force-delete broken pods and resolve Juju error units
	@echo ">>> Checking for Juju units in error state..."
	$(eval COMPUTE1_MGMT_IP := $(shell lxc exec $(CONTAINER_NAME) -- bash -c '\
		maas admin interfaces read $$(maas admin nodes read | \
		jq -r ".[] | select(.hostname == \"compute-1\") | .system_id") | \
		jq -r ".[] | select(.name == \"enp1s0\") | .links[] | select(.ip_address != null) | .ip_address" | head -1 \
	' 2>/dev/null))
	@error_units=$$(lxc exec $(CONTAINER_NAME) -- juju status --format short 2>&1 | \
		grep 'workload:error' | sed 's/^- //' | cut -d: -f1 | sed 's/ *$$//'); \
	if [ -z "$$error_units" ]; then \
		echo ">>> No units in error state. Nothing to do."; \
		exit 0; \
	fi; \
	echo ">>> Found error units: $$(echo $$error_units | tr '\n' ' ')"; \
	echo ">>> Force-deleting pods for error units (to get fresh charm files)..."; \
	for unit in $$error_units; do \
		pod_name=$$(echo "$$unit" | sed 's|/|-|'); \
		echo "  Deleting pod: $$pod_name"; \
		lxc exec $(CONTAINER_NAME) -- ssh $(SSH_OPTS) ubuntu@$(COMPUTE1_MGMT_IP) \
			"sudo k8s kubectl delete pod $$pod_name -n openstack --grace-period=0 --force" 2>/dev/null || true; \
	done; \
	echo ">>> Waiting 60s for pods to recreate..."; \
	sleep 60; \
	echo ">>> Resolving error units (round 1)..."; \
	for unit in $$error_units; do \
		lxc exec $(CONTAINER_NAME) -- juju resolved "$$unit" 2>/dev/null || true; \
	done; \
	sleep 30; \
	echo ">>> Resolving any remaining error units (round 2)..."; \
	error_units2=$$(lxc exec $(CONTAINER_NAME) -- juju status --format short 2>&1 | \
		grep 'workload:error' | sed 's/^- //' | cut -d: -f1 | sed 's/ *$$//'); \
	for unit in $$error_units2; do \
		lxc exec $(CONTAINER_NAME) -- juju resolved "$$unit" 2>/dev/null || true; \
	done

wait-juju: ## Wait for all Juju units to leave error state (up to 300s)
	@echo ">>> Waiting for all Juju units to recover (up to 300s)..."
	@timeout=300; elapsed=0; \
	while [ $$elapsed -lt $$timeout ]; do \
		errors=$$(lxc exec $(CONTAINER_NAME) -- juju status --format short 2>&1 | \
			grep -c 'workload:error' || true); \
		if [ "$$errors" -eq 0 ]; then \
			echo ">>> All Juju units recovered."; \
			break; \
		fi; \
		echo "  $$errors unit(s) still in error ($$elapsed/$$timeout s)..."; \
		resolve_units=$$(lxc exec $(CONTAINER_NAME) -- juju status --format short 2>&1 | \
			grep 'workload:error' | sed 's/^- //' | cut -d: -f1 | sed 's/ *$$//'); \
		for unit in $$resolve_units; do \
			lxc exec $(CONTAINER_NAME) -- juju resolved "$$unit" 2>/dev/null || true; \
		done; \
		sleep 30; \
		elapsed=$$((elapsed + 30)); \
	done; \
	if [ $$elapsed -ge $$timeout ]; then \
		echo "WARNING: Some units still in error after $${timeout}s. Check with 'juju status'."; \
	fi
	@echo ">>> Juju status:"
	@lxc exec $(CONTAINER_NAME) -- juju status --format short 2>&1

# ============================================================================
# STATUS - Health check
# ============================================================================

status: ## Show status of container, VMs, services, and network
	@echo "=== LXC Container ==="
	@lxc list $(CONTAINER_NAME) -f compact 2>/dev/null || echo "  Container not found"
	@echo ""
	@echo "=== Libvirt Networks ==="
	@lxc exec $(CONTAINER_NAME) -- virsh net-list --all 2>/dev/null || echo "  (container not running)"
	@echo ""
	@echo "=== Libvirt VMs ==="
	@lxc exec $(CONTAINER_NAME) -- virsh list --all 2>/dev/null || echo "  (container not running)"
	@echo ""
	@echo "=== MAAS Services ==="
	@lxc exec $(CONTAINER_NAME) -- systemctl is-active maas-regiond.service 2>/dev/null || echo "  regiond: unknown"
	@lxc exec $(CONTAINER_NAME) -- systemctl is-active maas-rackd.service 2>/dev/null || echo "  rackd: unknown"
	@echo ""
	@echo "=== MAAS Machines ==="
	@lxc exec $(CONTAINER_NAME) -- bash -c '\
		maas admin machines read 2>/dev/null | \
		jq -r ".[] | \"\(.hostname): \(.status_name) (power: \(.power_state))\"" \
	' 2>/dev/null || echo "  (cannot query MAAS)"
	@echo ""
	@echo "=== iptables DNAT rules (nat OUTPUT chain) ==="
	@lxc exec $(CONTAINER_NAME) -- iptables -t nat -L OUTPUT -n 2>/dev/null | grep DNAT || echo "  (none)"
	@echo ""
	@echo "=== External network route ==="
	@lxc exec $(CONTAINER_NAME) -- ip route show $(EXTERNAL_SUBNET_PREFIX).0/24 2>/dev/null || echo "  (none)"
	@echo ""
	@echo "=== compute-1 ip rules (pod-to-Ceph) ==="
	@COMPUTE1_IP=$$(lxc exec $(CONTAINER_NAME) -- bash -c '\
		maas admin interfaces read $$(maas admin nodes read | \
		jq -r ".[] | select(.hostname == \"compute-1\") | .system_id") | \
		jq -r ".[] | select(.name == \"enp1s0\") | .links[] | select(.ip_address != null) | .ip_address" | head -1 \
	' 2>/dev/null); \
	if [ -n "$$COMPUTE1_IP" ]; then \
		lxc exec $(CONTAINER_NAME) -- ssh $(SSH_OPTS) ubuntu@$$COMPUTE1_IP \
			"sudo ip rule show | grep '10.1.0.0/24'" 2>/dev/null || echo "  (not set)"; \
	else \
		echo "  (compute-1 IP unknown)"; \
	fi
	@echo ""
	@echo "=== compute-1 br-ex IP ==="
	@COMPUTE1_IP=$$(lxc exec $(CONTAINER_NAME) -- bash -c '\
		maas admin interfaces read $$(maas admin nodes read | \
		jq -r ".[] | select(.hostname == \"compute-1\") | .system_id") | \
		jq -r ".[] | select(.name == \"enp1s0\") | .links[] | select(.ip_address != null) | .ip_address" | head -1 \
	' 2>/dev/null); \
	if [ -n "$$COMPUTE1_IP" ]; then \
		lxc exec $(CONTAINER_NAME) -- ssh $(SSH_OPTS) ubuntu@$$COMPUTE1_IP \
			"ip addr show br-ex 2>/dev/null | grep inet" 2>/dev/null || echo "  (no IP on br-ex)"; \
	else \
		echo "  (compute-1 IP unknown)"; \
	fi
	@echo ""
	@echo "=== Kubernetes Pods (kube-system) ==="
	@COMPUTE1_IP=$$(lxc exec $(CONTAINER_NAME) -- bash -c '\
		maas admin interfaces read $$(maas admin nodes read | \
		jq -r ".[] | select(.hostname == \"compute-1\") | .system_id") | \
		jq -r ".[] | select(.name == \"enp1s0\") | .links[] | select(.ip_address != null) | .ip_address" | head -1 \
	' 2>/dev/null); \
	if [ -n "$$COMPUTE1_IP" ]; then \
		lxc exec $(CONTAINER_NAME) -- ssh $(SSH_OPTS) ubuntu@$$COMPUTE1_IP \
			"sudo k8s kubectl get pods -n kube-system --no-headers 2>/dev/null" 2>/dev/null || echo "  (could not query)"; \
	else \
		echo "  (compute-1 IP unknown)"; \
	fi
	@echo ""
	@echo "=== Kubernetes Pods (openstack summary) ==="
	@COMPUTE1_IP=$$(lxc exec $(CONTAINER_NAME) -- bash -c '\
		maas admin interfaces read $$(maas admin nodes read | \
		jq -r ".[] | select(.hostname == \"compute-1\") | .system_id") | \
		jq -r ".[] | select(.name == \"enp1s0\") | .links[] | select(.ip_address != null) | .ip_address" | head -1 \
	' 2>/dev/null); \
	if [ -n "$$COMPUTE1_IP" ]; then \
		lxc exec $(CONTAINER_NAME) -- ssh $(SSH_OPTS) ubuntu@$$COMPUTE1_IP \
			"sudo k8s kubectl get pods -n openstack --no-headers 2>/dev/null | awk '{print \$$3}' | sort | uniq -c | sort -rn" 2>/dev/null || echo "  (could not query)"; \
	else \
		echo "  (compute-1 IP unknown)"; \
	fi
	@echo ""
	@echo "=== Juju Units ==="
	@lxc exec $(CONTAINER_NAME) -- juju status --format short 2>/dev/null || echo "  (could not query Juju)"

# ============================================================================
# CONVENIENCE
# ============================================================================

restart: stop start ## Stop then start the full environment

ssh: ## SSH into the container as ubuntu
	@lxc exec $(CONTAINER_NAME) -- sudo -iu ubuntu

destroy: ## Destroy the container and all state (IRREVERSIBLE)
	@echo "WARNING: This will destroy '$(CONTAINER_NAME)' and all VMs inside it."
	@read -p "Are you sure? [y/N] " confirm; \
	if [ "$$confirm" = "y" ] || [ "$$confirm" = "Y" ]; then \
		lxc delete --force $(CONTAINER_NAME) 2>/dev/null || true; \
		echo "Container destroyed."; \
	else \
		echo "Aborted."; \
	fi
