# Inputs. Real values go in terraform.tfvars, which Git ignores.
# See terraform.tfvars.example for what to set.

variable "subscription_id" {
  description = "Azure subscription to deploy into. Find it with: az account show --query id -o tsv"
  type        = string
}

variable "location" {
  description = <<-EOT
    Azure region. Keep this matching the Snowflake account's region.
    Snowflake is on Azure canadacentral, so the storage sits there too.
    Reading across regions costs egress and adds latency for no benefit,
    and a storage account cannot be moved between regions afterwards.
  EOT
  type        = string
  default     = "canadacentral"
}

variable "project" {
  description = "Short name used in every resource name. Lowercase letters and digits only."
  type        = string
  default     = "medallion"

  validation {
    condition     = can(regex("^[a-z0-9]{3,12}$", var.project))
    error_message = "project must be 3-12 lowercase letters or digits (storage account names are strict)."
  }
}

variable "budget_amount" {
  description = "Monthly spend cap alert, in the subscription's currency. Alerts only - Azure does not stop resources."
  type        = number
  default     = 5
}

variable "budget_alert_email" {
  description = "Where budget alerts go. Kept out of the repo, since it is a real address."
  type        = string
}

variable "tags" {
  description = "Applied to everything, so the bill can be read per project."
  type        = map(string)
  default = {
    project    = "snowflake-medallion"
    managed_by = "terraform"
  }
}
