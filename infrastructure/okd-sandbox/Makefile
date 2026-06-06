# OKD sandbox cluster — operator-facing entry points.
# Run from infrastructure/okd-sandbox/ on iac-control. See README.md for prereqs.

SHELL          := /usr/bin/env bash
.SHELLFLAGS    := -eu -o pipefail -c
.DEFAULT_GOAL  := help

ROOT           := $(abspath .)
WORK           := $(ROOT)/_work
TF_DIR         := $(ROOT)/terraform
INSTALL_DIR    := $(ROOT)/install
SCRIPTS_DIR    := $(ROOT)/scripts
POSTINST_DIR   := $(ROOT)/post-install

ISO_NAME       := okd-sandbox-agent.x86_64.iso
PVE_HOSTS      := pve3 208-pve2  # both hosts that run masters need the ISO
ISO_REMOTE_DIR := /var/lib/vz/template/iso

KUBECONFIG     := $(WORK)/auth/kubeconfig
export KUBECONFIG

# ---- Targets ----------------------------------------------------------------

.PHONY: help
help:  ## Show this help.
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z0-9_-]+:.*?## / {printf "  \033[1m%-22s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

.PHONY: prereq
prereq:  ## Verify Vault token, Proxmox API, mirror reachability, IP collisions, openshift-install version.
	@bash $(SCRIPTS_DIR)/prereq.sh

.PHONY: render
render:  ## Render install-config.yaml + agent-config.yaml from templates (Vault-backed).
	@bash $(INSTALL_DIR)/render.sh

.PHONY: iso
iso: render  ## Generate the agent.x86_64.iso (~1 GB) into _work/.
	@bash $(SCRIPTS_DIR)/make-iso.sh

.PHONY: upload-iso
upload-iso:  ## scp the ISO to /var/lib/vz/template/iso on each PVE host.
	@test -f $(WORK)/agent.x86_64.iso || { echo "Run 'make iso' first."; exit 1; }
	@for h in $(PVE_HOSTS); do \
	  echo "[upload-iso] scp -> $$h:$(ISO_REMOTE_DIR)/$(ISO_NAME)"; \
	  scp -o BatchMode=yes -o StrictHostKeyChecking=no \
	    $(WORK)/agent.x86_64.iso root@$$h:$(ISO_REMOTE_DIR)/$(ISO_NAME); \
	done

.PHONY: tf-init
tf-init:  ## terraform init (MinIO S3 backend).
	@cd $(TF_DIR) && tofu init

.PHONY: apply
apply: tf-init  ## terraform apply — create the 3 master VMs.
	@cd $(TF_DIR) && \
	  TF_VAR_proxmox_api_token="$$(VAULT_ADDR=$${VAULT_ADDR:-https://vault.208.haist.farm} vault kv get -field=api_token secret/proxmox/terraform-prov)" \
	  TF_VAR_ssh_public_key="$$(cat $(WORK)/ssh_key.pub)" \
	  tofu apply -auto-approve

.PHONY: wait-bootstrap
wait-bootstrap:  ## Wait up to 35min for bootstrap-complete (control plane forms).
	@openshift-install agent wait-for bootstrap-complete --dir $(WORK)/manifests --log-level=info

.PHONY: wait-install
wait-install:  ## Wait up to 90min for install-complete (cluster operators ready).
	@openshift-install agent wait-for install-complete --dir $(WORK)/manifests --log-level=info

.PHONY: post-install
post-install:  ## Apply Local Storage Operator + LocalVolume + default-SC patch (Q5).
	@oc apply -f $(POSTINST_DIR)/01-local-storage-operator.yaml
	@echo "[post-install] waiting for local-storage-operator CSV (up to 5 min)..."
	@for i in $$(seq 1 60); do \
	  PHASE=$$(oc -n openshift-local-storage get csv -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true); \
	  if [ "$$PHASE" = "Succeeded" ]; then echo "[post-install] CSV Succeeded"; break; fi; \
	  echo "  ($$i/60) CSV phase=$${PHASE:-<none>}"; sleep 5; \
	done
	@oc apply -f $(POSTINST_DIR)/02-local-volume.yaml
	@bash $(POSTINST_DIR)/03-default-storageclass.sh

.PHONY: stash
stash:  ## Write kubeconfig + kubeadmin-password + api_url to Vault.
	@bash $(SCRIPTS_DIR)/stash-kubeconfig.sh

.PHONY: smoke
smoke:  ## Validation suite — see runbook §Validation.
	@echo "===== nodes ====="              && oc get nodes
	@echo "===== clusteroperators ====="   && oc get co
	@echo "===== storageclasses ====="     && oc get sc
	@echo "===== persistentvolumes =====" && oc get pv
	@echo "===== etcd member health ====="
	@oc -n openshift-etcd exec etcd-$$(oc get nodes -l node-role.kubernetes.io/master -o name | head -1 | cut -d/ -f2) \
	    -- etcdctl --cacert=/etc/kubernetes/static-pod-certs/configmaps/etcd-serving-ca/ca-bundle.crt \
	               --cert=/etc/kubernetes/static-pod-certs/secrets/etcd-all-certs/etcd-peer-$$(oc get nodes -l node-role.kubernetes.io/master -o name | head -1 | cut -d/ -f2).crt \
	               --key=/etc/kubernetes/static-pod-certs/secrets/etcd-all-certs/etcd-peer-$$(oc get nodes -l node-role.kubernetes.io/master -o name | head -1 | cut -d/ -f2).key \
	               endpoint health --cluster || true

.PHONY: teardown
teardown:  ## Destroy VMs (soft). Use 'make teardown-hard' to also drop Vault stash + ISOs.
	@bash $(SCRIPTS_DIR)/teardown.sh soft

.PHONY: teardown-hard
teardown-hard:  ## Soft teardown + remove Vault stash, _work/, and ISOs from PVE hosts.
	@bash $(SCRIPTS_DIR)/teardown.sh hard

.PHONY: clean
clean:  ## Remove _work/ only (keep VMs and Vault stash).
	@rm -rf $(WORK)
	@echo "removed $(WORK)"

# ---- Upgrade pipeline triggers (OPS-269) ----------------------------------
# These wrap the Forgejo Actions workflow so an operator can trigger the
# pipeline from iac-control without leaving the shell. Two flavours:
#   make upgrade-dry-run  — workflow_dispatch with dry_run=true (preflight + validate)
#   make upgrade          — guarded; reminds the operator that the real
#                           trigger is committing cluster-version.yaml
# Requires `forgejo` CLI on PATH (or `gh` configured against the Forgejo
# host as a generic git server — the Actions trigger API is gh-compatible).

FORGEJO_REPO        := sentinel-admin/sentinel-iac
FORGEJO_HOST        := forgejo.208.haist.farm
UPGRADE_WORKFLOW    := okd-upgrade-sandbox.yaml

.PHONY: upgrade-dry-run
upgrade-dry-run:  ## OPS-269: trigger upgrade workflow in dry-run mode (preflight + validate, NO `oc adm upgrade`).
	@if command -v forgejo >/dev/null 2>&1; then \
	  forgejo workflow run $(UPGRADE_WORKFLOW) -R $(FORGEJO_REPO) -F dry_run=true -F allow_not_recommended=true; \
	elif command -v gh >/dev/null 2>&1; then \
	  GH_HOST=$(FORGEJO_HOST) gh workflow run $(UPGRADE_WORKFLOW) -R $(FORGEJO_REPO) -f dry_run=true -f allow_not_recommended=true; \
	else \
	  echo "Need either 'forgejo' or 'gh' CLI on PATH. Falling back: open"; \
	  echo "  https://$(FORGEJO_HOST)/$(FORGEJO_REPO)/actions/workflows/$(UPGRADE_WORKFLOW)"; \
	  echo "and click Run workflow."; \
	  exit 1; \
	fi

.PHONY: upgrade
upgrade:  ## OPS-269: refuses; the proper trigger is committing cluster-version.yaml. See README.
	@echo "[upgrade] This Makefile target intentionally refuses to start an upgrade directly."
	@echo "[upgrade] The change-control gate IS the cluster-version.yaml commit on main."
	@echo "[upgrade] To upgrade:"
	@echo "[upgrade]   1. Edit infrastructure/okd-sandbox/cluster-version.yaml (bump desiredVersion + desiredImage)."
	@echo "[upgrade]   2. Open a PR. Judge validates the digest is in the upgrade graph."
	@echo "[upgrade]   3. Merge to main → .forgejo/workflows/okd-upgrade-sandbox.yaml fires."
	@echo "[upgrade] To rehearse without upgrading: 'make upgrade-dry-run'."
	@false

# ---- Convenience: full bring-up sequence ------------------------------------
.PHONY: all
all: prereq render iso upload-iso apply wait-bootstrap wait-install post-install stash smoke  ## End-to-end bring-up.
