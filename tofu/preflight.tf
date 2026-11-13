# Pre-flight: count Always Free usage across the WHOLE tenancy (every compartment)
# and refuse to plan anything that would push past a limit. See ../CLAUDE.md.
#
# Resources owned by this config carry the `managed-by` freeform tag and are
# excluded from "existing" usage, then counted again from the desired config.
# That way re-planning never double counts, and resizing is checked correctly.

locals {
  free_a1_ocpus      = 4
  free_a1_memory_gb  = 24
  free_e2_micro      = 2
  free_storage_gb    = 200 # boot + block volumes combined
  free_vcns          = 2
  live_volume_states = ["PROVISIONING", "AVAILABLE", "RESTORING", "FAULTY"]

  tenancy_ocid   = coalesce(var.tenancy_ocid, regex("(?m)^tenancy\\s*=\\s*(\\S+)", file(pathexpand("~/.oci/config")))[0])
  compartment_id = coalesce(var.compartment_id, local.tenancy_ocid)
  ad_names       = data.oci_identity_availability_domains.ads.availability_domains[*].name

  managed_tag = { "managed-by" = "opentofu-oci-freetier" }
}

data "oci_identity_availability_domains" "ads" {
  compartment_id = local.tenancy_ocid
}

data "oci_identity_compartments" "all" {
  compartment_id            = local.tenancy_ocid
  compartment_id_in_subtree = true
  access_level              = "ANY"
  state                     = "ACTIVE"
}

locals {
  all_compartment_ids = toset(concat([local.tenancy_ocid], data.oci_identity_compartments.all.compartments[*].id))
  compartment_ad_pairs = {
    for pair in setproduct(local.all_compartment_ids, local.ad_names) : "${pair[0]}|${pair[1]}" => pair
  }
}

data "oci_core_instances" "all" {
  for_each       = local.all_compartment_ids
  compartment_id = each.value
}

data "oci_core_boot_volumes" "all" {
  for_each            = local.compartment_ad_pairs
  compartment_id      = each.value[0]
  availability_domain = each.value[1]
}

data "oci_core_boot_volume_attachments" "all" {
  for_each            = local.compartment_ad_pairs
  compartment_id      = each.value[0]
  availability_domain = each.value[1]
}

data "oci_core_volumes" "all" {
  for_each       = local.all_compartment_ids
  compartment_id = each.value
}

data "oci_core_vcns" "all" {
  for_each       = local.all_compartment_ids
  compartment_id = each.value
}

locals {
  # ---- Existing usage (excluding resources this config manages) ----
  live_instances = [
    for i in flatten([for d in data.oci_core_instances.all : d.instances]) : i
    if !contains(["TERMINATED", "TERMINATING"], i.state)
  ]
  is_managed       = { for i in local.live_instances : i.id => try(i.freeform_tags["managed-by"], "") == local.managed_tag["managed-by"] }
  other_instances  = [for i in local.live_instances : i if !local.is_managed[i.id]]
  managed_inst_ids = [for i in local.live_instances : i.id if local.is_managed[i.id]]

  managed_boot_volume_ids = [
    for a in flatten([for d in data.oci_core_boot_volume_attachments.all : d.boot_volume_attachments]) : a.boot_volume_id
    if contains(local.managed_inst_ids, a.instance_id) && contains(["ATTACHING", "ATTACHED"], a.state)
  ]

  other_boot_volumes = [
    for v in flatten([for d in data.oci_core_boot_volumes.all : d.boot_volumes]) : v
    if contains(local.live_volume_states, v.state) && !contains(local.managed_boot_volume_ids, v.id)
  ]
  other_block_volumes = [
    for v in flatten([for d in data.oci_core_volumes.all : d.volumes]) : v
    if contains(local.live_volume_states, v.state)
  ]
  other_vcns = [
    for v in flatten([for d in data.oci_core_vcns.all : d.virtual_networks]) : v
    if !contains(["TERMINATED", "TERMINATING"], v.state) && try(v.freeform_tags["managed-by"], "") != local.managed_tag["managed-by"]
  ]

  used_a1_ocpus  = sum(concat([0], [for i in local.other_instances : i.shape_config[0].ocpus if i.shape == "VM.Standard.A1.Flex"]))
  used_a1_mem_gb = sum(concat([0], [for i in local.other_instances : i.shape_config[0].memory_in_gbs if i.shape == "VM.Standard.A1.Flex"]))
  used_e2_micro  = length([for i in local.other_instances : i if i.shape == "VM.Standard.E2.1.Micro"])
  used_storage   = sum(concat([0], [for v in concat(local.other_boot_volumes, local.other_block_volumes) : tonumber(v.size_in_gbs)]))
  used_vcns      = length(local.other_vcns)

  # ---- What this config wants ----
  n          = length(var.instance_names)
  is_a1      = var.instance_shape == "VM.Standard.A1.Flex"
  new_ocpus  = local.is_a1 ? local.n * var.instance_ocpus : 0
  new_mem_gb = local.is_a1 ? local.n * var.instance_memory_gb : 0
  new_e2     = local.is_a1 ? 0 : local.n
  new_gb     = local.n * var.boot_volume_gb
  new_vcns   = var.existing_subnet_id == null ? 1 : 0

  usage_report = <<-EOT
    A1 OCPUs:  ${local.used_a1_ocpus} other + ${local.new_ocpus} here (limit ${local.free_a1_ocpus})
    A1 memory: ${local.used_a1_mem_gb} GB other + ${local.new_mem_gb} GB here (limit ${local.free_a1_memory_gb} GB)
    E2 Micro:  ${local.used_e2_micro} other + ${local.new_e2} here (limit ${local.free_e2_micro})
    Storage:   ${local.used_storage} GB other + ${local.new_gb} GB here (limit ${local.free_storage_gb} GB)
    VCNs:      ${local.used_vcns} other + ${local.new_vcns} here (limit ${local.free_vcns})
  EOT
}

# Everything this config creates depends on this, so a failed precondition
# stops the plan before any resource is touched.
resource "terraform_data" "always_free_guard" {
  input = local.usage_report

  lifecycle {
    precondition {
      condition     = local.used_a1_ocpus + local.new_ocpus <= local.free_a1_ocpus
      error_message = "Would exceed Always Free A1 OCPUs.\n${local.usage_report}"
    }
    precondition {
      condition     = local.used_a1_mem_gb + local.new_mem_gb <= local.free_a1_memory_gb
      error_message = "Would exceed Always Free A1 memory.\n${local.usage_report}"
    }
    precondition {
      condition     = local.used_e2_micro + local.new_e2 <= local.free_e2_micro
      error_message = "Would exceed Always Free E2.1.Micro instance count.\n${local.usage_report}"
    }
    precondition {
      condition     = local.used_storage + local.new_gb <= local.free_storage_gb
      error_message = "Would exceed Always Free 200 GB block + boot volume storage.\n${local.usage_report}"
    }
    precondition {
      condition     = local.used_vcns + local.new_vcns <= local.free_vcns
      error_message = "Would exceed Always Free VCN count. Set existing_subnet_id to reuse a subnet.\n${local.usage_report}"
    }
  }
}
