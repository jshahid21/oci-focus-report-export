resource "oci_identity_dynamic_group" "rclone_dg" {
  compartment_id = var.tenancy_ocid
  name           = "rclone-dg"
  description    = "Instance Principal for rclone sync VM"
  matching_rule  = "instance.compartment.id = '${local.compartment_id}'"
}

resource "oci_identity_policy" "rclone_policy" {
  compartment_id = var.tenancy_ocid
  name           = "rclone-cross-tenancy-policy"
  description    = "Bling access + Vault secrets for rclone sync"

  statements = [
    "Define tenancy usage-report as ocid1.tenancy.oc1..aaaaaaaaned4fkpkisbwjlr56u7cj63lf3wffbilvqknstgtvzub7vhqkggq",
    "Endorse dynamic-group ${oci_identity_dynamic_group.rclone_dg.name} to read objects in tenancy usage-report",
    "Endorse dynamic-group ${oci_identity_dynamic_group.rclone_dg.name} to read buckets in tenancy usage-report",
    "Allow dynamic-group ${oci_identity_dynamic_group.rclone_dg.name} to use secret-bundles in compartment id ${local.compartment_id}",
    "Allow dynamic-group ${oci_identity_dynamic_group.rclone_dg.name} to use ons-topics in compartment id ${local.compartment_id}"
  ]
}
