# OCI Cost Reports → AWS S3 Sync

Syncs Oracle Cloud (OCI) cost and usage reports to an AWS S3 bucket. Runs automatically every 6 hours on a VM in OCI.

## What You Need Before Starting

| Requirement | Purpose |
|-------------|---------|
| **OCI account** | Compartment, VCN, private subnet with NAT + Service Gateway |
| **AWS IAM user** | Access Key + Secret Key with S3 write permission |
| **AWS S3 bucket** | Destination bucket for OCI cost reports |

---

## Setup — OCI Cloud Shell

`$HOME` persists across Cloud Shell sessions so this is a one-time setup. Follow these steps in order.

### Step 1: Generate an API key pair in Cloud Shell

The private key is generated directly in Cloud Shell and never leaves it.

```bash
mkdir -p ~/.oci
openssl genrsa -out ~/.oci/oci_api_key.pem 2048
chmod 600 ~/.oci/oci_api_key.pem
openssl rsa -pubout -in ~/.oci/oci_api_key.pem -out ~/.oci/oci_api_key_public.pem
cat ~/.oci/oci_api_key_public.pem   # copy this entire output to your clipboard
```

### Step 2: Upload the public key to the OCI Console

1. OCI Console → top-right **Profile → My profile → API keys → Add API key**
2. Select **Paste a public key**, paste the output from above → **Add**
3. Copy the config snippet displayed after adding (it contains your fingerprint, user OCID, and tenancy OCID)

### Step 3: Create the OCI config file

Paste the snippet from the Console into the command below, filling in the real values:

```bash
cat > ~/.oci/config << 'EOF'
[DEFAULT]
user=ocid1.user.oc1..aaaa...
fingerprint=xx:xx:xx:...
tenancy=ocid1.tenancy.oc1..aaaa...
region=us-ashburn-1
key_file=~/.oci/oci_api_key.pem
EOF
chmod 600 ~/.oci/config
```

Verify it works:

```bash
oci iam region list
```

### Step 4: Generate an SSH key pair

Required to SSH into the sync VM. This key is injected into the VM at deploy time — **generate it before running `tofu apply`.**

```bash
ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa -N ""
```

### Step 5: Install OpenTofu

The `tofu` binary installs to `~/bin`, which persists across sessions:

```bash
TOFU_VER=$(curl -s https://api.github.com/repos/opentofu/opentofu/releases/latest | grep '"tag_name"' | cut -d'"' -f4)
ARCH=$(uname -m); [[ "$ARCH" == "aarch64" ]] && TOFU_ARCH=arm64 || TOFU_ARCH=amd64
curl -sLO "https://github.com/opentofu/opentofu/releases/download/${TOFU_VER}/tofu_${TOFU_VER#v}_linux_${TOFU_ARCH}.zip"
unzip "tofu_${TOFU_VER#v}_linux_${TOFU_ARCH}.zip" tofu
mkdir -p ~/bin && mv tofu ~/bin/
export PATH="$HOME/bin:$PATH"
echo 'export PATH="$HOME/bin:$PATH"' >> ~/.bashrc
```

### Step 6: Download the project files

```bash
curl -sLO https://github.com/jshahid21/oci-focus-report-export/archive/refs/heads/main.zip
unzip main.zip
cd oci-focus-report-export-main/infra
```

### Step 7: Configure and deploy

```bash
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your OCI and AWS values
tofu init
tofu apply
```

Open `terraform.tfvars` and fill in:

- `region`, `tenancy_ocid`, `existing_compartment_id` — from your OCI Console
- Networking: set existing resource OCIDs or flip `create_*` flags to `true`
- `aws_s3_bucket_name`, `aws_region` — your S3 destination bucket
- **AWS credentials (choose one):**
  - **Let OpenTofu create Vault secrets:** set `create_aws_secrets = true`, `create_vault = true` (or `existing_vault_id`), `create_key = true` (or `existing_key_id`), then fill in `aws_access_key` and `aws_secret_key`
  - **Use existing Vault secrets:** set `create_aws_secrets = false`, fill in `existing_aws_access_key_secret_id` and `existing_aws_secret_key_secret_id` with the Vault secret OCIDs
- `alert_email_address` — email alerts on bootstrap or sync failure

Type `yes` when prompted. Wait ~10 minutes for the VM to bootstrap and run its first sync.

---

## Networking Options

The sync VM is always placed in a **private subnet** with no public IP. It reaches AWS S3 via a NAT Gateway and OCI Object Storage via a Service Gateway. You can bring your own existing networking or let OpenTofu create everything.

| Scenario | What to set in `terraform.tfvars` |
|----------|----------------------------------|
| Existing VCN + private subnet + NAT GW + Service GW | `create_vcn = false`, `existing_vcn_id`, `create_subnet = false`, `existing_subnet_id`, `existing_nat_gateway_id`, `existing_service_gateway_id` |
| Create all new networking | `create_vcn = true`, `create_subnet = true`, `create_nat_gateway = true`, `create_service_gateway = true` |
| Mix (existing VCN, new gateways) | Set `create_vcn = false` with `existing_vcn_id`, set `create_nat_gateway = true`, etc. |

Different compartments can be specified for compute, networking, and vault resources using the optional `compute_compartment_id`, `network_compartment_id`, and `vault_compartment_id` variables. All default to `existing_compartment_id` when left empty.

---

## SSH Access to the Sync VM

The sync VM runs unattended in a private subnet — SSH is only needed for debugging. All SSH options are **disabled by default** and only enabled when explicitly set.

### Option A — Cloud Shell Private Network Access (simplest)

Connect Cloud Shell to the same private subnet using the network icon in the Cloud Shell toolbar → **Ephemeral Private Network Setup**. Then SSH directly — no Bastion Service or bastion VM needed:

```bash
ssh opc@<instance_private_ip> -i ~/.ssh/id_rsa
```

> **Required: private subnet SSH ingress rule.** Add this once in OCI Console → Networking → your VCN → private subnet → Security Lists → Add Ingress Rule: Source CIDR = subnet CIDR (e.g. `10.0.1.0/24`), Protocol TCP, Port 22.

### Option B — OCI Bastion Service (no extra VM)

Set in `terraform.tfvars`:

```hcl
use_bastion_service           = true
bastion_service_allowed_cidrs = ["203.0.113.10/32"]   # your IP(s)
```

After `tofu apply`, create a session and connect:

```bash
# Get the ready-made session creation command
tofu output bastion_service_session_command

# Run the printed command, capture the session OCID, then wait ~60s:
oci bastion session get --session-id <session_ocid> \
  --query 'data."ssh-metadata".command' --raw-output
```

> **Note:** The OCI Cloud Agent Bastion plugin must be **Running** on the VM before sessions connect. It starts automatically within a few minutes of first boot.

### Option C — Temporary Bastion VM (for debugging only)

Requires an existing public subnet. Add to `terraform.tfvars`:

```hcl
create_bastion_vm          = true
existing_bastion_subnet_id = "ocid1.subnet.oc1.iad.aaaa..."
```

After `tofu apply`:

```bash
tofu output bastion_vm_ssh_command
# Prints: ssh -J opc@<bastion_public_ip> opc@<rclone_private_ip> -i ~/.ssh/id_rsa
```

**Remove when done** — set `create_bastion_vm = false` and run `tofu apply`. The rclone VM is untouched.

> **SSH access is not required** for normal operation — the sync runs unattended and email alerts notify on failure.

---

## How It Works

1. **OCI**: A VM runs in your compartment. No OCI API keys on the VM — it uses Instance Principal.
2. **Vault**: Your AWS keys are stored in OCI Vault. The VM retrieves them at sync time.
3. **Cron**: Every 6 hours, the VM syncs OCI cost reports (bling namespace) to your S3 bucket.

## Security (Financial Data)

- **VM**: No AWS keys on disk; keys are fetched from OCI Vault at sync time (memory only). OCI uses Instance Principal — no API keys on the VM.
- **Transit**: rclone uses HTTPS for OCI Object Storage and S3.
- **OCI Vault**: AWS keys are encrypted at rest with KMS.

**Important:** `terraform.tfstate` and `terraform.tfvars` can contain plaintext AWS credentials. Both are gitignored. Never commit these files.

---

## Common Tasks

| Task | Command / Location |
|------|--------------------|
| Check sync log | `sudo tail /var/log/rclone-sync.log` (on the VM) |
| Check bootstrap log | `sudo cat /var/log/cloud-init-bootstrap.log` (on the VM) |
| See cron schedule | `sudo grep rclone /etc/crontab` (on the VM) |
| Run sync manually | `sudo /usr/local/bin/sync.sh` (on the VM) |
| SSH via Bastion Service | `tofu output bastion_service_session_command` |
| SSH via temporary bastion VM | `tofu output bastion_vm_ssh_command` |

---

## Alerts

When `enable_monitoring = true` and `alert_email_address` is set, you get email alerts for:

- **Bootstrap failure** — install or first sync failed at VM boot. Check `/var/log/cloud-init-bootstrap.log`.
- **Sync failure** — credential fetch or rclone failed. Check `/var/log/rclone-sync.log`.

**First-time setup:** OCI sends a confirmation email — click the link to activate alerts.

---

## AWS IAM Policy

Your IAM user needs S3 access. Example policy (replace `YOUR_BUCKET`):

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["s3:PutObject", "s3:GetObject", "s3:DeleteObject", "s3:ListBucket"],
    "Resource": [
      "arn:aws:s3:::YOUR_BUCKET",
      "arn:aws:s3:::YOUR_BUCKET/*"
    ]
  }]
}
```

---

## Troubleshooting

| Problem | Fix |
|---------|-----|
| SSH hangs at `Connecting to <ip> port 22` | Private subnet security list is missing an SSH ingress rule. Add TCP port 22 from the subnet's own CIDR in OCI Console → Networking → your VCN → private subnet → Security Lists |
| `Permission denied (publickey)` on SSH | SSH key was not injected at deploy time. Generate `~/.ssh/id_rsa`, then run `tofu taint oci_core_instance.rclone_sync && tofu apply` |
| `directory not found` (bling) | Ensure `no_check_bucket = true` in rclone config; policy includes `read buckets` |
| `404` (Vault) | Policy needs `use secret-bundles` (not `secrets`) on the compartment |
| `invalid header` (S3) | Secret may have whitespace; trim on VM or re-store in Vault |
| No reports yet | Cost reports can take 24–48 hours; check correct OCI region |

---

## Architecture Recap

- **OCI**: Instance Principal (no API keys on VM). Dynamic group `rclone-dg` matches instances in your compartment. IAM policy grants access to bling (usage-report) namespace.
- **AWS**: Keys stored in OCI Vault, fetched at sync time. No credentials in instance metadata.
- **Cron**: Every 6 hours (`0 */6 * * *`). Logs append to `/var/log/rclone-sync.log`.

**Maintainers:** See [ARCHITECTURE.md](ARCHITECTURE.md) for a file-by-file breakdown of components, maintenance tasks, and security details.
