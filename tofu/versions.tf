terraform {
  required_version = ">= 1.6.0" # OpenTofu

  required_providers {
    oci = {
      source  = "oracle/oci"
      version = ">= 6.0.0, < 8.0.0"
    }
  }
}

# Auth comes from ~/.oci/config (same file the oci CLI and the bash scripts use).
provider "oci" {
  config_file_profile = var.oci_config_profile
}
