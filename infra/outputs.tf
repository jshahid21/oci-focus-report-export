output "instance_id" {
  description = "Sync VM OCID"
  value       = oci_core_instance.rclone_sync.id
}

output "instance_private_ip" {
  description = "Sync VM private IP"
  value       = oci_core_instance.rclone_sync.private_ip
}

# -----------------------------------------------------------------------------
# OCI Bastion Service outputs (use_bastion_service = true)
# -----------------------------------------------------------------------------
output "bastion_service_id" {
  description = "OCI Bastion Service OCID (null when use_bastion_service = false)"
  value       = var.use_bastion_service ? oci_bastion_bastion.this[0].id : null
}

output "bastion_service_session_command" {
  description = "OCI CLI command to create a Managed SSH session to the sync VM via Bastion Service"
  value = var.use_bastion_service ? join(" ", [
    "oci bastion session create-managed-ssh",
    "--bastion-id", oci_bastion_bastion.this[0].id,
    "--target-resource-id", oci_core_instance.rclone_sync.id,
    "--target-os-username opc",
    "--session-ttl 10800"
  ]) : null
}

# -----------------------------------------------------------------------------
# Vault / Secrets
# -----------------------------------------------------------------------------
output "aws_access_key_secret_id" {
  description = "OCI Vault Secret OCID for AWS Access Key"
  value       = local.aws_access_key_secret_id
  sensitive   = true
}

output "aws_secret_key_secret_id" {
  description = "OCI Vault Secret OCID for AWS Secret Key"
  value       = local.aws_secret_key_secret_id
  sensitive   = true
}

output "alert_notification_topic_id" {
  description = "OCI Notification Topic OCID for rclone sync alerts"
  value       = var.enable_monitoring ? oci_ons_notification_topic.rclone_alerts[0].topic_id : null
}
