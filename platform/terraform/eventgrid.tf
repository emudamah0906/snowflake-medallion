# ============================================================================
# The plumbing that makes loading automatic
#
# A blob lands in the container. Something has to tell Snowflake. That chain:
#
#   blob uploaded
#     -> Event Grid system topic notices        (Azure watches the account)
#     -> event subscription routes the event    (a rule: which events, where)
#     -> Azure Storage Queue holds the message  (a durable inbox)
#     -> Snowflake reads the queue and ingests  (Snowpipe, next file)
#
# WHY A QUEUE IN THE MIDDLE
#   Event Grid could call a webhook directly, but then a message is lost if the
#   listener is down. A queue holds messages until something collects them, so
#   Snowflake being briefly unavailable delays the load instead of losing it.
#   Snowflake on Azure requires the queue for exactly this reason.
# ============================================================================


# ----------------------------------------------------------------------------
# The inbox. Event Grid writes here; Snowflake reads and deletes.
# ----------------------------------------------------------------------------
resource "azurerm_storage_queue" "snowpipe" {
  name               = "snowpipe-events"
  storage_account_id = azurerm_storage_account.landing.id
}


# ----------------------------------------------------------------------------
# The watcher.
#
# A "system topic" is Azure's built-in event source for a resource - here, the
# storage account. It exists so you can subscribe to what the account does.
# It emits nothing by itself until something subscribes.
# ----------------------------------------------------------------------------
resource "azurerm_eventgrid_system_topic" "storage" {
  name                   = "evgt-${var.project}"
  resource_group_name    = azurerm_resource_group.main.name
  location               = azurerm_resource_group.main.location
  source_arm_resource_id = azurerm_storage_account.landing.id
  topic_type             = "Microsoft.Storage.StorageAccounts"
  tags                   = var.tags
}


# ----------------------------------------------------------------------------
# The rule: which events go where.
#
# Two filters, both deliberate:
#
#   included_event_types = BlobCreated only.
#     Deletes, property changes and tier changes are ignored. Snowpipe only
#     cares that a new file arrived.
#
#   subject_begins_with = the landing container.
#     Without it, every container on this storage account would notify
#     Snowflake - including ones added later for something unrelated.
# ----------------------------------------------------------------------------
resource "azurerm_eventgrid_system_topic_event_subscription" "to_queue" {
  name                = "evgs-${var.project}-snowpipe"
  system_topic        = azurerm_eventgrid_system_topic.storage.name
  resource_group_name = azurerm_resource_group.main.name

  storage_queue_endpoint {
    storage_account_id = azurerm_storage_account.landing.id
    queue_name         = azurerm_storage_queue.snowpipe.name
  }

  included_event_types = ["Microsoft.Storage.BlobCreated"]

  subject_filter {
    subject_begins_with = "/blobServices/default/containers/${azurerm_storage_container.landing.name}/"
  }

  # If Snowflake cannot be reached, keep retrying for a day rather than
  # dropping the event after the default few hours.
  retry_policy {
    max_delivery_attempts = 30
    event_time_to_live    = 1440 # minutes
  }
}
