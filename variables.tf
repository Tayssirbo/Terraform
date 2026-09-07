###############################################################################
# REQUIRED — no defaults. Terraform prompts if these are not set.
###############################################################################

variable "subscription_id" {
  description = "Azure subscription ID for the sandbox."
  type        = string
}

variable "allowed_source_cidrs" {
  description = <<-EOT
    Source CIDR ranges permitted to reach SSH and the service ports.

    Must be corporate ranges. The inference endpoint on port 8000 has no
    authentication of its own — anyone who can reach it can use the GPU.
  EOT
  type        = list(string)

  validation {
    condition     = !contains(var.allowed_source_cidrs, "0.0.0.0/0")
    error_message = "0.0.0.0/0 is not permitted. Specify corporate CIDR ranges."
  }
}

variable "cost_center" {
  description = "Cost centre code for tagging and chargeback."
  type        = string
}

###############################################################################
# Region and SKU — verify both before first apply. See README.
###############################################################################

variable "location" {
  description = <<-EOT
    Azure region. Must match the region where you hold NCADSH100v5 family
    quota — quota does not carry across regions.
  EOT
  type        = string
  default     = "germanywestcentral"
}

variable "vm_size" {
  description = <<-EOT
    VM SKU. Must be a member of the NCADSH100v5 family (the only family this
    sandbox has quota for). Default: one whole H100 NVL 94 GB, 40 vCPU.
  EOT
  type        = string
  default     = "Standard_NC40ads_H100_v5"
}

###############################################################################
# Naming and tags
###############################################################################

variable "project" {
  description = "Short project prefix used in every resource name."
  type        = string
  default     = "gpuvm"

  validation {
    condition     = can(regex("^[a-z0-9]{3,12}$", var.project))
    error_message = "project must be 3-12 lowercase alphanumeric characters."
  }
}

variable "environment" {
  description = "Environment tag and name component."
  type        = string
  default     = "sandbox"
}

variable "extra_tags" {
  description = "Additional tags merged onto every resource."
  type        = map(string)
  default     = {}
}

###############################################################################
# Compute
###############################################################################

variable "use_spot" {
  description = <<-EOT
    Run as a Spot instance. Substantially cheaper but evictable with about 30
    seconds notice. Inference is stateless, so eviction costs a restart rather
    than data. Spot availability on H100 v5 is unverified.
  EOT
  type        = bool
  default     = false
}

variable "spot_max_price" {
  description = "Maximum spot price per hour. -1 means pay up to the on-demand rate."
  type        = number
  default     = -1
}

variable "admin_username" {
  description = "Linux admin username."
  type        = string
  default     = "azureuser"
}

variable "ssh_public_key_path" {
  description = "Path to an existing SSH public key. Generate with: ssh-keygen -t ed25519"
  type        = string
  default     = "~/.ssh/id_rsa.pub"
}

variable "os_disk_size_gb" {
  description = "OS disk size in GB."
  type        = number
  default     = 128
}

variable "encryption_at_host_enabled" {
  description = <<-EOT
    Enable encryption at host. Requires the EncryptionAtHost subscription
    feature to be registered. Enabling it without registration fails the
    deployment, so this stays false until confirmed.

    Register with:
      az feature register --namespace Microsoft.Compute --name EncryptionAtHost
  EOT
  type        = bool
  default     = false
}

###############################################################################
# Model storage
###############################################################################

variable "models_disk_size_gb" {
  description = <<-EOT
    Persistent data disk for model weights, mounted at /models.

    This disk exists so weights survive deallocation. The SKU's local disk is
    ephemeral and is wiped on deallocate, which would force a re-download every
    time the VM restarts. Size for the total weights you plan to keep resident.
  EOT
  type        = number
  default     = 128
}

variable "models_disk_type" {
  description = "Managed disk SKU for /models. StandardSSD is adequate; Premium loads weights faster."
  type        = string
  default     = "StandardSSD_LRS"

  validation {
    condition     = contains(["StandardSSD_LRS", "Premium_LRS"], var.models_disk_type)
    error_message = "models_disk_type must be StandardSSD_LRS or Premium_LRS."
  }
}

###############################################################################
# Networking
###############################################################################

variable "service_ports" {
  description = <<-EOT
    Inbound TCP ports for the LLM inference stack.
    8000 (vLLM OpenAI-compatible endpoint), 3000 (Open WebUI).
  EOT
  type        = list(string)
  default     = ["8000", "3000"]
}

###############################################################################
# Host bootstrap
###############################################################################

variable "install_nvidia_driver" {
  description = <<-EOT
    Install the GPU driver via cloud-init.

    Set false to install manually or to use the NvidiaGpuDriverLinux VM
    extension. That extension lags on new GPU generations.
  EOT
  type        = bool
  default     = true
}

variable "nvidia_driver_branch" {
  description = <<-EOT
    NVIDIA driver branch. 550 or later supports Hopper (H100). The bootstrap
    falls back to the distro's recommended driver if the requested branch is
    unavailable, so a wrong value degrades rather than fails.
  EOT
  type        = string
  default     = "550"
}

###############################################################################
# Cost control
###############################################################################

variable "auto_shutdown_enabled" {
  description = "Enable the daily auto-shutdown schedule."
  type        = bool
  default     = true
}

variable "auto_shutdown_time" {
  description = "Daily auto-shutdown time, 24-hour HHmm, in auto_shutdown_timezone."
  type        = string
  default     = "1900"
}

variable "auto_shutdown_timezone" {
  description = "Timezone for the auto-shutdown schedule. Windows timezone naming."
  type        = string
  default     = "Romance Standard Time"
}

variable "auto_shutdown_notification_email" {
  description = "Email notified 30 minutes before auto-shutdown."
  type        = string
  default     = "tayssir.ben-othmen@oddo-bhf.com"
}
