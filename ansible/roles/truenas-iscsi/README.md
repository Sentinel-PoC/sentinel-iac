# truenas-iscsi

Ansible role for idempotent iSCSI provisioning on TrueNAS SCALE via the REST API.

**Tracking:** OPS-1011 (child of OPS-947 truenas-zfs role)  
**API target:** TrueNAS SCALE REST API v2.0 (source-verified against TrueNAS-25.10.3.1)

---

## What it does

Creates and manages the four resources that constitute an iSCSI LUN on TrueNAS:

1. **Extent** — declares the backing storage (zvol or file)
2. **Target** — declares the iSCSI target (IQN name + portal group)
3. **Target-to-extent mapping** — links target to extent with a LUN ID (presented to initiators)

All create operations are idempotent: the role performs a GET first and skips POST
if a resource with the given name already exists.

---

## Prerequisites

- TrueNAS API token in Vault: `secret/truenas` (field: `api_token`)
- For zvol-backed extents: the zvol must already exist (use the `truenas-zfs` role's
  `zvol_create` task to create it)
- At least one iSCSI portal must exist on TrueNAS (default portal tag=1 is assumed)

---

## Task groups

Set `truenas_iscsi_tasks` to a list of the task groups you want to run:

| Task group | Description | Destructive? |
|---|---|---|
| `list` | Read-only: enumerate all extents, targets, targetextents | No |
| `extent_create` | Create zvol- or file-backed extent if absent | No |
| `target_create` | Create iSCSI target if absent | No |
| `targetextent_create` | Create target→extent LUN mapping if absent | No |
| `targetextent_destroy` | Delete LUN mapping (requires `confirm_destroy: true`) | **YES** |
| `target_destroy` | Delete iSCSI target (requires `confirm_destroy: true`) | **YES** |
| `extent_destroy` | Delete iSCSI extent (requires `confirm_destroy: true`) | **YES** |

Default: `truenas_iscsi_tasks: [list]` — safe read-only.

---

## Destroy order

**CRITICAL:** TrueNAS rejects deleting an extent or target that is still referenced
by a targetextent (LUN mapping). Always destroy in this order:

```
targetextent_destroy → target_destroy → extent_destroy
```

Set `truenas_iscsi_tasks` accordingly:

```yaml
truenas_iscsi_tasks:
  - targetextent_destroy
  - target_destroy
  - extent_destroy
confirm_destroy: true
```

---

## Usage examples

### Provision a new iSCSI LUN (3-step)

```yaml
- name: Provision minio-replica iSCSI LUN
  hosts: localhost
  connection: local
  vars:
    truenas_api_token: "{{ lookup('community.hashi_vault.hashi_vault', 'secret/truenas:api_token') }}"
    truenas_url: "https://192.168.12.205"  # or https://data.haist.farm if DNS available
    truenas_validate_certs: false

    truenas_iscsi_tasks:
      - extent_create
      - target_create
      - targetextent_create

    # Step 1: Extent (zvol must already exist — create with truenas-zfs zvol_create)
    truenas_iscsi_extent_name: "okd-minio-replica-data"
    truenas_iscsi_extent_type: "DISK"
    truenas_iscsi_extent_disk: "zvol/SSD/iscsi-okd/minio-replica-data"
    truenas_iscsi_extent_comment: "OPS-932 — minio replica data LUN"

    # Step 2: Target
    truenas_iscsi_target_name: "okd-minio-replica-data"
    truenas_iscsi_target_portal_id: 1       # OKD iSCSI portal
    truenas_iscsi_target_initiator_id: 1    # OKD cluster initiator group

    # Step 3: LUN mapping
    truenas_iscsi_targetextent_target_name: "okd-minio-replica-data"
    truenas_iscsi_targetextent_extent_name: "okd-minio-replica-data"
    truenas_iscsi_targetextent_lunid: 0

  roles:
    - role: truenas-iscsi
```

### Gather (read-only, verify state)

```bash
ansible-playbook ansible/playbooks/gather-truenas-iscsi.yml \
  -e "truenas_api_token=$(vault kv get -field=api_token secret/truenas)" \
  -e "truenas_url=https://192.168.12.205"
```

### Decommission a LUN (safe destroy order)

```yaml
truenas_iscsi_tasks:
  - targetextent_destroy
  - target_destroy
  - extent_destroy
confirm_destroy: true

truenas_iscsi_targetextent_target_name: "okd-minio-replica-data"
truenas_iscsi_targetextent_extent_name: "okd-minio-replica-data"
truenas_iscsi_extent_name: "okd-minio-replica-data"
truenas_iscsi_target_name: "okd-minio-replica-data"
```

---

## Key variables

| Variable | Default | Description |
|---|---|---|
| `truenas_url` | `https://data.haist.farm` | TrueNAS base URL |
| `truenas_validate_certs` | `false` | Skip TLS cert validation |
| `truenas_iscsi_tasks` | `[list]` | Task groups to run |
| `confirm_destroy` | `false` | Safety gate for destroy tasks |
| `truenas_iscsi_extent_name` | `""` | Extent name |
| `truenas_iscsi_extent_type` | `DISK` | `DISK` or `FILE` |
| `truenas_iscsi_extent_disk` | `""` | zvol path for DISK type: `zvol/POOL/PATH` |
| `truenas_iscsi_extent_filepath` | `""` | Filesystem path for FILE type |
| `truenas_iscsi_extent_blocksize` | `512` | Block size (512 or 4096) |
| `truenas_iscsi_extent_rpm` | `SSD` | RPM hint: `SSD`, `5400`, `7200`, etc. |
| `truenas_iscsi_target_name` | `""` | Target name (IQN suffix) |
| `truenas_iscsi_target_portal_id` | `1` | Portal ID (1 = OKD global portal) |
| `truenas_iscsi_target_initiator_id` | `null` | Initiator group ID (`null` = allow all) |
| `truenas_iscsi_target_authmethod` | `NONE` | Auth: `NONE` or `CHAP` |
| `truenas_iscsi_targetextent_target_name` | `""` | Target name for LUN mapping |
| `truenas_iscsi_targetextent_extent_name` | `""` | Extent name for LUN mapping |
| `truenas_iscsi_targetextent_lunid` | `0` | LUN ID |

See `defaults/main.yml` for full documentation.

---

## Related

- `truenas-zfs` role — ZFS dataset/zvol/snapshot management (OPS-947)
- `gather-truenas-iscsi.yml` — read-only gather playbook for this role
- `truenas-zfs-gather.yml` — gather playbook for the ZFS role
- OPS-932 — minio-replica provisioning that drove this role's creation
