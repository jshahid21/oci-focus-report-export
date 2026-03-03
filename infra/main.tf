# OCI Cost Reports → AWS S3. VM + rclone, cron every 6h.
locals {
  # Base compartment — fallback for all per-resource overrides
  compartment_id = var.create_compartment ? oci_identity_compartment.this[0].id : var.existing_compartment_id

  # Per-resource compartment overrides (fall back to compartment_id when empty)
  compute_compartment_id = var.compute_compartment_id != "" ? var.compute_compartment_id : local.compartment_id
  network_compartment_id = var.network_compartment_id != "" ? var.network_compartment_id : local.compartment_id
  vault_compartment_id   = var.vault_compartment_id != "" ? var.vault_compartment_id : local.compartment_id

  vcn_id         = var.create_vcn ? oci_core_vcn.this[0].id : var.existing_vcn_id
  subnet_id      = var.create_subnet ? oci_core_subnet.this[0].id : var.existing_subnet_id
  nat_gateway_id = var.create_nat_gateway ? oci_core_nat_gateway.this[0].id : var.existing_nat_gateway_id
  sgw_id         = var.create_service_gateway ? oci_core_service_gateway.this[0].id : var.existing_service_gateway_id
  vault_id       = var.create_vault ? oci_kms_vault.this[0].id : var.existing_vault_id
  key_id         = var.create_key ? oci_kms_key.this[0].id : var.existing_key_id

  vault_management_endpoint = data.oci_kms_vault.vault_lookup.management_endpoint

  aws_access_key_secret_id = var.create_aws_secrets ? oci_vault_secret.aws_access_key[0].id : var.existing_aws_access_key_secret_id
  aws_secret_key_secret_id = var.create_aws_secrets ? oci_vault_secret.aws_secret_key[0].id : var.existing_aws_secret_key_secret_id

  has_nat = var.create_nat_gateway || var.existing_nat_gateway_id != ""
  has_sgw = var.create_service_gateway || var.existing_service_gateway_id != ""

  # SSH key is needed when using a bastion VM or OCI Bastion Service
  needs_ssh_key  = var.create_bastion || var.use_bastion_service
  ssh_public_key = local.needs_ssh_key && var.ssh_public_key_path != "" ? file(pathexpand(var.ssh_public_key_path)) : ""

  oracle_linux_image_id = try(
    data.oci_core_images.oracle_linux.images[0].id,
    data.oci_core_images.oracle_linux_8.images[0].id
  )
  availability_domain    = data.oci_identity_availability_domains.ads.availability_domains[0].name
  object_storage_service = [for s in data.oci_core_services.all.services : s if strcontains(lower(s.name), "object storage")][0]
  object_storage_cidr    = local.object_storage_service.cidr_block
  object_storage_id      = local.object_storage_service.id
}

# -----------------------------------------------------------------------------
# Compartment
# -----------------------------------------------------------------------------
resource "oci_identity_compartment" "this" {
  count = var.create_compartment ? 1 : 0

  compartment_id = var.tenancy_ocid
  name           = var.compartment_name
  description    = var.compartment_description
}

# -----------------------------------------------------------------------------
# VCN
# -----------------------------------------------------------------------------
resource "oci_core_vcn" "this" {
  count = var.create_vcn ? 1 : 0

  compartment_id = local.network_compartment_id
  cidr_block     = var.vcn_cidr
  display_name   = "oci-aws-sync-vcn"
  dns_label      = var.vcn_dns_label

  lifecycle {
    prevent_destroy = true
  }
}

# -----------------------------------------------------------------------------
# NAT Gateway (internet egress for sync VM → AWS S3)
# -----------------------------------------------------------------------------
resource "oci_core_nat_gateway" "this" {
  count = var.create_nat_gateway ? 1 : 0

  compartment_id = local.network_compartment_id
  vcn_id         = local.vcn_id
  display_name   = "oci-aws-sync-nat"
}

# -----------------------------------------------------------------------------
# Service Gateway (sync VM → OCI Object Storage / bling)
# -----------------------------------------------------------------------------
resource "oci_core_service_gateway" "this" {
  count = var.create_service_gateway ? 1 : 0

  compartment_id = local.network_compartment_id
  vcn_id         = local.vcn_id
  display_name   = "oci-aws-sync-sgw"
  services {
    service_id = local.object_storage_id
  }
}

data "oci_core_services" "all" {}

# -----------------------------------------------------------------------------
# Route Table for private subnet (only when creating a new subnet)
# -----------------------------------------------------------------------------
resource "oci_core_route_table" "private" {
  count = var.create_subnet && (local.has_nat || local.has_sgw) ? 1 : 0

  compartment_id = local.network_compartment_id
  vcn_id         = local.vcn_id
  display_name   = "oci-aws-sync-private-rt"

  dynamic "route_rules" {
    for_each = local.has_nat ? [1] : []
    content {
      destination       = "0.0.0.0/0"
      destination_type  = "CIDR_BLOCK"
      network_entity_id = local.nat_gateway_id
    }
  }

  dynamic "route_rules" {
    for_each = local.has_sgw ? [1] : []
    content {
      destination       = local.object_storage_cidr
      destination_type  = "SERVICE_CIDR_BLOCK"
      network_entity_id = local.sgw_id
    }
  }
}

# -----------------------------------------------------------------------------
# Security List for private subnet
# -----------------------------------------------------------------------------
resource "oci_core_security_list" "private" {
  count = var.create_subnet ? 1 : 0

  compartment_id = local.network_compartment_id
  vcn_id         = local.vcn_id
  display_name   = "oci-aws-sync-private-sl"

  # SSH ingress from bastion VM subnet (when bastion VM is created alongside a new subnet)
  dynamic "ingress_security_rules" {
    for_each = var.create_bastion && var.create_subnet ? [1] : []
    content {
      protocol  = "6"
      source    = var.bastion_subnet_cidr
      stateless = false
      tcp_options {
        min = 22
        max = 22
      }
    }
  }

  egress_security_rules {
    destination = "0.0.0.0/0"
    protocol    = "all"
    stateless   = false
  }
}

# -----------------------------------------------------------------------------
# Private Subnet (sync VM always placed here — prohibit_public_ip_on_vnic = true)
# -----------------------------------------------------------------------------
resource "oci_core_subnet" "this" {
  count = var.create_subnet ? 1 : 0

  compartment_id            = local.network_compartment_id
  vcn_id                    = local.vcn_id
  cidr_block                = var.subnet_cidr
  display_name              = "oci-aws-sync-private-subnet"
  dns_label                 = var.subnet_dns_label
  prohibit_public_ip_on_vnic = true
  route_table_id            = (local.has_nat || local.has_sgw) ? oci_core_route_table.private[0].id : null
  security_list_ids         = [oci_core_security_list.private[0].id]

  lifecycle {
    prevent_destroy = true
  }
}

# -----------------------------------------------------------------------------
# Bastion VM (option 1)
# Creates its own Internet Gateway, public subnet, route table, and security
# list within the VCN. Works with both new and existing VCNs.
# -----------------------------------------------------------------------------
resource "oci_core_internet_gateway" "bastion" {
  count = var.create_bastion ? 1 : 0

  compartment_id = local.network_compartment_id
  vcn_id         = local.vcn_id
  display_name   = "oci-aws-sync-igw"
}

resource "oci_core_route_table" "bastion" {
  count = var.create_bastion ? 1 : 0

  compartment_id = local.network_compartment_id
  vcn_id         = local.vcn_id
  display_name   = "oci-aws-sync-bastion-rt"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.bastion[0].id
  }
}

resource "oci_core_security_list" "bastion" {
  count = var.create_bastion ? 1 : 0

  compartment_id = local.network_compartment_id
  vcn_id         = local.vcn_id
  display_name   = "oci-aws-sync-bastion-sl"

  ingress_security_rules {
    protocol  = "6"
    source    = "0.0.0.0/0"
    stateless = false
    tcp_options {
      min = 22
      max = 22
    }
  }

  egress_security_rules {
    destination = "0.0.0.0/0"
    protocol    = "all"
    stateless   = false
  }
}

resource "oci_core_subnet" "bastion" {
  count = var.create_bastion ? 1 : 0

  compartment_id             = local.network_compartment_id
  vcn_id                     = local.vcn_id
  cidr_block                 = var.bastion_subnet_cidr
  display_name               = "oci-aws-sync-bastion-subnet"
  dns_label                  = "bastion"
  prohibit_public_ip_on_vnic = false
  route_table_id             = oci_core_route_table.bastion[0].id
  security_list_ids          = [oci_core_security_list.bastion[0].id]
}

resource "oci_core_instance" "bastion" {
  count = var.create_bastion ? 1 : 0

  compartment_id       = local.compute_compartment_id
  availability_domain  = local.availability_domain
  shape                = var.instance_shape
  display_name         = "oci-aws-sync-bastion"
  preserve_boot_volume = false

  shape_config {
    ocpus         = var.instance_ocpus
    memory_in_gbs = var.instance_memory_gb
  }

  source_details {
    source_type = "image"
    source_id   = local.oracle_linux_image_id
  }

  create_vnic_details {
    subnet_id              = oci_core_subnet.bastion[0].id
    skip_source_dest_check = false
    assign_public_ip       = true
    hostname_label         = "bastion"
  }

  metadata = {
    ssh_authorized_keys = local.ssh_public_key
  }
}

data "oci_core_vnic_attachments" "bastion" {
  count          = var.create_bastion ? 1 : 0
  compartment_id = local.compute_compartment_id
  instance_id    = oci_core_instance.bastion[0].id
}

data "oci_core_vnic" "bastion" {
  count   = var.create_bastion ? 1 : 0
  vnic_id = data.oci_core_vnic_attachments.bastion[0].vnic_attachments[0].vnic_id
}

# -----------------------------------------------------------------------------
# OCI Bastion Service (option 2)
# Managed keyless SSH access to the private sync VM. No extra VM or public
# subnet required. Uses Oracle Cloud Agent Bastion plugin on the sync VM.
# -----------------------------------------------------------------------------
resource "oci_bastion_bastion" "this" {
  count = var.use_bastion_service ? 1 : 0

  bastion_type                 = "STANDARD"
  compartment_id               = local.compute_compartment_id
  target_subnet_id             = local.subnet_id
  name                         = "ociAwsSyncBastionSvc"
  client_cidr_block_allow_list = var.bastion_service_allowed_cidrs
}

# -----------------------------------------------------------------------------
# Vault
# -----------------------------------------------------------------------------
resource "oci_kms_vault" "this" {
  count = var.create_vault ? 1 : 0

  compartment_id = local.vault_compartment_id
  display_name   = "oci-aws-sync-vault"
  vault_type     = var.vault_type

  lifecycle {
    prevent_destroy = true
  }
}

# -----------------------------------------------------------------------------
# KMS Key (for secret encryption)
# -----------------------------------------------------------------------------
resource "oci_kms_key" "this" {
  count = var.create_key ? 1 : 0

  compartment_id      = local.vault_compartment_id
  display_name        = "oci-aws-sync-key"
  management_endpoint = local.vault_management_endpoint
  key_shape {
    algorithm = "AES"
    length    = 32
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "oci_kms_key_version" "this" {
  count = var.create_key ? 1 : 0

  key_id              = oci_kms_key.this[0].id
  management_endpoint = local.vault_management_endpoint
}

data "oci_kms_vault" "vault_lookup" {
  vault_id = local.vault_id
}

resource "oci_vault_secret" "aws_access_key" {
  count = var.create_aws_secrets ? 1 : 0

  compartment_id = local.vault_compartment_id
  secret_name    = "oci-aws-sync-aws-access-key"
  vault_id       = local.vault_id
  key_id         = local.key_id
  secret_content {
    content_type = "BASE64"
    content      = base64encode(var.aws_access_key)
  }
}

resource "oci_vault_secret" "aws_secret_key" {
  count = var.create_aws_secrets ? 1 : 0

  compartment_id = local.vault_compartment_id
  secret_name    = "oci-aws-sync-aws-secret-key"
  vault_id       = local.vault_id
  key_id         = local.key_id
  secret_content {
    content_type = "BASE64"
    content      = base64encode(var.aws_secret_key)
  }
}

# -----------------------------------------------------------------------------
# Compute Instance (sync VM — always private, no public IP)
# -----------------------------------------------------------------------------
resource "oci_core_instance" "rclone_sync" {
  compartment_id       = local.compute_compartment_id
  availability_domain  = local.availability_domain
  shape                = var.instance_shape
  display_name         = var.instance_display_name
  preserve_boot_volume = false

  freeform_tags = {
    "Role" = "rclone-worker"
  }

  agent_config {
    is_monitoring_disabled = !var.enable_monitoring
    plugins_config {
      desired_state = var.enable_monitoring ? "ENABLED" : "DISABLED"
      name          = "Custom Logs Monitoring"
    }
    # Enable OCI Bastion plugin when using Bastion Service (managed SSH sessions)
    dynamic "plugins_config" {
      for_each = var.use_bastion_service ? [1] : []
      content {
        desired_state = "ENABLED"
        name          = "Bastion"
      }
    }
  }

  shape_config {
    ocpus         = var.instance_ocpus
    memory_in_gbs = var.instance_memory_gb
  }

  source_details {
    source_type = "image"
    source_id   = local.oracle_linux_image_id
  }

  create_vnic_details {
    subnet_id              = local.subnet_id
    skip_source_dest_check = false
    assign_public_ip       = false
    nsg_ids                = []
    hostname_label         = "rclone-sync"
  }

  metadata = merge(
    {
      user_data = base64encode(templatefile("${path.module}/cloud-init.yaml", {
        tenancy_ocid             = var.tenancy_ocid
        region                   = var.region
        opc_password             = var.opc_password
        aws_access_key_secret_id = local.aws_access_key_secret_id
        aws_secret_key_secret_id = local.aws_secret_key_secret_id
        aws_s3_bucket_name       = var.aws_s3_bucket_name
        aws_s3_prefix            = var.aws_s3_prefix
        aws_region               = var.aws_region
        alert_topic_id           = var.enable_monitoring && var.alert_email_address != "" ? oci_ons_notification_topic.rclone_alerts[0].topic_id : ""
      }))
    },
    local.needs_ssh_key && local.ssh_public_key != "" ? { ssh_authorized_keys = local.ssh_public_key } : {}
  )
}

data "oci_identity_availability_domains" "ads" {
  compartment_id = local.compute_compartment_id
}

data "oci_core_images" "oracle_linux" {
  compartment_id           = local.compute_compartment_id
  operating_system         = "Oracle Linux"
  operating_system_version = "9"
  shape                    = var.instance_shape
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

data "oci_core_images" "oracle_linux_8" {
  compartment_id           = local.compute_compartment_id
  operating_system         = "Oracle Linux"
  operating_system_version = "8"
  shape                    = var.instance_shape
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}
