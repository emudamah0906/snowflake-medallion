# ============================================================================
# Phase 2 — where the data lands
#
# WHAT THIS BUILDS
#   1. A resource group          a folder for everything below
#   2. A storage account         ADLS Gen2, the landing zone
#   3. A container               the folder inside it that files arrive in
#   4. A budget alert            emails me before the bill surprises me
#
# Snowflake reads from the container. Nothing here knows about Snowflake yet —
# that connection gets made in the next file, once these exist.
# ============================================================================


# ----------------------------------------------------------------------------
# A random suffix.
#
# Storage account names are globally unique across ALL of Azure, not just my
# subscription. "stmedallion" is almost certainly taken by someone. Six random
# characters make the name mine without me having to invent one.
#
# keepers is empty, so this is generated once and then stays put. Without it a
# later change could roll the suffix and Terraform would destroy and rebuild
# the storage account.
# ----------------------------------------------------------------------------
resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
  numeric = true
}


# ----------------------------------------------------------------------------
# 1. Resource group — a folder. Deleting it deletes everything inside, which
#    is the whole teardown story for this phase.
# ----------------------------------------------------------------------------
resource "azurerm_resource_group" "main" {
  name     = "rg-${var.project}-${var.location}"
  location = var.location
  tags     = var.tags
}


# ----------------------------------------------------------------------------
# 2. Storage account — the landing zone.
#
# is_hns_enabled = true is the line that matters. HNS is the hierarchical
# namespace: it turns plain blob storage into ADLS Gen2, giving real folders
# and per-folder permissions instead of filenames that merely contain slashes.
# It CANNOT be switched on afterwards. Get it wrong and you rebuild.
#
# Standard + LRS is the cheapest tier. LRS keeps three copies inside one
# datacentre. For a few MB of CSV that is plenty.
# ----------------------------------------------------------------------------
resource "azurerm_storage_account" "landing" {
  name                = "st${var.project}${random_string.suffix.result}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location

  account_tier             = "Standard"
  account_replication_type = "LRS"
  account_kind             = "StorageV2"
  is_hns_enabled           = true # ADLS Gen2. Cannot be changed later.

  # Security defaults. Azure's own defaults are looser than this.
  https_traffic_only_enabled      = true
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
  shared_access_key_enabled       = true # Snowflake's storage integration needs it

  blob_properties {
    # Keeps 7 days of history if a file is overwritten or deleted by mistake.
    delete_retention_policy {
      days = 7
    }
  }

  tags = var.tags
}


# ----------------------------------------------------------------------------
# 3. Container — the folder files land in.
#
# "private" means nothing is readable without credentials. A public container
# is how storage accounts end up in news articles.
# ----------------------------------------------------------------------------
resource "azurerm_storage_container" "landing" {
  name                  = "landing"
  storage_account_id    = azurerm_storage_account.landing.id
  container_access_type = "private"
}


# ----------------------------------------------------------------------------
# 4. Budget alert.
#
# This ALERTS. It does not stop anything — Azure budgets cannot switch
# resources off, unlike the Snowflake resource monitor in Phase 1, which
# genuinely suspends the warehouses at 100%. Worth knowing the difference:
# one is a brake, this is a warning light.
#
# Two thresholds: 80% of actual spend, and 100% of FORECAST. The forecast one
# fires before the money is gone, which is the point.
# ----------------------------------------------------------------------------
resource "azurerm_consumption_budget_subscription" "monthly" {
  name            = "budget-${var.project}"
  subscription_id = "/subscriptions/${var.subscription_id}"

  amount     = var.budget_amount
  time_grain = "Monthly"

  time_period {
    # Budgets must start on the first of a month, at or before today.
    start_date = formatdate("YYYY-MM-01'T'00:00:00Z", timestamp())
  }

  notification {
    enabled        = true
    threshold      = 80
    operator       = "GreaterThan"
    threshold_type = "Actual"
    contact_emails = [var.budget_alert_email]
  }

  notification {
    enabled        = true
    threshold      = 100
    operator       = "GreaterThan"
    threshold_type = "Forecasted"
    contact_emails = [var.budget_alert_email]
  }

  # start_date is computed from today's date, so it would look "changed" on
  # every plan. Ignore it after creation.
  lifecycle {
    ignore_changes = [time_period]
  }
}
