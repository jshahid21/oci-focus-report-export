# Learning Guide: OpenTofu, Project Structure, cloud-init & rclone

A guide for someone new to OpenTofu (Terraform) to understand this project’s structure, code, and scripts.

---

## Part 1: OpenTofu & Terraform Basics

### What is OpenTofu?

**OpenTofu** is an open-source **Infrastructure as Code (IaC)** tool. You describe infrastructure (VMs, networks, databases) in configuration files, and OpenTofu creates and updates that infrastructure in cloud providers.

- **Terraform** and **OpenTofu** use the same language (HCL) and are largely compatible.
- You write `.tf` files describing *desired state* → OpenTofu figures out what to create, change, or destroy.

### Core Concepts

| Concept | Meaning |
|--------|---------|
| **Provider** | Plugin for a cloud (e.g. `oci` for Oracle Cloud). Handles API calls to create real resources. |
| **Resource** | A single cloud object: `oci_core_instance`, `oci_core_vcn`, etc. |
| **Variable** | Input you provide (via `terraform.tfvars` or CLI). Makes config reusable. |
| **Output** | Values printed after apply (e.g. IP addresses, IDs). |
| **Local** | Internal computed value. Not exposed; used to avoid repeating logic. |
| **Data source** | Read-only lookup of existing resources (e.g. AMI IDs, availability domains). |

### The OpenTofu Workflow

1. `tofu init` — download providers, prepare backend.
2. `tofu plan` — show what would change (dry run).
3. `tofu apply` — apply changes (create/update/destroy resources).
4. `tofu destroy` — tear everything down (optional).

---

## Part 2: Project Structure

```
oci-rclone-sync/
├── README.md              # Quick start, manual install, troubleshooting
├── ARCHITECTURE.md        # Maintenance guide for developers
├── LEARNING.md            # This file
├── .gitignore
└── infra/
    ├── providers.tf       # OpenTofu + OCI provider config
    ├── variables.tf       # Variable declarations (inputs)
    ├── main.tf            # Core infra: VCN, subnet, Vault, compute, etc.
    ├── iam.tf             # Dynamic group + IAM policies
    ├── monitoring.tf      # Notification topic + email subscription
    ├── outputs.tf         # Values printed after apply
    ├── cloud-init.yaml    # VM bootstrap script (template)
    ├── terraform.tfvars.example  # Example config (copy to terraform.tfvars)
    └── terraform.tfvars   # Your values (gitignored; contains secrets)
```

### Why This Structure?

- **Separation of concerns**: Networking in `main.tf`, IAM in `iam.tf`, monitoring in `monitoring.tf`.
- **Variables**: All inputs live in `variables.tf`; actual values in `terraform.tfvars`.
- **cloud-init.yaml**: Passed to the VM as `user_data`; contains the scripts that run on first boot.

---

## Part 3: OpenTofu Code Walkthrough

### 3.1 `providers.tf` — Line by Line

```hcl
terraform {
  required_version = ">= 1.5"
  required_providers {
    oci = { source = "oracle/oci", version = ">= 5.0, < 9.0" }
  }
}
```

| Line | Explanation |
|------|-------------|
| `terraform { ... }` | Top-level Terraform/OpenTofu block. |
| `required_version = ">= 1.5"` | Minimum OpenTofu version. |
| `required_providers` | Declares needed provider(s). |
| `oci = { source = "oracle/oci", ... }` | OCI provider from Oracle; downloads during `tofu init`. |
| `version = ">= 5.0, < 9.0"` | Acceptable provider version range. |

```hcl
provider "oci" {
  config_file_profile = "DEFAULT"
  region              = var.region
}
```

| Line | Explanation |
|------|-------------|
| `provider "oci"` | Configures the OCI provider. |
| `config_file_profile = "DEFAULT"` | Use the DEFAULT profile from `~/.oci/config` (your API keys). |
| `region = var.region` | OCI region from `var.region` (e.g. `us-ashburn-1`). |

Conceptually: OpenTofu runs on your machine and uses your OCI config to talk to Oracle Cloud. The VM itself uses Instance Principal later and never sees these credentials.

---

### 3.2 `variables.tf` — Key Concepts

Variables are declared here; values come from `terraform.tfvars` or environment.

**Example:**

```hcl
variable "region" {
  description = "OCI region (e.g., us-ashburn-1)"
  type        = string
}

variable "create_compartment" {
  description = "Create a new compartment for OCI-to-AWS sync resources"
  type        = bool
  default     = false
}
```

- `description` — Shown in `tofu plan` / help.
- `type` — `string`, `bool`, `number`, etc.
- `default` — Used when no value is provided.
- `sensitive = true` — Hides value in logs (e.g. `aws_secret_key`).

Pattern used here: `create_*` flags decide whether resources are created; `existing_*` IDs let you point at existing resources (brownfield).

---

### 3.3 `main.tf` — Conceptual Flow

**Locals block (lines 1–29):**

```hcl
locals {
  compartment_id = var.create_compartment ? oci_identity_compartment.this[0].id : var.existing_compartment_id
  vault_id       = var.create_vault ? oci_kms_vault.this[0].id : var.existing_vault_id
  ...
}
```

Conceptually: “Choose either the newly created resource or the existing one.” This is used everywhere to support both greenfield and brownfield deployments.

**Resource blocks — high level:**

| Resource | Purpose |
|----------|---------|
| `oci_identity_compartment` | OCI compartment (optional). |
| `oci_core_vcn` | Virtual Cloud Network. |
| `oci_core_nat_gateway` | Outbound internet (AWS, package downloads). |
| `oci_core_service_gateway` | Path to OCI Object Storage (bling). |
| `oci_core_subnet` | Private subnet for the sync VM. |
| `oci_kms_vault` + `oci_kms_key` | Encrypted vault for secrets. |
| `oci_vault_secret` (2x) | AWS access key and secret key stored in Vault. |
| `oci_core_instance.rclone_sync` | The sync VM; gets `user_data` from cloud-init. |

Important pattern: `count = var.create_* ? 1 : 0` — resource is created only when the corresponding variable is true.

**Compute instance and cloud-init (lines 336–387):**

```hcl
metadata = merge(
  {
    user_data = base64encode(templatefile("${path.module}/cloud-init.yaml", {
      tenancy_ocid             = var.tenancy_ocid
      aws_access_key_secret_id = local.aws_access_key_secret_id
      ...
    }))
  },
  var.create_bastion ? { ssh_authorized_keys = ... } : {}
)
```

Conceptually:

1. `templatefile(...)` — Load `cloud-init.yaml` and replace placeholders like `${tenancy_ocid}`.
2. `base64encode(...)` — OCI expects `user_data` base64-encoded.
3. `metadata.user_data` — OCI runs this on first boot.
4. `merge(...)` — Optionally add SSH keys when a bastion is created.

---

### 3.4 `iam.tf` — Line by Line

```hcl
resource "oci_identity_dynamic_group" "rclone_dg" {
  compartment_id = var.tenancy_ocid
  name           = "rclone-dg"
  matching_rule  = "instance.compartment.id = '${local.compartment_id}'"
}
```

| Line | Explanation |
|------|-------------|
| `oci_identity_dynamic_group` | OCI resource type for a dynamic group. |
| `rclone_dg` | Local name for this resource. |
| `compartment_id` | Where the policy lives (tenancy root). |
| `matching_rule` | All instances in `local.compartment_id` belong to this group. |

Conceptually: A dynamic group is a group whose members are defined by rules (e.g. “instances in this compartment”), not a static list.

```hcl
resource "oci_identity_policy" "rclone_policy" {
  statements = [
    "Define tenancy usage-report as ocid1.tenancy.oc1..aaaaaaaaned4fkpkisbwjlr56u7cj63lf3wffbilvqknstgtvzub7vhqkggq",
    "Endorse dynamic-group rclone-dg to read objects in tenancy usage-report",
    "Endorse dynamic-group rclone-dg to read buckets in tenancy usage-report",
    "Allow dynamic-group rclone-dg to use secret-bundles in compartment id ${local.compartment_id}",
    "Allow dynamic-group rclone-dg to use ons-topics in compartment id ${local.compartment_id}"
  ]
}
```

Conceptually:

- Statement 1 — Names the Oracle-managed usage-report (bling) tenancy.
- Statements 2–3 — Grant the dynamic group read access to bling objects and buckets.
- Statement 4 — Allows the dynamic group to read Vault secrets (for AWS keys).
- Statement 5 — Allows publishing to the OCI notification topic for alerts.

---

### 3.5 `monitoring.tf` — Line by Line

```hcl
resource "oci_ons_notification_topic" "rclone_alerts" {
  count = var.enable_monitoring ? 1 : 0
  ...
}
```

| Line | Explanation |
|------|-------------|
| `count = var.enable_monitoring ? 1 : 0` | Topic created only if monitoring is enabled. |
| `oci_ons_notification_topic` | OCI Notifications topic. |

```hcl
resource "oci_ons_subscription" "rclone_alerts_email" {
  count = var.enable_monitoring && var.alert_email_address != "" ? 1 : 0
  protocol = "EMAIL"
  endpoint = var.alert_email_address
}
```

Conceptually: When monitoring is on and an email is set, subscribe that email to the topic. Failed syncs can trigger `oci ons message publish`, which sends an email.

---

### 3.6 `outputs.tf` — Line by Line

Outputs are printed after `tofu apply` and used for operations (SSH, debugging).

| Output | Use |
|--------|-----|
| `instance_id` | VM OCID. |
| `instance_private_ip` | Private IP of the sync VM. |
| `bastion_public_ip` | Bastion public IP for SSH jump host. |
| `bastion_ssh_command` | Full SSH command to reach the sync VM. |
| `aws_access_key_secret_id` | Vault secret OCID (debugging). |
| `alert_notification_topic_id` | Topic OCID for testing alerts. |

---

## Part 4: cloud-init.yaml — Conceptual Overview

### What is cloud-init?

**cloud-init** runs on first boot on many Linux clouds (including OCI). It reads metadata (here: `user_data`) and configures the system (users, packages, files, commands).

### Why cloud-init here?

OCI injects `user_data` at boot. OpenTofu puts the contents of `cloud-init.yaml` into `metadata.user_data` after templating. So:

```
OpenTofu templatefile() → cloud-init.yaml with ${placeholders} replaced
       ↓
base64encode() → OCI metadata.user_data
       ↓
VM first boot → cloud-init runs → creates files, starts bootstrap
```

### OCI’s cloud-init Time Limit

OCI cloud-init has a ~2-minute limit. Heavy work (dnf, pip, rclone download) would time out, so this setup:

1. Writes files and configs quickly.
2. Starts a **systemd service** that waits 90 seconds, then runs the heavy bootstrap in the background.

---

## Part 5: cloud-init.yaml — Line by Line

### Header (Lines 1–7)

```yaml
#cloud-config
# OCI Cost Reports → AWS S3 sync. Bootstrap runs in background (OCI cloud-init timeout ~2min).

ssh_pwauth: false
disable_root: true
package_update: false
package_upgrade: false
```

| Line | Explanation |
|------|-------------|
| `#cloud-config` | Magic comment; tells cloud-init this is cloud-config format. |
| `ssh_pwauth: false` | Disable password auth over SSH. |
| `disable_root: true` | Disable direct root login. |
| `package_update` / `package_upgrade` | Skip apt/dnf updates to avoid cloud-init timeout. |

---

### write_files — rclone.conf (Lines 9–25)

```yaml
write_files:
  - path: /root/.config/rclone/rclone.conf
    owner: root:root
    permissions: "0600"
    content: |
      [oci_usage]
      type = oracleobjectstorage
      provider = instance_principal_auth
      namespace = bling
      compartment = ${tenancy_ocid}
      region = ${region}
      no_check_bucket = true

      [aws_s3]
      type = s3
      provider = AWS
      region = ${aws_region}
      env_auth = true
```

| Line | Explanation |
|------|-------------|
| `write_files` | cloud-init directive: create files. |
| `path` | Where the file is created. |
| `permissions: "0600"` | Read/write for owner only (root). |
| `content: \|` | Literal block; preserve newlines. |
| `[oci_usage]` | rclone remote name for OCI. |
| `provider = instance_principal_auth` | Use Instance Principal (no config file). |
| `namespace = bling` | OCI cost-report namespace. |
| `no_check_bucket = true` | Skip bucket existence check (bling is special). |
| `[aws_s3]` | rclone remote name for S3. |
| `env_auth = true` | Use `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` from environment. |

`${tenancy_ocid}`, `${region}`, `${aws_region}` are replaced by OpenTofu’s `templatefile()`.

---

### write_files — sync.sh (Lines 27–52)

```yaml
  - path: /usr/local/bin/sync.sh
    owner: root:root
    permissions: "0755"
    content: |
      #!/bin/bash
      set -e
      export PATH="/usr/local/bin:$PATH"
      export RCLONE_CONFIG="/root/.config/rclone/rclone.conf"
      export OCI_CLI_AUTH=instance_principal

      OCI_BIN="$(command -v oci 2>/dev/null)"
      [[ -z "$${OCI_BIN}" ]] && OCI_BIN="/usr/local/bin/oci"

      alert_on_exit() {
        ...
      }
      trap alert_on_exit EXIT

      export AWS_ACCESS_KEY_ID=$(${OCI_BIN} secrets secret-bundle get ...)
      export AWS_SECRET_ACCESS_KEY=$(...)

      /usr/local/bin/rclone sync oci_usage:${tenancy_ocid} aws_s3:${aws_s3_bucket_name}/${aws_s3_prefix} ...
```

| Line | Explanation |
|------|-------------|
| `$${OCI_BIN}` | Cloud-init/YAML escaping: `$$` becomes `$` so the shell sees `$OCI_BIN`. |
| `set -e` | Exit on first command failure. |
| `RCLONE_CONFIG` | Tells rclone where its config file is. |
| `OCI_CLI_AUTH=instance_principal` | Use Instance Principal for OCI CLI. |
| `trap alert_on_exit EXIT` | On any exit, run `alert_on_exit`; on failure it publishes to OCI Notifications. |
| `AWS_ACCESS_KEY_ID=...` | Fetch secret from Vault, base64-decode, trim, export. |
| `rclone sync oci_usage:... aws_s3:...` | Sync OCI bling to S3. |

Full line-by-line coverage of `sync.sh` is in Part 7.

---

### write_files — bootstrap-oci-sync.sh (Lines 54–88)

```yaml
  - path: /usr/local/bin/bootstrap-oci-sync.sh
    content: |
      #!/bin/bash
      set -e
      exec > >(tee -a /var/log/cloud-init-bootstrap.log) 2>&1
      echo "=== Bootstrap $(date) ==="

      dnf install -y unzip jq python3-pip
      pip3 install --break-system-packages oci-cli ...

      ARCH=$(uname -m)
      [[ "$${ARCH}" == "aarch64" ]] && RCLONE_ARCH=arm64 || RCLONE_ARCH=amd64
      curl -sLO "https://downloads.rclone.org/rclone-current-linux-$${RCLONE_ARCH}.zip"
      unzip -o rclone-current-linux-$${RCLONE_ARCH}.zip
      cp rclone-*-linux-$${RCLONE_ARCH}/rclone /usr/local/bin/

      echo "0 */6 * * * root /usr/local/bin/sync.sh >> /var/log/rclone-sync.log 2>&1" >> /etc/crontab
      /usr/local/bin/sync.sh
```

| Line | Explanation |
|------|-------------|
| `exec > >(tee -a ...) 2>&1` | Redirect stdout and stderr to log file and terminal. |
| `dnf install ...` | Install packages needed for oci-cli and rclone. |
| `pip3 install oci-cli` | Install OCI CLI. |
| `ARCH=$(uname -m)` | Detect arm64 vs amd64. |
| `curl ... rclone ... .zip` | Download rclone. |
| `echo "0 */6 * * * ..." >> /etc/crontab` | Add cron: run sync every 6 hours. |
| `/usr/local/bin/sync.sh` | Run first sync right away. |

---

### write_files — systemd service (Lines 89–105)

```yaml
  - path: /etc/systemd/system/oci-sync-bootstrap.service
    content: |
      [Unit]
      Description=OCI Sync Bootstrap
      After=network-online.target

      [Service]
      Type=oneshot
      ExecStartPre=/bin/sleep 90
      ExecStart=/usr/local/bin/bootstrap-oci-sync.sh
      RemainAfterExit=yes

      [Install]
      WantedBy=multi-user.target
```

| Section | Explanation |
|---------|-------------|
| `[Unit]` | Unit metadata. |
| `After=network-online.target` | Wait for network before starting. |
| `Type=oneshot` | Run a single command; exit when done. |
| `ExecStartPre=/bin/sleep 90` | Wait 90 seconds so cloud-init can finish. |
| `ExecStart=...` | Run the bootstrap script. |
| `RemainAfterExit=yes` | Treat service as “active” after script exits. |
| `WantedBy=multi-user.target` | Start when multi-user mode is reached. |

---

### runcmd (Lines 106–109)

```yaml
runcmd:
  - systemctl enable oci-sync-bootstrap.service
  - ( systemctl start oci-sync-bootstrap.service & )
```

| Line | Explanation |
|------|-------------|
| `runcmd` | cloud-init directive: run shell commands. |
| `systemctl enable` | Enable the service at boot. |
| `( systemctl start ... & )` | Start it in background; don’t block cloud-init. |

---

## Part 6: rclone sync.sh — Conceptual Overview

### Purpose

`sync.sh` is the script that actually syncs OCI cost reports to S3. It:

1. Fetches AWS credentials from OCI Vault (using Instance Principal).
2. Exports them as environment variables.
3. Runs `rclone sync` from OCI bling to AWS S3.

### Why fetch credentials at runtime?

- No AWS keys stored on disk.
- Keys exist only in memory during the sync.
- Reduces risk if the VM is compromised.

### Flow

```
sync.sh starts
    ↓
trap: on EXIT, if failure → send OCI notification
    ↓
oci secrets secret-bundle get (AWS access key) → base64 decode → export AWS_ACCESS_KEY_ID
oci secrets secret-bundle get (AWS secret key) → base64 decode → export AWS_SECRET_ACCESS_KEY
    ↓
rclone sync oci_usage:tenancy_ocid → aws_s3:bucket/prefix
```

---

## Part 7: sync.sh — Line by Line

```bash
#!/bin/bash
set -e
export PATH="/usr/local/bin:$PATH"
export RCLONE_CONFIG="/root/.config/rclone/rclone.conf"
export OCI_CLI_AUTH=instance_principal
```

| Line | Explanation |
|------|-------------|
| `#!/bin/bash` | Use Bash to run the script. |
| `set -e` | Exit immediately if any command fails. |
| `PATH=...` | Ensure `/usr/local/bin` is in PATH (rclone, oci). |
| `RCLONE_CONFIG` | rclone config location. |
| `OCI_CLI_AUTH=instance_principal` | OCI CLI auth via Instance Principal (metadata). |

```bash
OCI_BIN="$(command -v oci 2>/dev/null)"
[[ -z "$OCI_BIN" ]] && OCI_BIN="/usr/local/bin/oci"
```

| Line | Explanation |
|------|-------------|
| `command -v oci` | Path to `oci` binary, or empty if not found. |
| Fallback | If not found, assume `/usr/local/bin/oci`. |

```bash
alert_on_exit() {
  local code=$?
  if [[ "$code" =~ ^[0-9]+$ ]] && [[ $code -ne 0 ]] && [[ -n "${alert_topic_id}" ]]; then
    $OCI_BIN ons message publish --topic-id "${alert_topic_id}" --auth instance_principal \
      --body "Rclone sync FAILED (exit $code). Check /var/log/rclone-sync.log on $(hostname)" 2>/dev/null || true
  fi
}
trap alert_on_exit EXIT
```

| Line | Explanation |
|------|-------------|
| `local code=$?` | Capture previous command’s exit code. |
| `$code -ne 0` | Non-zero means failure. |
| `[[ -n "${alert_topic_id}" ]]` | Only send if topic is configured. |
| `oci ons message publish` | Publish to the OCI notification topic. |
| `trap alert_on_exit EXIT` | Run `alert_on_exit` whenever the script exits (success or failure). |

```bash
export AWS_ACCESS_KEY_ID=$($OCI_BIN secrets secret-bundle get --secret-id ${aws_access_key_secret_id} \
  --auth instance_principal --query 'data."secret-bundle-content".content' --raw-output \
  | base64 --decode | tr -d '\n\r\t ')
export AWS_SECRET_ACCESS_KEY=$($OCI_BIN secrets secret-bundle get --secret-id ${aws_secret_key_secret_id} \
  --auth instance_principal --query 'data."secret-bundle-content".content' --raw-output \
  | base64 --decode | tr -d '\n\r\t ')
```

| Part | Explanation |
|------|-------------|
| `oci secrets secret-bundle get` | Fetch the secret from OCI Vault. |
| `--auth instance_principal` | Use VM identity (no config file). |
| `--query 'data."secret-bundle-content".content'` | JMESPath to extract the content. |
| `--raw-output` | Plain text, no JSON wrapper. |
| `base64 --decode` | Decode the stored base64. |
| `tr -d '\n\r\t '` | Remove whitespace that can break S3 auth. |
| `export` | Set env vars for rclone. |

```bash
/usr/local/bin/rclone sync oci_usage:${tenancy_ocid} aws_s3:${aws_s3_bucket_name}/${aws_s3_prefix} \
  --log-file=/var/log/rclone-sync.log --checksum --s3-chunk-size 64M --s3-upload-concurrency 8 -v
```

| Part | Explanation |
|------|-------------|
| `rclone sync` | One-way sync: make destination match source. |
| `oci_usage:${tenancy_ocid}` | Source: OCI bling namespace, tenancy as “bucket” path. |
| `aws_s3:bucket/prefix` | Destination: S3 bucket and prefix. |
| `--log-file` | Append logs to `/var/log/rclone-sync.log`. |
| `--checksum` | Use checksums instead of size/modtime for sync decisions. |
| `--s3-chunk-size 64M` | S3 multipart chunk size. |
| `--s3-upload-concurrency 8` | Parallel upload streams. |
| `-v` | Verbose output. |

---

## Part 8: End-to-End Flow Summary

```
1. You run: tofu apply
2. OpenTofu creates: VCN, subnet, NAT, service gateway, Vault, secrets, VM
3. VM boots with user_data (cloud-init)
4. cloud-init: writes rclone.conf, sync.sh, bootstrap script, systemd unit
5. runcmd: enables and starts oci-sync-bootstrap.service (background)
6. After 90s: bootstrap runs dnf, pip, rclone install, adds cron, runs first sync
7. Every 6 hours: cron runs sync.sh
8. sync.sh: fetches AWS keys from Vault → rclone sync bling → S3
```

---

## Part 9: Escaping in cloud-init Templates

When `cloud-init.yaml` is used as an OpenTofu template:

| In template | Result in file | Reason |
|-------------|----------------|--------|
| `${tenancy_ocid}` | Replaced with variable value | OpenTofu interpolation |
| `$${OCI_BIN}` | `${OCI_BIN}` | `$$` becomes literal `$`; shell expands |
| `$${code}` | `${code}` | Same |
| `$(hostname)` | Evaluated by shell when script runs | Not a Terraform variable |

Terraform interpolates `${...}` first. We use `$$` so the shell, not Terraform, sees the variable.

---

## Further Reading

- [OpenTofu Docs](https://opentofu.org/docs)
- [OCI Provider](https://registry.terraform.io/providers/oracle/oci/latest/docs)
- [cloud-init Docs](https://cloudinit.readthedocs.io/)
- [rclone Oracle Object Storage](https://rclone.org/s3/)
