resource "oci_ons_notification_topic" "rclone_alerts" {
  count = var.enable_monitoring ? 1 : 0

  compartment_id = local.compartment_id
  name           = "oci-aws-sync-rclone-alerts"
  description    = "Alerts when rclone sync to AWS S3 fails"
}

resource "oci_ons_subscription" "rclone_alerts_email" {
  count = var.enable_monitoring && var.alert_email_address != "" ? 1 : 0

  compartment_id = local.compartment_id
  topic_id       = oci_ons_notification_topic.rclone_alerts[0].topic_id
  protocol       = "EMAIL"
  endpoint       = var.alert_email_address
}
