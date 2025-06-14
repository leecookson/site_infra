
# Variables
variable "resource_group_name" {
  description = "The name of the Azure Resource Group."
  type        = string
  default     = "rg-cooksonpro-site"
}

variable "location" {
  description = "The Azure region for the resources."
  type        = string
  default     = "EastUS" # Choose a region appropriate for your resources
}

variable "domain_name" {
  description = "The primary domain name for the site (e.g., cookson.pro)."
  type        = string
  default     = "www.az.cookson.pro"
}

variable "api_origin_domain" {
  description = "The domain name for the API origin (e.g., api.cookson.pro)."
  type        = string
  default     = "api.cookson.pro"
}

variable "storage_account_name" {
  description = "The globally unique name for the Azure Storage Account for static content. (3-24 chars, lowercase letters and numbers)"
  type        = string
  default     = "cooksonprostaticsite" # CHANGE THIS to a globally unique name
}

variable "storage_container_name" {
  description = "The name of the Azure Blob Storage container for static content."
  type        = string
  default     = "$web" # Common name for web content, e.g., $web
}

variable "frontdoor_profile_name" {
  description = "The name for the Azure Front Door Profile."
  type        = string
  default     = "afd-cooksonpro-profile"
}

variable "frontdoor_endpoint_name" {
  description = "The globally unique name for the Azure Front Door Endpoint."
  type        = string
  default     = "afd-cooksonpro-endpoint" # CHANGE THIS to a globally unique name (e.g., cooksonpro-afd)
}

# DNS Resource Group
data "azurerm_resource_group" "dnsresources" {
  name = "dnsresources"
}

data "azurerm_dns_zone" "az_cookson_pro" {
  name                = "az.cookson.pro"
  resource_group_name = "dnsresources"
}

# Resource Group
resource "azurerm_resource_group" "main" {
  name     = var.resource_group_name
  location = var.location
}

# Storage Account for static website content
resource "azurerm_storage_account" "content_storage" {
  name                     = var.storage_account_name
  resource_group_name      = azurerm_resource_group.main.name
  location                 = azurerm_resource_group.main.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  account_kind             = "StorageV2"
  min_tls_version          = "TLS1_2"

  tags = {
    environment = "production"
    project     = var.domain_name
  }
}

resource "azurerm_storage_account_static_website" "static_website" {
  storage_account_id = azurerm_storage_account.content_storage.id
  error_404_document = "404.html"
  index_document     = "index.html"
}
resource "azurerm_storage_container" "content_container" {
  name                  = var.storage_container_name
  storage_account_id    = azurerm_storage_account.content_storage.id
  container_access_type = "blob" # Anonymous read access for blobs
}

# resource "azurerm_storage_blob" "index_html" {
#   name                   = "index.html"
#   storage_account_name   = azurerm_storage_account.content_storage.name
#   storage_container_name = azurerm_storage_container.content_container.name
#   type                   = "Block"
#   content_type           = "text/html"
#   source                 = "./static/index.html"
# }

# resource "azurerm_storage_blob" "web_404_html" {
#   name                   = "404.html"
#   storage_account_name   = azurerm_storage_account.content_storage.name
#   storage_container_name = azurerm_storage_container.content_container.name
#   type                   = "Block"
#   content_type           = "text/html"
#   source                 = "./static/404.html"
# }

resource "azurerm_storage_blob" "all_static" {
  for_each               = fileset("./static", "*")
  name                   = each.value
  storage_account_name   = azurerm_storage_account.content_storage.name
  storage_container_name = azurerm_storage_container.content_container.name
  type                   = "Block"
  source                 = "./static/${each.value}"
  content_type           = "text/html"
  cache_control          = "public, max-age=1200"
  content_md5            = filemd5("./static/${each.value}")
}

# Azure Front Door Profile (Standard SKU)
resource "azurerm_cdn_frontdoor_profile" "main" {
  name                = var.frontdoor_profile_name
  resource_group_name = azurerm_resource_group.main.name
  sku_name            = "Standard_AzureFrontDoor" # Use Standard or Premium

  tags = {
    environment = "production"
    project     = var.domain_name
  }
}

# Azure Front Door Endpoint
resource "azurerm_cdn_frontdoor_endpoint" "main" {
  name                     = var.frontdoor_endpoint_name
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.main.id
  enabled                  = true

  tags = {
    environment = "production"
    project     = var.domain_name
  }
}

# Origin Group for Static Content (Azure Blob Storage)
resource "azurerm_cdn_frontdoor_origin_group" "static_content_origin_group" {
  name                     = "StaticContentOriginGroup"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.main.id
  session_affinity_enabled = false

  health_probe {
    path                = "/" # Basic health probe path for the storage origin
    protocol            = "Https"
    interval_in_seconds = 100
  }

  load_balancing {
    sample_size                 = 4
    successful_samples_required = 2
  }
}

resource "azurerm_cdn_frontdoor_origin" "static_content_origin" {
  name                           = "StaticStorageOrigin"
  cdn_frontdoor_origin_group_id  = azurerm_cdn_frontdoor_origin_group.static_content_origin_group.id
  enabled                        = true
  host_name                      = azurerm_storage_account.content_storage.primary_web_host
  origin_host_header             = azurerm_storage_account.content_storage.primary_web_host
  http_port                      = 80
  https_port                     = 443
  priority                       = 1
  weight                         = 1000
  certificate_name_check_enabled = false # Blob storage uses a wildcard cert
}

# Origin Group for API
resource "azurerm_cdn_frontdoor_origin_group" "api_origin_group" {
  name                     = "APIOriginGroup"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.main.id
  session_affinity_enabled = false # Typically false for stateless APIs

  health_probe {
    path                = "/api/health" # Example health check endpoint for your API
    protocol            = "Https"
    interval_in_seconds = 100
  }
  load_balancing {
    sample_size                 = 4
    successful_samples_required = 2
  }
}

resource "azurerm_cdn_frontdoor_origin" "api_origin" {
  name                           = "APIOrigin"
  cdn_frontdoor_origin_group_id  = azurerm_cdn_frontdoor_origin_group.api_origin_group.id
  enabled                        = true
  host_name                      = var.api_origin_domain
  origin_host_header             = var.api_origin_domain # Forward original host or set to API domain
  http_port                      = 80                    # Or disable if API is HTTPS only
  https_port                     = 443
  priority                       = 1
  weight                         = 1000
  certificate_name_check_enabled = true # Ensure API origin has a valid cert for its hostname
}

# Custom Domain for cookson.pro with Azure-managed TLS
resource "azurerm_cdn_frontdoor_custom_domain" "main_custom_domain" {
  name                     = "www-az-cookson-pro"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.main.id
  host_name                = var.domain_name
  dns_zone_id              = data.azurerm_dns_zone.az_cookson_pro.id

  tls {
    certificate_type = "ManagedCertificate"
  }
  # This resource will output DNS records needed for validation if dns_zone_id is not used or if manual validation is required.
  # Typically, a CNAME record `afdverify.yourdomain.com` pointing to `afdverify.your-endpoint-name.azurefd.net`
}

resource "azurerm_dns_txt_record" "example" {
  name                = "_dnsauth.www"
  zone_name           = data.azurerm_dns_zone.az_cookson_pro.name
  resource_group_name = data.azurerm_resource_group.dnsresources.name
  ttl                 = 300

  record {
    value = azurerm_cdn_frontdoor_custom_domain.main_custom_domain.validation_token
  }
}
# Rule Set for API (to disable caching)
resource "azurerm_cdn_frontdoor_rule_set" "api_rules" {
  name                     = "APIRuleSet"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.main.id
}

resource "azurerm_cdn_frontdoor_rule" "api_no_cache" {
  name                      = "APINoCacheRule"
  cdn_frontdoor_rule_set_id = azurerm_cdn_frontdoor_rule_set.api_rules.id
  order                     = 1
  behavior_on_match         = "Continue" # Allows other conditions/actions if any

  actions {
    route_configuration_override_action {
      forwarding_protocol           = "HttpsOnly" # Connect to origin via HTTPS
      cdn_frontdoor_origin_group_id = azurerm_cdn_frontdoor_origin_group.api_origin_group.id
      cache_behavior                = "Disabled"
    }
  } # Disable caching for API paths
  # No condition needed here if this rule set is only applied to the API route
}


# Route for API requests (/api/*)
resource "azurerm_cdn_frontdoor_route" "api_route" {
  name                            = "api-route"
  cdn_frontdoor_endpoint_id       = azurerm_cdn_frontdoor_endpoint.main.id
  cdn_frontdoor_origin_group_id   = azurerm_cdn_frontdoor_origin_group.api_origin_group.id
  cdn_frontdoor_origin_ids        = [azurerm_cdn_frontdoor_origin.api_origin.id]
  cdn_frontdoor_custom_domain_ids = [azurerm_cdn_frontdoor_custom_domain.main_custom_domain.id]
  cdn_frontdoor_rule_set_ids      = [azurerm_cdn_frontdoor_rule_set.api_rules.id] # Apply API specific rules
  enabled                         = true
  forwarding_protocol             = "HttpsOnly" # Connect to origin via HTTPS
  https_redirect_enabled          = true        # Redirect HTTP client requests to HTTPS
  patterns_to_match               = ["/api/*"]
  supported_protocols             = ["Http", "Https"]
  link_to_default_domain          = false # Only apply to custom domain for this specific path

  cache {
    query_string_caching_behavior = "UseQueryString" # Forward all query params for API
    compression_enabled           = true             # Enable compression if API supports it
    content_types_to_compress     = ["text/html", "text/javascript", "text/xml"]
  }
  depends_on = [azurerm_cdn_frontdoor_custom_domain.main_custom_domain]
}

# Default Route for static content (/*)
resource "azurerm_cdn_frontdoor_route" "default_route" {
  name                            = "default-route"
  cdn_frontdoor_origin_ids        = [azurerm_cdn_frontdoor_origin.static_content_origin.id]
  cdn_frontdoor_endpoint_id       = azurerm_cdn_frontdoor_endpoint.main.id
  cdn_frontdoor_origin_group_id   = azurerm_cdn_frontdoor_origin_group.static_content_origin_group.id
  cdn_frontdoor_custom_domain_ids = [azurerm_cdn_frontdoor_custom_domain.main_custom_domain.id]
  # cdn_frontdoor_rule_set_ids      = [] # Can add a ruleset for static content if needed
  enabled                = true
  forwarding_protocol    = "HttpsOnly" # Connect to origin via HTTPS
  https_redirect_enabled = true        # Redirect HTTP client requests to HTTPS
  patterns_to_match      = ["/*", "/"]
  supported_protocols    = ["Http", "Https"]
  link_to_default_domain = true # Also apply to the azurefd.net endpoint

  cache {
    query_string_caching_behavior = "IgnoreQueryString" # Good for static assets
    compression_enabled           = true
    content_types_to_compress     = ["text/html", "text/javascript", "text/xml"]
  }
  depends_on = [azurerm_cdn_frontdoor_custom_domain.main_custom_domain, azurerm_cdn_frontdoor_route.api_route] # Ensure API route is evaluated first
}


# DNS CNAME Record for cookson.pro pointing to Front Door Endpoint
resource "azurerm_dns_cname_record" "main_domain_cname" {
  name                = "www"
  zone_name           = data.azurerm_dns_zone.az_cookson_pro.name
  resource_group_name = data.azurerm_resource_group.dnsresources.name
  ttl                 = 300
  record              = azurerm_cdn_frontdoor_endpoint.main.host_name

  # Ensure custom domain validation is complete before creating this CNAME
  # The custom domain resource itself handles the validation process.
  # This CNAME is the final step to point your domain to the AFD endpoint.
  depends_on = [azurerm_cdn_frontdoor_custom_domain.main_custom_domain]
}

# Outputs
output "frontdoor_endpoint_hostname" {
  description = "The hostname of the Azure Front Door endpoint."
  value       = azurerm_cdn_frontdoor_endpoint.main.host_name
}

output "custom_domain_validation_dns_records" {
  description = "DNS records required for custom domain validation (if manual steps are needed, usually TXT or afdverify CNAME)."
  value       = azurerm_cdn_frontdoor_custom_domain.main_custom_domain.validation_token # This attribute might not exist directly, check docs.
  # Validation is usually handled by Azure when dns_zone_id is provided,
  # or by creating a CNAME like 'afdverify.cookson.pro'.
  # The resource should manage this.
}

output "storage_account_primary_blob_endpoint" {
  description = "The primary blob endpoint for the static content storage account."
  value       = azurerm_storage_account.content_storage.primary_blob_endpoint
}

output "static_content_container_url" {
  description = "URL to the static content container (note: access is via Front Door)."
  value       = "${azurerm_storage_account.content_storage.primary_blob_endpoint}${azurerm_storage_container.content_container.name}/"
}

output "azurerm_cdn_frontdoor_endpoint_main" {
  description = "FrontDoor Endpoint config"
  value       = "azurerm_cdn_frontdoor_endpoint.main"
}