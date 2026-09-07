output "public_ip" {
  description = "Public IP of the sandbox VM."
  value       = azurerm_public_ip.main.ip_address
}

output "ssh_command" {
  description = "SSH into the VM."
  value       = "ssh ${var.admin_username}@${azurerm_public_ip.main.ip_address}"
}

output "vllm_endpoint" {
  description = "OpenAI-compatible inference endpoint. Point the scan runner here."
  value       = "http://${azurerm_public_ip.main.ip_address}:8000/v1"
}

output "open_webui_url" {
  description = "Open WebUI, once the stack is running."
  value       = "http://${azurerm_public_ip.main.ip_address}:3000"
}

output "vm_size" {
  description = "Provisioned VM SKU."
  value       = azurerm_linux_virtual_machine.main.size
}

output "models_disk" {
  description = "Persistent model storage. Survives deallocation; local disk does not."
  value = {
    mount_point = "/models"
    size_gb     = azurerm_managed_disk.models.disk_size_gb
    sku         = azurerm_managed_disk.models.storage_account_type
  }
}

output "lifecycle_commands" {
  description = "Start and stop the VM. Deallocating stops compute billing."
  value = {
    stop  = "az vm deallocate -g ${azurerm_resource_group.main.name} -n ${azurerm_linux_virtual_machine.main.name}"
    start = "az vm start -g ${azurerm_resource_group.main.name} -n ${azurerm_linux_virtual_machine.main.name}"
  }
}

output "post_apply_checklist" {
  description = "Steps Terraform cannot perform."
  value       = <<-EOT
    Bootstrap takes roughly 8-12 minutes and ends with an automatic reboot.

    1. Wait for the reboot, then SSH in.
    2. Check bootstrap finished:  ls /var/lib/cloud/stack-bootstrap-complete
    3. Check the log if not:      sudo cat /var/log/stack-bootstrap.log
    4. Verify the GPU:            nvidia-smi
    5. Verify persistent disk:    df -h /models
    6. Verify Docker sees GPU:    docker run --rm --gpus all nvidia/cuda:12.4.0-base-ubuntu22.04 nvidia-smi
    7. Download weights:          hf download Qwen/Qwen3.6-27B --local-dir /models/qwen36-27b
    8. Start the stack:           cd /opt/stack && docker compose up -d
    9. Smoke test:                curl http://localhost:8000/v1/models

    Deallocate when you finish for the day. Auto-shutdown is a backstop, not a
    substitute.
  EOT
}
