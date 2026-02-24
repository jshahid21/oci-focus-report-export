# OCI Cost Reports → AWS S3 Sync

Syncs Oracle Cloud (OCI) cost and usage reports to an AWS S3 bucket. Runs automatically every 6 hours on a VM in OCI.

## What You Need Before Starting

| Requirement | Purpose |
|-------------|---------|
| **OpenTofu** | `brew install opentofu` (Mac) or [opentofu.org](https://opentofu.org/docs/intro/install/) |
| **OCI account** | API key in `~/.oci/config` (for `tofu apply` only; create via OCI Console → Profile → API Keys) |
| **AWS IAM user** | Access Key + Secret Key with S3 write permission |
| **S3 bucket** | Created in AWS; the sync will create a folder inside it |

## Quick Start (3 Steps)

### 1. Copy and edit the config file

```bash
cd infra
cp terraform.tfvars.example terraform.tfvars
```

Open `terraform.tfvars` and fill in:

- `region`, `tenancy_ocid`, `existing_compartment_id` — from your OCI console
- `aws_s3_bucket_name`, `aws_region` — your S3 bucket and its region
- `aws_access_key`, `aws_secret_key` — AWS IAM user credentials (they go into OCI Vault, not on the VM)
- `alert_email_address` — get email when bootstrap, sync, or cron run fails

### 2. Run the setup

```bash
tofu init
tofu apply
```

Type `yes` when prompted. Wait a few minutes for the VM to start.

### 3. Verify

After apply, logs appear at `bastion_ssh_command`. SSH in and run:

```bash
sudo tail /var/log/rclone-sync.log
```

## How It Works

1. **OCI**: A VM runs in your compartment. No OCI API keys on the VM—it uses Instance Principal.
2. **Vault**: Your AWS keys are stored in OCI Vault. The VM retrieves them at sync time.
3. **Cron**: Every 6 hours, the VM syncs OCI cost reports (bling namespace) to your S3 bucket.

## Security (Financial Data)

- **VM**: No AWS keys on disk; keys are fetched from OCI Vault at sync time (memory only). OCI uses Instance Principal—no API keys on the VM.
- **Transit**: rclone uses HTTPS for OCI Object Storage and S3.
- **OCI Vault**: AWS keys are encrypted at rest with KMS.

**Important:** Terraform state and `terraform.tfvars` can contain plaintext AWS credentials. Use a remote encrypted backend for state and restrict access. See [ARCHITECTURE.md](ARCHITECTURE.md#8-security-details) for details.

## Common Tasks

| Task | Command / Location |
|------|--------------------|
| Check sync log | `sudo tail /var/log/rclone-sync.log` (on the VM) |
| SSH to VM | Use the `bastion_ssh_command` output after apply |
| See cron schedule | `sudo grep rclone /etc/crontab` |
| Run sync manually | `sudo /usr/local/bin/sync.sh` |

## Alerts

When `enable_monitoring = true` and `alert_email_address` is set, you get email alerts for:

- **Bootstrap failure** — dnf, rclone install, or first sync failed at VM boot. Check `/var/log/cloud-init-bootstrap.log`.
- **Sync failure** — credential fetch, rclone, or cron run failed. Check `/var/log/rclone-sync.log`.

**First-time setup:** OCI sends a confirmation email for the subscription. Click the link to activate alerts.

**Test alert** (on VM): `oci ons message publish --topic-id <topic_ocid> --body "Test" --auth instance_principal`

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

## Troubleshooting

| Problem | Fix |
|---------|-----|
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

---

## Manual Install (Alternative)

Use this when you prefer not to use OpenTofu, or want to understand how the solution works under the hood.

**Important:** The VM must be an **OCI compute instance**—Instance Principal only works on OCI. For VMs on other clouds or on-prem, you would need OCI API keys and different IAM policies.

### Manual Prerequisites

| Requirement | Purpose |
|-------------|---------|
| OCI compartment | Where your VM and Vault live |
| VCN, subnet, NAT gateway | Internet egress for AWS and downloads |
| Service Gateway | Direct path to OCI Object Storage (bling) |
| OCI Vault + KMS key | Store AWS credentials (encrypted at rest) |
| AWS IAM user + S3 bucket | Same as OpenTofu path |

### Step 1: Create OCI Infrastructure

Create (or use existing):

- **VCN** and **private subnet**
- **NAT Gateway** — routes `0.0.0.0/0` for AWS and package downloads
- **Service Gateway** — routes Object Storage CIDR for bling namespace
- **Route table** — default via NAT; Object Storage CIDR via Service Gateway

### Step 2: OCI Vault

1. Create a Vault and KMS key in your compartment (Console or `oci kms vault create`).
2. Store AWS credentials as base64-encoded secrets:
   ```bash
   # Encode and store (example; use Console or oci vault secret create)
   echo -n "AKIA..." | base64 -w0   # aws_access_key
   echo -n "your-secret" | base64 -w0   # aws_secret_key
   ```
3. Note the **secret OCIDs** for both secrets (you'll use them in the sync script).

### Step 3: IAM Policies (Tenancy Level)

Create a **dynamic group** matching instances in your compartment:

```
instance.compartment.id = 'ocid1.compartment.oc1..aaaa...'
```

Create a **policy** with these statements (replace `rclone-dg` and compartment OCID):

```
Define tenancy usage-report as ocid1.tenancy.oc1..aaaaaaaaned4fkpkisbwjlr56u7cj63lf3wffbilvqknstgtvzub7vhqkggq
Endorse dynamic-group rclone-dg to read objects in tenancy usage-report
Endorse dynamic-group rclone-dg to read buckets in tenancy usage-report
Allow dynamic-group rclone-dg to use secret-bundles in compartment id <your_compartment_ocid>
```

Optional (for email alerts):

```
Allow dynamic-group rclone-dg to use ons-topics in compartment id <your_compartment_ocid>
```

### Step 4: Provision the VM

- Launch an Oracle Linux instance in the private subnet.
- Ensure it has internet via NAT and Object Storage via Service Gateway.

### Step 5: Install Software (on VM)

```bash
sudo dnf install -y unzip jq python3-pip
sudo pip3 install --break-system-packages oci-cli 2>/dev/null || sudo pip3 install oci-cli

# rclone
ARCH=$(uname -m)
[[ "$ARCH" == "aarch64" ]] && RCLONE_ARCH=arm64 || RCLONE_ARCH=amd64
curl -sLO "https://downloads.rclone.org/rclone-current-linux-${RCLONE_ARCH}.zip"
unzip -o rclone-current-linux-${RCLONE_ARCH}.zip
sudo cp rclone-*-linux-${RCLONE_ARCH}/rclone /usr/local/bin/
sudo chmod 755 /usr/local/bin/rclone
```

### Step 6: Rclone Config

Create `/root/.config/rclone/rclone.conf` (mode `0600`):

```ini
[oci_usage]
type = oracleobjectstorage
provider = instance_principal_auth
namespace = bling
compartment = YOUR_TENANCY_OCID
region = us-ashburn-1
no_check_bucket = true

[aws_s3]
type = s3
provider = AWS
region = us-east-2
env_auth = true
```

Replace `YOUR_TENANCY_OCID`, `region`, and `aws_s3` region with your values.

### Step 7: Sync Script

Create `/usr/local/bin/sync.sh` (mode `0755`):

```bash
#!/bin/bash
set -e
export PATH="/usr/local/bin:$PATH"
export RCLONE_CONFIG="/root/.config/rclone/rclone.conf"
export OCI_CLI_AUTH=instance_principal

# Replace with your OCI Vault secret OCIDs
AWS_ACCESS_KEY_SECRET_ID="ocid1.vaultsecret.oc1..aaaa..."
AWS_SECRET_KEY_SECRET_ID="ocid1.vaultsecret.oc1..aaaa..."

S3_BUCKET="my-oci-cost-reports"
S3_PREFIX="oci-sync"
TENANCY_OCID="ocid1.tenancy.oc1..aaaa..."

OCI_BIN="$(command -v oci 2>/dev/null)"
[[ -z "$OCI_BIN" ]] && OCI_BIN="/usr/local/bin/oci"

# Optional: alert on failure (set ALERT_TOPIC_ID if using OCI Notifications)
# alert_on_exit() {
#   local code=$?
#   if [[ $code -ne 0 ]] && [[ -n "$ALERT_TOPIC_ID" ]]; then
#     $OCI_BIN ons message publish --topic-id "$ALERT_TOPIC_ID" --auth instance_principal \
#       --body "Rclone sync FAILED (exit $code). Check /var/log/rclone-sync.log on $(hostname)" 2>/dev/null || true
#   fi
# }
# trap alert_on_exit EXIT

export AWS_ACCESS_KEY_ID=$($OCI_BIN secrets secret-bundle get --secret-id "$AWS_ACCESS_KEY_SECRET_ID" \
  --auth instance_principal --query 'data."secret-bundle-content".content' --raw-output \
  | base64 --decode | tr -d '\n\r\t ')
export AWS_SECRET_ACCESS_KEY=$($OCI_BIN secrets secret-bundle get --secret-id "$AWS_SECRET_KEY_SECRET_ID" \
  --auth instance_principal --query 'data."secret-bundle-content".content' --raw-output \
  | base64 --decode | tr -d '\n\r\t ')

/usr/local/bin/rclone sync "oci_usage:${TENANCY_OCID}" "aws_s3:${S3_BUCKET}/${S3_PREFIX}" \
  --log-file=/var/log/rclone-sync.log --checksum --s3-chunk-size 64M --s3-upload-concurrency 8 -v
```

Fill in the secret OCIDs, `S3_BUCKET`, `S3_PREFIX`, and `TENANCY_OCID`.

### Step 8: Cron Job

```bash
echo "0 */6 * * * root /usr/local/bin/sync.sh >> /var/log/rclone-sync.log 2>&1" | sudo tee -a /etc/crontab
```

### Step 9: Verify

```bash
sudo /usr/local/bin/sync.sh
sudo tail /var/log/rclone-sync.log
```

### Sync Script Checklist

| Requirement | Purpose |
|-------------|---------|
| `oci` CLI | Fetches secrets from OCI Vault via Instance Principal |
| `set -e` | Exits on first error |
| `OCI_CLI_AUTH=instance_principal` | No OCI config file needed on VM |
| `RCLONE_CONFIG` | Points rclone to the config file |
| Base64 decode + `tr -d '\n\r\t '` | Vault stores base64; trimming avoids S3 auth errors |
| `env_auth = true` (rclone) | Uses `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` from env |
