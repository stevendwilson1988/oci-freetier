output "ssh_commands" {
  value = { for name, i in oci_core_instance.ubuntu : name => "ssh ubuntu@${i.public_ip}" }
}

output "image" {
  value = data.oci_core_images.ubuntu.images[0].display_name
}

output "always_free_usage" {
  description = "Tenancy usage at plan time (other resources + this config)."
  value       = local.usage_report
}
