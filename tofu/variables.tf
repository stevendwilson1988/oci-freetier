variable "oci_config_profile" {
  description = "Profile in ~/.oci/config to authenticate with."
  type        = string
  default     = "DEFAULT"
}

variable "tenancy_ocid" {
  description = "Tenancy OCID. If null, read from the first `tenancy=` line of ~/.oci/config."
  type        = string
  default     = null
}

variable "compartment_id" {
  description = "Compartment to create resources in. If null, the tenancy (root compartment)."
  type        = string
  default     = null
}

variable "instance_names" {
  description = "One instance is created per name. Names are stable keys: renaming one replaces that instance."
  type        = list(string)
  default     = ["freetier-ubuntu-1", "freetier-ubuntu-2"]

  validation {
    condition     = length(var.instance_names) == length(distinct(var.instance_names))
    error_message = "instance_names must be unique."
  }
}

variable "instance_shape" {
  description = "Always Free shapes only."
  type        = string
  default     = "VM.Standard.A1.Flex"

  validation {
    condition     = contains(["VM.Standard.A1.Flex", "VM.Standard.E2.1.Micro"], var.instance_shape)
    error_message = "Only Always Free shapes are allowed: VM.Standard.A1.Flex or VM.Standard.E2.1.Micro."
  }
}

# Per-instance size for A1.Flex. Ignored for E2.1.Micro (fixed shape).
# The default fits beside the existing 2 OCPU / 12 GB `freetier-ubuntu` instance
# (4 OCPU / 24 GB A1 total across the tenancy).
variable "instance_ocpus" {
  description = "OCPUs per A1 instance."
  type        = number
  default     = 1
}

variable "instance_memory_gb" {
  description = "Memory (GB) per A1 instance."
  type        = number
  default     = 6
}

variable "boot_volume_gb" {
  description = "Boot volume size per instance. Counts toward the 200 GB combined storage limit."
  type        = number
  default     = 50

  validation {
    condition     = var.boot_volume_gb >= 50 && var.boot_volume_gb <= 200
    error_message = "boot_volume_gb must be between 50 and 200."
  }
}

variable "ubuntu_version" {
  description = "Canonical Ubuntu release to use."
  type        = string
  default     = "24.04"
}

variable "availability_domain_index" {
  description = "Which AD (0-based) to launch in. If you get 'Out of host capacity', try another index."
  type        = number
  default     = 0
}

variable "ssh_public_key_path" {
  description = "SSH public key installed for the `ubuntu` user."
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "ssh_allowed_cidr" {
  description = "Source CIDR allowed to reach SSH (port 22). Set it in terraform.tfvars (git-ignored); see terraform.tfvars.example."
  type        = string
  # No default: the plan fails rather than opening SSH to the internet.

  validation {
    condition     = can(cidrhost(var.ssh_allowed_cidr, 0)) && var.ssh_allowed_cidr != "0.0.0.0/0"
    error_message = "ssh_allowed_cidr must be a valid CIDR such as 203.0.113.7/32, and not 0.0.0.0/0."
  }
}

variable "existing_subnet_id" {
  description = "Put the instances in this existing public subnet instead of creating a new VCN. Saves one of the 2 free VCNs."
  type        = string
  default     = null
}

variable "name_prefix" {
  description = "Prefix for the network resources this config creates."
  type        = string
  default     = "freetier-tofu"
}
