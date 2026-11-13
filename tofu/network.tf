# Created only when existing_subnet_id is null.

locals {
  create_network = var.existing_subnet_id == null
  subnet_id      = local.create_network ? oci_core_subnet.this[0].id : var.existing_subnet_id
}

resource "oci_core_vcn" "this" {
  count          = local.create_network ? 1 : 0
  compartment_id = local.compartment_id
  display_name   = "${var.name_prefix}-vcn"
  cidr_blocks    = ["10.1.0.0/16"]
  dns_label      = "tofuvcn"
  freeform_tags  = local.managed_tag

  depends_on = [terraform_data.always_free_guard]
}

resource "oci_core_internet_gateway" "this" {
  count          = local.create_network ? 1 : 0
  compartment_id = local.compartment_id
  vcn_id         = oci_core_vcn.this[0].id
  display_name   = "${var.name_prefix}-igw"
  enabled        = true
  freeform_tags  = local.managed_tag
}

resource "oci_core_default_route_table" "this" {
  count                      = local.create_network ? 1 : 0
  manage_default_resource_id = oci_core_vcn.this[0].default_route_table_id

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.this[0].id
  }
}

resource "oci_core_default_security_list" "this" {
  count                      = local.create_network ? 1 : 0
  manage_default_resource_id = oci_core_vcn.this[0].default_security_list_id

  egress_security_rules {
    destination = "0.0.0.0/0"
    protocol    = "all"
  }

  ingress_security_rules {
    description = "SSH"
    source      = var.ssh_allowed_cidr
    protocol    = "6" # TCP
    tcp_options {
      min = 22
      max = 22
    }
  }

  # Path MTU discovery (kept from OCI's default security list).
  ingress_security_rules {
    source   = "0.0.0.0/0"
    protocol = "1" # ICMP
    icmp_options {
      type = 3
      code = 4
    }
  }
}

resource "oci_core_subnet" "this" {
  count          = local.create_network ? 1 : 0
  compartment_id = local.compartment_id
  vcn_id         = oci_core_vcn.this[0].id
  display_name   = "${var.name_prefix}-subnet"
  cidr_block     = "10.1.0.0/24"
  dns_label      = "tofusub"
  freeform_tags  = local.managed_tag
}
