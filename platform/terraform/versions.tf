# Which versions of Terraform and the Azure provider this project uses.
#
# Pinned on purpose. An unpinned provider upgrades itself on the next
# `terraform init`, and a major version can rename arguments underneath you.
# Same reasoning as pinning dbt in requirements.txt: my machine and CI run
# the same thing.

terraform {
  required_version = ">= 1.5"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0" # allow 4.x patches, never jump to 5.0
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "azurerm" {
  features {}

  # azurerm 4.0 made this mandatory. Before 4.0 it silently used whatever
  # subscription the az CLI happened to be on, which is exactly how people
  # deploy to the wrong account.
  subscription_id = var.subscription_id

  # Don't let the provider auto-register resource providers.
  #
  # By default azurerm registers every provider it supports on every run, then
  # waits for each one. On this subscription it hung waiting for Microsoft.AVS
  # (Azure VMware Solution) - something this project will never use.
  #
  # The two providers this project actually needs were registered once by hand:
  #   az provider register --namespace Microsoft.Storage  --wait
  #   az provider register --namespace Microsoft.EventGrid --wait
  #
  # Trade-off: adding a resource from a new provider now fails with a confusing
  # API-version error instead of self-healing. Register it by hand when that
  # happens. Worth it - plans go from minutes to seconds and stop depending on
  # services we don't use.
  resource_provider_registrations = "none"
}
