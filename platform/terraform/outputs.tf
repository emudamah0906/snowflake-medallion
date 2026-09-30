# What the next step needs.
#
# The Snowflake storage integration has to be told exactly where to read from,
# and the abfss:// URL is easy to get subtly wrong by hand. Printing it here
# means copying it, not typing it.

output "resource_group" {
  description = "Resource group holding everything in this phase."
  value       = azurerm_resource_group.main.name
}

output "storage_account" {
  description = "Storage account name. Includes the random suffix."
  value       = azurerm_storage_account.landing.name
}

output "container" {
  description = "Container files land in."
  value       = azurerm_storage_container.landing.name
}

output "abfss_url" {
  description = "Paste this into the Snowflake external stage URL."
  value       = "azure://${azurerm_storage_account.landing.name}.blob.core.windows.net/${azurerm_storage_container.landing.name}"
}

output "upload_command" {
  description = "Upload the source CSVs to the landing container."
  value = join(" ", [
    "az storage blob upload-batch",
    "--account-name ${azurerm_storage_account.landing.name}",
    "--destination ${azurerm_storage_container.landing.name}",
    "--source ../../data",
    "--pattern '*.csv'",
    "--auth-mode login",
  ])
}

# ---------------------------------------------------------------------------
# For the Snowflake notification integration (Snowpipe auto-ingest).
# ---------------------------------------------------------------------------
output "storage_queue_uri" {
  description = "Paste into AZURE_STORAGE_QUEUE_PRIMARY_URI on the notification integration."
  value       = "https://${azurerm_storage_account.landing.name}.queue.core.windows.net/${azurerm_storage_queue.snowpipe.name}"
}
