terraform {
  required_version = ">= 1.5"
  required_providers {
    oci = { source = "oracle/oci", version = ">= 5.0, < 9.0" }
  }
}

provider "oci" {
  config_file_profile = "DEFAULT"
  region              = var.region
}
