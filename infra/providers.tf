terraform {
  required_version = ">= 1.5"
  required_providers {
    oci = { source = "oracle/oci", version = ">= 5.0, < 9.0" }
  }
}

# auth = "APIKey"           — default; reads ~/.oci/config (workstation, OL8/9, Windows)
# auth = "SecurityToken"    — OCI Cloud Shell; reads session token from ~/.oci/config
#
# Override without editing this file:
#   export TF_VAR_oci_auth=SecurityToken   (Cloud Shell)
#   export TF_VAR_oci_auth=APIKey          (everywhere else)
variable "oci_auth" {
  description = "OCI provider auth method. APIKey for workstation; SecurityToken for OCI Cloud Shell."
  type        = string
  default     = "APIKey"
}

provider "oci" {
  auth                = var.oci_auth
  config_file_profile = "DEFAULT"
  region              = var.region
}
