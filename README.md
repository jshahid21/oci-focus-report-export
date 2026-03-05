# OCI Cost Reports → AWS S3 Sync

Syncs Oracle Cloud (OCI) cost and usage reports to an AWS S3 bucket. Runs automatically every 6 hours on a VM in OCI.

## What You Need Before Starting

| Requirement | Purpose |
|-------------|---------|
| **OpenTofu** | `brew install opentofu` (Mac) or [opentofu.org](https://opentofu.org/docs/intro/install/) |
| **OCI account** | API key in `~/.oci/config` (for `tofu apply` only — see Prerequisites section below) |
| **OCI compartment** | Where the sync VM and supporting resources will live |
| **OCI private subnet** | Existing private subnet with NAT Gateway and Service Gateway in its route table, **or** let OpenTofu create them |
| **AWS IAM user** | Access Key + Secret Key with S3 write permission |
| **AWS S3 bucket** | Destination bucket for OCI cost reports |

## Prerequisites & OCI Authentication

Before running `tofu apply`, OpenTofu needs to authenticate with OCI from your local machine. This is a one-time setup.

> **Security note:** This API key is used exclusively by OpenTofu on your workstation to provision infrastructure (VMs, IAM policies, Vault secrets, etc.). Once deployed, the VM itself never uses an API key — it authenticates via **Instance Principals**, a keyless mechanism native to OCI. No credentials are stored in or passed to the cloud environment.

Pick your client environment and follow the relevant section:

| Environment | Steps required |
|-------------|---------------|
| macOS | Steps 1, 2, 3 below |
| Oracle Linux 8 / 9 | Steps 1, 2, 3 — with different install commands |
| Windows | Steps 1, 2, 3 — with different install commands and config path |
| OCI Cloud Shell | **Option A (recommended):** Steps 1, 2 (upload key once, `$HOME` persists), then Step 3. **Option B:** skip Steps 1 & 2, set `TF_VAR_oci_auth=SecurityToken`, then Step 3 |

---

### macOS

**Install OpenTofu:**

```bash
brew install opentofu
```

**Install OCI CLI** (needed for the verification step):

```bash
brew install oci-cli
```

---

### Oracle Linux 8 / 9

**Install OpenTofu:**

```bash
sudo dnf install -y yum-utils
sudo yum-config-manager --add-repo https://packages.opentofu.org/opentofu/tofu/rpm_any/rpm_any.repo
sudo dnf install -y tofu
```

**Install OCI CLI:**

```bash
sudo dnf install -y python3-pip
pip3 install oci-cli
```

---

### Windows

**Install OpenTofu** — run in PowerShell:

```powershell
winget install OpenTofu.OpenTofu
```

Or download the MSI installer from [opentofu.org/docs/intro/install](https://opentofu.org/docs/intro/install/).

**Install OCI CLI** — requires [Python from python.org](https://www.python.org/downloads/), then:

```powershell
pip install oci-cli
```

**Note on key generation:** Skip the `openssl` terminal commands below. On Windows, use the OCI Console to generate and download the key pair directly (Profile → My profile → API keys → Add API key → Generate API key pair). This is the simplest approach.

**Config file path on Windows:** The OCI config lives at `C:\Users\<username>\.oci\config` instead of `~/.oci/config`. The format is identical. No `chmod` is needed — Windows handles file permissions differently.

---

### OCI Cloud Shell

Cloud Shell is pre-authenticated as your OCI Console user and the OCI CLI is pre-installed. Follow these steps in order:

#### Step CS-1: Set up OCI authentication for OpenTofu

OpenTofu needs an OCI auth method to provision infrastructure — two options are available:

**Option A (Recommended) — Copy your API key config once**

`$HOME` persists across Cloud Shell sessions, so this is a one-time setup. Complete Steps 1 and 2 below on your local machine (or directly in Cloud Shell), then upload the key and config using the Cloud Shell **Upload** button:

- `~/.oci/oci_api_key.pem` — your private key
- `~/.oci/config` — your OCI config file

Then set permissions:

```bash
chmod 600 ~/.oci/config ~/.oci/oci_api_key.pem
```

No extra environment variable is needed — `APIKey` is the default auth method.

**Option B — Use the Cloud Shell session token**

If you prefer not to copy keys, skip Steps 1 and 2. Run these two commands **before** `tofu init` / `tofu plan` / `tofu apply`:

```bash
# Required — use Cloud Shell session token instead of API key config
export TF_VAR_oci_auth=SecurityToken

# Required if you want SSH access to the VM (skip if not needed)
ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa -N ""
```

The OCI provider will use the active Cloud Shell session token. The SSH key is injected into the VM and enables direct SSH access from Cloud Shell Private Network or a bastion VM.

#### Step CS-2: Install OpenTofu

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

#### Step CS-3: Download the project files

```bash
curl -sLO https://github.com/jshahid21/oci-focus-report-export/archive/refs/heads/main.zip
unzip main.zip
cd oci-focus-report-export-main
```

For **Option A**, continue to Steps 1 and 2 below, then [Step 3](#step-3-deploy-with-opentofu). For **Option B**, skip ahead directly to [Step 3](#step-3-deploy-with-opentofu).

---

### Step 1: Generate an OCI API Key Pair

> **OCI Cloud Shell — Option B only:** Skip this step if using `TF_VAR_oci_auth=SecurityToken`.

1. Log in to the [OCI Console](https://cloud.oracle.com).
2. Click your **Profile** icon (top-right) → **My profile** → **API keys** → **Add API key**.
3. Select **Generate API key pair**, download both the private and public keys, then click **Add**.
4. OCI will display a configuration preview — keep this open for the next step.

Alternatively (macOS / Linux only), generate the key pair from your terminal:

```bash
mkdir -p ~/.oci
openssl genrsa -out ~/.oci/oci_api_key.pem 2048
chmod 600 ~/.oci/oci_api_key.pem
openssl rsa -pubout -in ~/.oci/oci_api_key.pem -out ~/.oci/oci_api_key_public.pem
```

Upload the contents of `oci_api_key_public.pem` to the OCI Console under **Profile → API keys**.

### Step 2: Configure the OCI Config File

> **OCI Cloud Shell — Option B only:** Skip this step if using `TF_VAR_oci_auth=SecurityToken`.

Create (or edit) `~/.oci/config` (macOS / Linux) or `C:\Users\<username>\.oci\config` (Windows) with the values from the OCI Console configuration preview:

```ini
[DEFAULT]
user=ocid1.user.oc1..aaaa<your_user_ocid>
fingerprint=aa:bb:cc:dd:ee:ff:00:11:22:33:44:55:66:77:88:99
tenancy=ocid1.tenancy.oc1..aaaa<your_tenancy_ocid>
region=us-ashburn-1
key_file=~/.oci/oci_api_key.pem
```

| Field | Where to find it |
|-------|-----------------|
| `user` | Profile → My profile → OCID |
| `fingerprint` | Shown after uploading the public key |
| `tenancy` | Profile → Tenancy → OCID |
| `region` | Top-right region selector (e.g. `us-ashburn-1`) |
| `key_file` | Path to your downloaded/generated private key |

On macOS / Linux, set the correct permissions:

```bash
chmod 600 ~/.oci/config
```

Verify authentication is working:

```bash
oci iam region list
```

You should see a list of OCI regions. If you get an authentication error, double-check the `fingerprint` and `key_file` path.

### Step 3: Deploy with OpenTofu

With authentication confirmed, deploy the full stack:

```bash
cd infra
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your OCI and AWS values
tofu init
tofu apply
```

---

## Networking Options

The sync VM is always placed in a **private subnet** with no public IP. It reaches AWS S3 via a NAT Gateway and OCI Object Storage via a Service Gateway. You can bring your own existing networking or let OpenTofu create everything.

| Scenario | What to set in `terraform.tfvars` |
|----------|----------------------------------|
| Existing VCN + private subnet + NAT GW + Service GW | `create_vcn = false`, `existing_vcn_id`, `create_subnet = false`, `existing_subnet_id`, `existing_nat_gateway_id`, `existing_service_gateway_id` |
| Create all new networking | `create_vcn = true`, `create_subnet = true`, `create_nat_gateway = true`, `create_service_gateway = true` |
| Mix (existing VCN, new gateways) | Set `create_vcn = false` with `existing_vcn_id`, set `create_nat_gateway = true`, etc. |

Different compartments can be specified for compute, networking, and vault resources using the optional `compute_compartment_id`, `network_compartment_id`, and `vault_compartment_id` variables. All default to `existing_compartment_id` when left empty.

## SSH Access to the Sync VM

The sync VM runs unattended in a private subnet — SSH is only needed for debugging. All SSH options are **disabled by default** (`use_bastion_service = false`, `create_bastion_vm = false`) and only enabled when explicitly set.

> **Cloud Shell tip:** If you launch Cloud Shell with [Private Network Access](https://docs.oracle.com/iaas/Content/API/Concepts/cloudshellintro_topic-Cloud_Shell_Networking.htm) connected to the same private subnet as the rclone VM, you can SSH directly with `ssh opc@<private_ip>` — no Bastion Service or bastion VM needed. Set `ssh_public_key_path = "~/.ssh/id_rsa.pub"` in `terraform.tfvars` before deploying so Cloud Shell's key is injected into the VM.

### Option A — OCI Bastion Service (recommended, no extra VM)

Set in `terraform.tfvars`:

```hcl
use_bastion_service           = true
bastion_service_allowed_cidrs = ["203.0.113.10/32"]   # your IP(s)
```

No SSH key pre-provisioning needed — OCI Cloud Agent injects a temporary key for the duration of the session.

After `tofu apply`, create a session and connect:

```bash
# Step 1 — create session (get the ready-made command from tofu output)
tofu output bastion_service_session_command

# Run the printed command, capture the session OCID, then:
# Step 2 — wait for ACTIVE (~60 sec), then get the SSH command
oci bastion session get --session-id <session_ocid> \
  --query 'data."ssh-metadata".command' --raw-output
```

Run the printed SSH command replacing `<privateKey>` with `~/.ssh/id_rsa`.

> **Note:** The OCI Cloud Agent Bastion plugin must be **Running** on the VM before sessions connect. It starts automatically within a few minutes of first boot. Check status under the instance's **Oracle Cloud Agent** tab in the OCI Console.

### Option B — Temporary Bastion VM (for debugging only)

Useful when you need reliable direct SSH access without depending on Cloud Agent. Requires an existing public subnet and an SSH key pair.

```hcl
create_bastion_vm          = true
existing_bastion_subnet_id = "ocid1.subnet.oc1.iad.aaaa..."   # your public subnet
ssh_public_key_path        = "~/.ssh/id_rsa.pub"
```

> If you don't have an SSH key pair, generate one first: `ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa -N ""`

After `tofu apply`, one command connects directly to the rclone VM via ProxyJump:

```bash
tofu output bastion_vm_ssh_command
# Prints: ssh -J opc@<bastion_public_ip> opc@<rclone_private_ip> -i ~/.ssh/id_rsa
```

**Removing the bastion VM when done:**

```hcl
# In terraform.tfvars — set to false, leave other values in place
create_bastion_vm = false
```

```bash
tofu apply   # destroys only the bastion VM and its NSG, rclone VM is untouched
```

**Re-adding it later for debugging:**

```hcl
create_bastion_vm = true   # set back to true, subnet OCID is already saved
```

```bash
tofu apply   # recreates the bastion VM in ~60 seconds
```

> **SSH access is not required** for normal operation — the sync runs unattended and email alerts notify on failure.

## Quick Start (3 Steps)

### 1. Copy and edit the config file

```bash
cd infra
cp terraform.tfvars.example terraform.tfvars
```

Open `terraform.tfvars` and fill in:

- `region`, `tenancy_ocid`, `existing_compartment_id` — from your OCI console
- Networking: set existing resource OCIDs or flip `create_*` flags to `true`
- `aws_s3_bucket_name`, `aws_region` — your S3 destination bucket
- **AWS credentials (choose one):**
  - **Let OpenTofu create Vault secrets:** set `create_aws_secrets = true`, `create_vault = true` (or `existing_vault_id`), `create_key = true` (or `existing_key_id`), then fill in `aws_access_key` and `aws_secret_key`
  - **Use existing Vault secrets:** set `create_aws_secrets = false`, fill in `existing_aws_access_key_secret_id` and `existing_aws_secret_key_secret_id` with the Vault secret OCIDs
- `alert_email_address` — email alerts on bootstrap or sync failure

### 2. Run the setup

```bash
tofu init
tofu apply
```

Type `yes` when prompted. Wait a few minutes for the VM to bootstrap.

### 3. Verify

SSH in via your chosen access method and run:

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

**Important:** Terraform state (`terraform.tfstate`) and `terraform.tfvars` can contain plaintext AWS credentials. Both are gitignored. Restrict filesystem access to the `infra/` directory and never commit these files. See [ARCHITECTURE.md](ARCHITECTURE.md#8-security-details) for details.

## Common Tasks

| Task | Command / Location |
|------|--------------------|
| Check sync log | `sudo tail /var/log/rclone-sync.log` (on the VM) |
| Check bootstrap log | `sudo cat /var/log/cloud-init-bootstrap.log` (on the VM) |
| SSH via Bastion Service | `tofu output bastion_service_session_command` |
| SSH via temporary bastion VM | `tofu output bastion_vm_ssh_command` |
| See cron schedule | `sudo grep rclone /etc/crontab` (on the VM) |
| Run sync manually | `sudo /usr/local/bin/sync.sh` (on the VM) |

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

