output "instance_id" {
  description = "Sync VM OCID"
  value       = oci_core_instance.rclone_sync.id
}

output "instance_private_ip" {
  description = "Sync VM private IP (for SSH via bastion)"
  value       = oci_core_instance.rclone_sync.private_ip
}

output "bastion_public_ip" {
  description = "Public IP of bastion host (for SSH proxy)"
  value       = var.create_bastion && var.create_vcn ? data.oci_core_vnic.bastion[0].public_ip_address : null
}

output "bastion_ssh_command" {
  description = "SSH to sync VM"
  value       = var.create_bastion && var.create_vcn ? "ssh -J opc@${data.oci_core_vnic.bastion[0].public_ip_address} opc@${oci_core_instance.rclone_sync.private_ip}" : null
}

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
