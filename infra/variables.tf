# OCI-to-AWS Sync - Variables

variable "region" {
  description = "OCI region (e.g., us-ashburn-1)"
  type        = string
}

variable "tenancy_ocid" {
  description = "OCI Tenancy OCID"
  type        = string
}

# -----------------------------------------------------------------------------
# Compartment
# Default compartment for all resources. Override per resource type below.
# -----------------------------------------------------------------------------
variable "create_compartment" {
  description = "Create a new compartment for OCI-to-AWS sync resources"
  type        = bool
  default     = false
}

variable "existing_compartment_id" {
  description = "Default compartment OCID used for all resources unless overridden below"
  type        = string
  default     = ""
}

variable "compartment_name" {
  description = "Name for the compartment when create_compartment = true"
  type        = string
  default     = "oci-aws-sync"
}

variable "compartment_description" {
  description = "Description for the compartment when create_compartment = true"
  type        = string
  default     = "Compartment for OCI-to-AWS sync"
}

# Optional per-resource compartment overrides. Leave empty to use existing_compartment_id.
variable "compute_compartment_id" {
  description = "Compartment for the sync VM and bastion VM. Defaults to existing_compartment_id."
  type        = string
  default     = ""
}

variable "network_compartment_id" {
  description = "Compartment for networking resources (VCN, gateways, subnets, route tables). Defaults to existing_compartment_id."
  type        = string
  default     = ""
}

variable "vault_compartment_id" {
  description = "Compartment for Vault, KMS key, and secrets. Defaults to existing_compartment_id."
  type        = string
  default     = ""
}

# -----------------------------------------------------------------------------
# VCN
# -----------------------------------------------------------------------------
variable "create_vcn" {
  description = "Create a new VCN. Set false to use an existing VCN."
  type        = bool
  default     = false
}

variable "existing_vcn_id" {
  description = "Existing VCN OCID when create_vcn = false"
  type        = string
  default     = ""
}

variable "vcn_cidr" {
  description = "CIDR block for the new VCN when create_vcn = true"
  type        = string
  default     = "10.0.0.0/16"
}

variable "vcn_dns_label" {
  description = "DNS label for the new VCN"
  type        = string
  default     = "ociawssync"
}

# -----------------------------------------------------------------------------
# Private Subnet (sync VM always placed here — no public IP ever assigned)
# -----------------------------------------------------------------------------
variable "create_subnet" {
  description = "Create a new private subnet. Set false to use an existing private subnet."
  type        = bool
  default     = false
}

variable "existing_subnet_id" {
  description = "Existing private subnet OCID when create_subnet = false"
  type        = string
  default     = ""
}

variable "subnet_cidr" {
  description = "CIDR for the new private subnet when create_subnet = true"
  type        = string
  default     = "10.0.1.0/24"
}

variable "subnet_dns_label" {
  description = "DNS label for the new private subnet"
  type        = string
  default     = "ociawssyncsub"
}

# -----------------------------------------------------------------------------
# NAT Gateway (internet egress for sync VM → AWS S3)
# Required for the sync VM to reach AWS S3. Provide existing or create new.
# -----------------------------------------------------------------------------
variable "create_nat_gateway" {
  description = "Create a new NAT Gateway for internet egress (sync VM → AWS S3)"
  type        = bool
  default     = false
}

variable "existing_nat_gateway_id" {
  description = "Existing NAT Gateway OCID when create_nat_gateway = false"
  type        = string
  default     = ""
}

# -----------------------------------------------------------------------------
# Service Gateway (private path for sync VM → OCI Object Storage / bling)
# Required for the sync VM to read OCI cost reports. Provide existing or create new.
# -----------------------------------------------------------------------------
variable "create_service_gateway" {
  description = "Create a new Service Gateway for OCI Object Storage access (bling namespace)"
  type        = bool
  default     = false
}

variable "existing_service_gateway_id" {
  description = "Existing Service Gateway OCID when create_service_gateway = false"
  type        = string
  default     = ""
}

# -----------------------------------------------------------------------------
# Bastion VM (option 1: traditional jump host in a new public subnet)
# Creates its own IGW, public subnet, and route table within the VCN.
# Works with both new and existing VCNs.
# -----------------------------------------------------------------------------
variable "create_bastion" {
  description = "Create a bastion VM in a new public subnet for SSH jump access to the sync VM"
  type        = bool
  default     = false
}

variable "bastion_subnet_cidr" {
  description = "CIDR for the bastion public subnet (only used when create_bastion = true)"
  type        = string
  default     = "10.0.2.0/24"
}

variable "ssh_public_key_path" {
  description = "Path to SSH public key placed on the sync VM and bastion VM (required when create_bastion = true or use_bastion_service = true)"
  type        = string
  default     = "~/.ssh/id_rsa.pub"
}

# -----------------------------------------------------------------------------
# OCI Bastion Service (option 2: managed keyless SSH to the private sync VM)
# No extra VM or public subnet required. Uses Oracle Cloud Agent plugin.
# Mutually exclusive with create_bastion — choose one or neither.
# -----------------------------------------------------------------------------
variable "use_bastion_service" {
  description = "Create an OCI Bastion Service endpoint targeting the private sync VM subnet"
  type        = bool
  default     = false
}

variable "bastion_service_allowed_cidrs" {
  description = "List of client CIDRs allowed to create Bastion Service sessions (e.g. your office IP)"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

# -----------------------------------------------------------------------------
# Vault & Keys
# -----------------------------------------------------------------------------
variable "create_vault" {
  description = "Create a new OCI Vault for storing AWS credentials"
  type        = bool
  default     = false
}

variable "existing_vault_id" {
  description = "Existing Vault OCID when create_vault = false"
  type        = string
  default     = ""
}

variable "create_key" {
  description = "Create a new KMS key for secret encryption"
  type        = bool
  default     = false
}

variable "existing_key_id" {
  description = "Existing KMS Key OCID when create_key = false"
  type        = string
  default     = ""
}

variable "vault_type" {
  description = "Vault type: DEFAULT or VIRTUAL_PRIVATE"
  type        = string
  default     = "DEFAULT"
}

# -----------------------------------------------------------------------------
# Secrets (AWS Credentials)
# -----------------------------------------------------------------------------
variable "create_aws_secrets" {
  description = "Create AWS Access Key and Secret Key secrets in the Vault"
  type        = bool
  default     = false
}

variable "existing_aws_access_key_secret_id" {
  description = "Existing secret OCID for AWS Access Key when create_aws_secrets = false"
  type        = string
  default     = ""
}

variable "existing_aws_secret_key_secret_id" {
  description = "Existing secret OCID for AWS Secret Key when create_aws_secrets = false"
  type        = string
  default     = ""
}

variable "aws_access_key" {
  description = "AWS Access Key ID (used when create_aws_secrets = true)"
  type        = string
  default     = ""
  sensitive   = true
}

variable "aws_secret_key" {
  description = "AWS Secret Access Key (used when create_aws_secrets = true)"
  type        = string
  default     = ""
  sensitive   = true
}

# -----------------------------------------------------------------------------
# Compute (sync VM — always private, no public IP)
# E6.Flex = latest AMD; A1.Flex = free tier ARM (arm64)
# -----------------------------------------------------------------------------
variable "instance_shape" {
  description = "Compute shape (VM.Standard.E6.Flex, VM.Standard.E5.Flex, or VM.Standard.A1.Flex for free tier ARM)"
  type        = string
  default     = "VM.Standard.E6.Flex"
}

variable "instance_ocpus" {
  description = "OCPUs for Flex shapes"
  type        = number
  default     = 1
}

variable "instance_memory_gb" {
  description = "Memory in GB for Flex shapes. Use at least 4 GB for bootstrap (dnf + pip)."
  type        = number
  default     = 4
}

variable "instance_display_name" {
  description = "Display name for the sync compute instance"
  type        = string
  default     = "oci-aws-rclone-sync"
}

variable "opc_password" {
  description = "Optional password for opc user (Serial Console access). Leave empty to skip."
  type        = string
  default     = ""
  sensitive   = true
}

# -----------------------------------------------------------------------------
# AWS Destination
# -----------------------------------------------------------------------------
variable "aws_s3_bucket_name" {
  description = "AWS S3 bucket name for the sync destination"
  type        = string
}

variable "aws_s3_prefix" {
  description = "Optional prefix/folder inside the S3 bucket"
  type        = string
  default     = ""
}

variable "aws_region" {
  description = "AWS region for the S3 bucket"
  type        = string
}

# -----------------------------------------------------------------------------
# Observability / Monitoring
# -----------------------------------------------------------------------------
variable "enable_monitoring" {
  description = "Enable OCI Notifications and email alerts for sync/bootstrap failures"
  type        = bool
  default     = true
}

variable "alert_email_address" {
  description = "Email address for rclone sync failure alerts"
  type        = string
  default     = ""
}
