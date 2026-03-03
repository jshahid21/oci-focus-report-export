# OCI Cost Reports → AWS S3: Architecture & Maintenance Guide

This document explains every component for someone maintaining this project. Start here if you need to understand or change how it works.

---

## 1. High-Level Flow

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  OCI bling (cost reports)                                                   │
│  Restricted namespace — requires special IAM policy                         │
└─────────────────────────────────┬───────────────────────────────────────────┘
                                  │
                                  ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│  Sync VM (Oracle Linux)                                                     │
│  • Instance Principal = no OCI API keys on the VM                           │
│  • Fetches AWS keys from OCI Vault at sync time                             │
│  • rclone syncs bling → S3 every 6 hours (cron)                             │
└─────────────────────────────────┬───────────────────────────────────────────┘
                                  │
                                  ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│  AWS S3 bucket                                                              │
│  Your cost reports land in aws_s3_bucket_name / aws_s3_prefix               │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. File-by-File Breakdown

### `infra/providers.tf`
**Purpose:** Configures OpenTofu/Terraform and the OCI provider.

| Section | What it does |
|---------|--------------|
| `terraform` block | Requires OpenTofu 1.5+ and the Oracle OCI provider |
| `provider "oci"` | Uses `~/.oci/config` (DEFAULT profile) for authentication. This is for **you** when you run `tofu apply` — the VM never uses this. |

**When to change:** Rarely. Only if you switch regions or use a different OCI config profile.

---

### `infra/variables.tf`
**Purpose:** Declares all configurable inputs. Values come from `terraform.tfvars`.

| Variable Group | Key Variables | What They Control |
|----------------|---------------|-------------------|
| **Identity** | `region`, `tenancy_ocid` | OCI region and tenancy |
| **Compartment** | `create_compartment`, `existing_compartment_id` | Default compartment for all resources |
| **Compartment overrides** | `compute_compartment_id`, `network_compartment_id`, `vault_compartment_id` | Optional per-resource compartment overrides; fall back to `existing_compartment_id` when empty |
| **Network** | `create_vcn`, `create_subnet`, `create_nat_gateway`, `create_service_gateway` | Create new network or use existing (brownfield). Sync VM is always private. |
| **Bastion VM** | `create_bastion`, `bastion_subnet_cidr`, `ssh_public_key_path` | Optional jump host in a new public subnet. Works with new or existing VCNs. |
| **Bastion Service** | `use_bastion_service`, `bastion_service_allowed_cidrs` | OCI managed SSH — no extra VM, no public subnet. Mutually exclusive with `create_bastion`. |
| **Vault** | `create_vault`, `create_key`, `create_aws_secrets` | Create Vault/KMS/secrets or use existing |
| **AWS** | `aws_access_key`, `aws_secret_key`, `aws_s3_bucket_name`, `aws_region` | AWS creds (stored in Vault) and S3 destination |
| **Monitoring** | `enable_monitoring`, `alert_email_address` | Email alerts on failure |
| **Compute** | `instance_shape`, `instance_ocpus`, `instance_memory_gb` | VM size |

**When to change:** When adding new features or adjusting defaults.

---

### `infra/main.tf`
**Purpose:** Core infrastructure — compartment, VCN, subnet, NAT, service gateway, Vault, secrets, compute instance, and optional SSH access methods.

| Section | Resources | Logic |
|---------|-----------|-------|
| **locals** | `compartment_id`, `compute_compartment_id`, `network_compartment_id`, `vault_compartment_id`, etc. | Resolves create vs existing; per-resource compartment overrides fall back to base compartment |
| **Compartment** | `oci_identity_compartment` | Created only if `create_compartment = true` |
| **VCN** | `oci_core_vcn` | Created only if `create_vcn = true`; otherwise uses `existing_vcn_id` |
| **NAT Gateway** | `oci_core_nat_gateway` | Internet egress for the sync VM (→ AWS S3). Create or use existing. |
| **Service Gateway** | `oci_core_service_gateway` | Private path to OCI Object Storage / bling. Create or use existing. |
| **Route Table** | `oci_core_route_table.private` | Only created with new subnet. Routes: 0.0.0.0/0 → NAT, Object Storage CIDR → Service GW. |
| **Private Subnet** | `oci_core_subnet.this` | `prohibit_public_ip_on_vnic = true`. Sync VM always here. |
| **Bastion VM** | `oci_core_instance.bastion`, IGW, subnet, RT, SL | Created when `create_bastion = true`. Owns its own IGW and public subnet within the VCN. |
| **OCI Bastion Service** | `oci_bastion_bastion` | Created when `use_bastion_service = true`. Targets the private subnet. No extra VM or subnet. |
| **Vault** | `oci_kms_vault`, `oci_kms_key` | Encrypts secrets at rest. In `vault_compartment_id`. |
| **Secrets** | `oci_vault_secret.aws_access_key`, `oci_vault_secret.aws_secret_key` | Stores AWS keys (base64). In `vault_compartment_id`. |
| **Compute** | `oci_core_instance.rclone_sync` | Sync VM. Always private (`assign_public_ip = false`). Bastion plugin enabled when `use_bastion_service = true`. In `compute_compartment_id`. |

**Critical:** The `metadata.user_data` is rendered from `cloud-init.yaml` using `templatefile()`. Changing cloud-init requires replacing the instance (`tofu apply -replace=oci_core_instance.rclone_sync`).

---

### `infra/iam.tf`
**Purpose:** Identity and access. Defines the dynamic group and policies that let the VM access bling and Vault without API keys.

| Resource | What it does |
|----------|---------------|
| **oci_identity_dynamic_group.rclone_dg** | Groups all instances in your compartment. The VM is a member by compartment match (`instance.compartment.id`). Freeform tags are not used. |
| **oci_identity_policy.rclone_policy** | Single policy with: (1) Define usage-report tenancy (FOCUS Report tenancy billing namespace), (2) Read objects + buckets in usage-report, (3) Use secret-bundles in compartment (Vault), (4) Use ons-topics (Notifications for alerts). |

**Why no API keys?** Instance Principal: the VM uses its identity (metadata) to get temporary credentials. The dynamic group policies authorize that identity.

---

### `infra/monitoring.tf`
**Purpose:** Failure alerts via OCI Notifications.

| Resource | What it does |
|----------|---------------|
| **oci_ons_notification_topic.rclone_alerts** | Topic for sync/bootstrap failure messages. Created when `enable_monitoring = true`. |
| **oci_ons_subscription.rclone_alerts_email** | Email subscription. Sends to `alert_email_address` when a message is published. Requires confirmation link in first email. |

**Flow:** When sync or bootstrap fails → trap in script runs → `oci ons message publish` → topic → email.

---

### `infra/cloud-init.yaml`
**Purpose:** Config and scripts installed on the VM at first boot. OCI runs cloud-init, but times out after ~2 minutes, so heavy setup runs in a delayed systemd service.

| Section | What it does |
|---------|--------------|
| **write_files** | Creates rclone config, sync.sh, bootstrap script, systemd unit |
| **runcmd** | Enables and starts the bootstrap service (runs in background) |

**Files created on VM:**

| Path | Purpose |
|------|---------|
| `/root/.config/rclone/rclone.conf` | rclone config: `oci_usage` (instance_principal_auth, bling), `aws_s3` (env_auth). `no_check_bucket = true` avoids GetBucket on bling. |
| `/usr/local/bin/sync.sh` | Fetches AWS keys from Vault, runs rclone sync. Trap on EXIT sends alert if any step fails. |
| `/usr/local/bin/bootstrap-oci-sync.sh` | Installs dnf packages, oci-cli, rclone. Adds cron job. Runs first sync. Trap on EXIT sends alert on failure. |
| `/etc/systemd/system/oci-sync-bootstrap.service` | Runs bootstrap 90 seconds after boot (avoids OCI cloud-init timeout). |

**Template variables** (from main.tf templatefile): `tenancy_ocid`, `region`, `aws_access_key_secret_id`, `aws_secret_key_secret_id`, `aws_s3_bucket_name`, `aws_s3_prefix`, `aws_region`, `alert_topic_id`, `opc_password`.

---

### `infra/outputs.tf`
**Purpose:** Values printed after `tofu apply` for operators.

| Output | Use |
|--------|-----|
| `instance_id`, `instance_private_ip` | VM identifiers |
| `bastion_public_ip`, `bastion_ssh_command` | SSH via bastion VM (`create_bastion = true`) |
| `bastion_service_id`, `bastion_service_session_command` | SSH via OCI Bastion Service (`use_bastion_service = true`) |
| `aws_access_key_secret_id`, `aws_secret_key_secret_id` | Vault secret OCIDs (debugging) |
| `alert_notification_topic_id` | Test alerts from VM |

---

### `infra/terraform.tfvars.example`
**Purpose:** Template for `terraform.tfvars`. Copy to `terraform.tfvars` and fill in real values. `terraform.tfvars` is gitignored (contains secrets). Sections cover compartments, networking, SSH access options, vault, secrets, AWS destination, monitoring, and compute.


---

## 3. Key Concepts

### Instance Principal
The VM has no OCI config or API keys. It uses the OCI instance metadata service to get temporary credentials. The dynamic group says "instances in compartment X are allowed to ...". Policies grant that group access.

### FOCUS usage-report policy
Bling (cost reports) lives in a restricted Oracle tenancy. The policy:
- `Define tenancy usage-report as ocid1.tenancy.oc1..aaaa...` — names that tenancy
- `Endorse dynamic-group rclone-dg to read objects/buckets in tenancy usage-report` — grants cross-tenancy access

### Vault secret flow
1. Terraform stores `aws_access_key` / `aws_secret_key` in Vault (base64).
2. At sync time, sync.sh runs `oci secrets secret-bundle get --auth instance_principal`.
3. Decodes base64, strips whitespace, exports as `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`.
4. rclone uses `env_auth = true` so it reads those env vars.

### Alert flow
1. sync.sh and bootstrap both have `trap alert_on_exit EXIT`.
2. On any non-zero exit, the trap runs `oci ons message publish` to the topic.
3. Topic delivers to email subscription.

---

## 4. Common Maintenance Tasks

| Task | Steps |
|------|-------|
| Change sync frequency | Edit `cloud-init.yaml` cron line (e.g. `0 */6 * * *` → `0 * * * *` for hourly). Then `tofu apply -replace=oci_core_instance.rclone_sync`. |
| Change S3 bucket/prefix | Edit `terraform.tfvars`, run `tofu apply`. No instance replace needed. |
| Rotate AWS keys | Update `aws_access_key` / `aws_secret_key` in tfvars, run `tofu apply`. Secrets are updated in Vault. |
| Add/modify alert email | Update `alert_email_address`, run `tofu apply`. Confirm new email via OCI subscription link. |
| Fix sync script logic | Edit `cloud-init.yaml` sync.sh block, run `tofu apply -replace=oci_core_instance.rclone_sync`. |
| Use existing VCN/Vault | Set `create_vcn = false`, `existing_vcn_id = "ocid..."`, etc. in tfvars. |

---

## 5. Logs & Debugging

| Location | Contents |
|----------|----------|
| `/var/log/rclone-sync.log` | rclone output (append each run) |
| `/var/log/cloud-init-bootstrap.log` | Bootstrap install and first sync |
| `/var/log/cloud-init.log` | Cloud-init stages |
| `/var/log/cron` | Cron execution (if enabled) |

---

## 6. Troubleshooting Quick Reference

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| `directory not found` (bling) | Bucket check failing | `no_check_bucket = true` in rclone config; policy needs `read buckets` |
| `404` (Vault) | Wrong policy verb | Use `use secret-bundles` not `secrets` |
| `404` (ONS publish) | No publish permission | Policy needs `use ons-topics` in compartment |
| `invalid header` (S3) | Bad secret format | Ensure tr -d trim in sync.sh; re-store secret in Vault |
| No alerts | Subscription not confirmed | Check OCI Console → Topics → Subscriptions; click confirmation link |
| VM replaced unexpectedly | user_data changed | Normal when cloud-init.yaml changes; use `-replace` intentionally |

---

## 8. Security Details

This project handles cost/usage reports (financial data). Key considerations:

### What's Protected

| Area | Status |
|------|--------|
| **VM** | No AWS keys on disk. Keys exist only in process memory during sync; fetched from Vault at runtime via Instance Principal. |
| **Instance metadata** | Only secret OCIDs (not the actual keys) are in user_data. |
| **OCI Vault** | Keys encrypted at rest with KMS. |
| **Transit** | rclone uses HTTPS for both OCI Object Storage and S3. |
| **Logs** | rclone does not log credentials. |

### Risks & Mitigations

| Risk | Mitigation |
|------|------------|
| **Terraform state** contains `aws_access_key`, `aws_secret_key`, and secret content. Anyone with state access can recover keys. | `terraform.tfstate` is gitignored and stays in `infra/` on the deploying machine. Restrict filesystem access. Never commit `*.tfstate`. |
| **terraform.tfvars** holds plaintext AWS keys on disk. | Keep tfvars gitignored (it is). Consider `TF_VAR_aws_access_key` / `TF_VAR_aws_secret_key` from env or a secrets manager in CI. Restrict filesystem access. |
| **S3 destination** receives the reports. | Enable default encryption, restrict bucket policy, enable access logging. Scope AWS IAM to minimal S3 permissions. |

### Operational

- **IAM scope**: AWS credentials should have least privilege (only required S3 actions and bucket).
- **Key rotation**: Update `aws_access_key` / `aws_secret_key` in tfvars and run `tofu apply`; Vault secrets are updated in place.
- **Audit**: Track who can access Terraform state, Vault, and the S3 bucket.

---

## 9. Project Structure Summary

```
oci-focus-report-export/
├── README.md              # Quick start and user-facing docs
├── ARCHITECTURE.md        # This file — component and maintenance guide
├── LEARNING.md            # Deep-dive concepts (OpenTofu, cloud-init, rclone, Bastion Service)
├── .gitignore             # Excludes tfvars, tfstate, credentials
└── infra/
    ├── providers.tf               # OCI provider config (supports workstation + Cloud Shell auth)
    ├── variables.tf               # Variable declarations (compartments, networking, bastion options)
    ├── main.tf                    # Core infra (VCN, gateways, Vault, bastion VM/service, compute)
    ├── iam.tf                     # Dynamic group + policies
    ├── monitoring.tf              # Notification topic + email
    ├── outputs.tf                 # Post-apply outputs (bastion VM, bastion service, vault)
    ├── cloud-init.yaml            # VM bootstrap (template)
    ├── terraform.tfvars.example   # Config template (all options documented)
    ├── terraform.tfvars           # Your values (gitignored)
    └── terraform.tfstate          # Local state (gitignored — stays in infra/ on deploying machine)
```
