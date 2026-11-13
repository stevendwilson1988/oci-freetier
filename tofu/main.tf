data "oci_core_images" "ubuntu" {
  compartment_id           = local.compartment_id
  operating_system         = "Canonical Ubuntu"
  operating_system_version = var.ubuntu_version
  shape                    = var.instance_shape # picks aarch64 for A1, x86_64 for E2
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

resource "oci_core_instance" "ubuntu" {
  for_each = toset(var.instance_names)

  compartment_id      = local.compartment_id
  availability_domain = local.ad_names[var.availability_domain_index]
  display_name        = each.key
  shape               = var.instance_shape
  freeform_tags       = local.managed_tag

  dynamic "shape_config" {
    for_each = local.is_a1 ? [1] : []
    content {
      ocpus         = var.instance_ocpus
      memory_in_gbs = var.instance_memory_gb
    }
  }

  source_details {
    source_type             = "image"
    source_id               = data.oci_core_images.ubuntu.images[0].id
    boot_volume_size_in_gbs = var.boot_volume_gb
    boot_volume_vpus_per_gb = 10 # Balanced (default). Higher costs money.
  }

  create_vnic_details {
    subnet_id        = local.subnet_id
    assign_public_ip = true
    hostname_label   = replace(each.key, "/[^a-zA-Z0-9]/", "")
  }

  metadata = {
    ssh_authorized_keys = file(pathexpand(var.ssh_public_key_path))
  }

  # `tofu destroy` must also delete the boot volume, or it keeps counting
  # toward the 200 GB limit.
  preserve_boot_volume = false

  lifecycle {
    # A newer Ubuntu image release must not destroy and recreate running instances.
    ignore_changes = [source_details[0].source_id, metadata]
  }

  depends_on = [terraform_data.always_free_guard]
}
