data "google_project" "cookson_pro" {
  project_id = "cookson-pro-gcp"
}

data "google_dns_managed_zone" "gcp_cookson_pro" {
  project = data.google_project.cookson_pro.project_id

  name = "gcp-cookson-pro-zone"
}

# 1. Reserve a global static IP address for the load balancer
resource "google_compute_global_address" "cdn_ip" {
  project = data.google_project.cookson_pro.project_id
  name    = "cdn-ip-www-gcp-cookson-pro"
}

# 1.5 add CNAME to point to the CDN domain
resource "google_dns_record_set" "site_a_record" {
  project      = data.google_project.cookson_pro.project_id
  name         = "${var.site_domain}." # Replace with the actual name provided by GCP
  type         = "A"
  ttl          = 300
  managed_zone = data.google_dns_managed_zone.gcp_cookson_pro.name
  rrdatas      = [google_compute_global_address.cdn_ip.address] # Replace with the actual value provided by GCP
}

resource "google_certificate_manager_certificate" "cookson_pro" {
  project  = data.google_project.cookson_pro.project_id
  name     = "managed-cert"
  location = "global"
  scope    = "DEFAULT"
  managed {
    domains = [
      google_certificate_manager_dns_authorization.cookson_pro.domain,
    ]
    dns_authorizations = [
      google_certificate_manager_dns_authorization.cookson_pro.id,
    ]
  }
}

resource "google_certificate_manager_dns_authorization" "cookson_pro" {
  project  = data.google_project.cookson_pro.project_id
  name     = "cookson-pro-auth"
  location = "global"
  domain   = var.site_domain
}
locals {
  dns_resource_record = google_certificate_manager_dns_authorization.cookson_pro.dns_resource_record.0
}
resource "google_dns_record_set" "cert_validation_cname" {
  project      = data.google_project.cookson_pro.project_id
  name         = local.dns_resource_record.name
  type         = local.dns_resource_record.type
  ttl          = 300
  managed_zone = data.google_dns_managed_zone.gcp_cookson_pro.name
  rrdatas      = [local.dns_resource_record.data]
}

resource "google_certificate_manager_certificate_map" "cookson_pro" {
  project     = data.google_project.cookson_pro.project_id
  name        = "my-cert-map"
  description = "A certificate map for global certificates"
}

resource "google_certificate_manager_certificate_map_entry" "cookson_pro" {
  project      = data.google_project.cookson_pro.project_id
  name         = "test-entry"
  map          = google_certificate_manager_certificate_map.cookson_pro.name
  hostname     = var.site_domain
  certificates = [google_certificate_manager_certificate.cookson_pro.id]
}


# 3. Create a Cloud Storage bucket for static website content
resource "google_storage_bucket" "static_site_bucket" {
  project                     = data.google_project.cookson_pro.project_id
  name                        = "www-gcp-cookson-pro-static-assets" # Bucket names must be globally unique
  location                    = "US"                                # Choose an appropriate multi-region or region
  uniform_bucket_level_access = true
  force_destroy               = true # Consider setting to false in production

  website {
    main_page_suffix = "index.html"
    not_found_page   = "404.html"
  }
}

# Grant public read access to the bucket objects for the CDN
resource "google_storage_bucket_iam_member" "public_reader" {
  bucket = google_storage_bucket.static_site_bucket.name
  role   = "roles/storage.objectViewer"
  member = "allUsers"
}

# 4. Create a backend bucket for serving static content from GCS
resource "google_compute_backend_bucket" "static_site_backend_bucket" {
  project     = data.google_project.cookson_pro.project_id
  name        = "bb-static-www-gcp-cookson-pro"
  description = "Backend bucket for static website content"
  bucket_name = google_storage_bucket.static_site_bucket.name
  enable_cdn  = true
}

# 5. Define the Internet NEG for the external API (api.cookson.pro)
resource "google_compute_global_network_endpoint_group" "api_neg" {
  project               = data.google_project.cookson_pro.project_id
  name                  = "neg-api-cookson-pro-external"
  network_endpoint_type = "INTERNET_FQDN_PORT"
  default_port          = 443 # Assuming api.cookson.pro is served over HTTPS on port 443
}

# Add the FQDN endpoint to the NEG
resource "google_compute_global_network_endpoint" "api_fqdn_endpoint" {
  project                       = data.google_project.cookson_pro.project_id
  global_network_endpoint_group = google_compute_global_network_endpoint_group.api_neg.id
  fqdn                          = "api.cookson.pro"
  port                          = 443 # Port for api.cookson.pro
}

# 6. Create a backend service for the /api route pointing to the external API
resource "google_compute_backend_service" "api_backend_service" {
  project               = data.google_project.cookson_pro.project_id
  name                  = "bs-api-cookson-pro-external"
  description           = "Backend service for /api route to external api.cookson.pro"
  protocol              = "HTTPS" # Protocol LB uses to connect to api.cookson.pro
  port_name             = "https"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  timeout_sec           = 30
  enable_cdn            = false # Typically false for dynamic API backends

  backend {
    group = google_compute_global_network_endpoint_group.api_neg.id
  }

  # Optional: If api.cookson.pro requires a specific Host header
  # custom_request_headers = ["Host: api.cookson.pro"]

  # Consider adding a health check for production
  # health_checks = [google_compute_health_check.api_health_check.id]
}

# 7. Create a URL map to route requests
resource "google_compute_url_map" "cdn_url_map" {
  project         = data.google_project.cookson_pro.project_id
  name            = "url-map-www-gcp-cookson-pro"
  default_service = google_compute_backend_bucket.static_site_backend_bucket.id

  host_rule {
    hosts        = [var.site_domain]
    path_matcher = "api-and-default-matcher"
  }

  path_matcher {
    name            = "api-and-default-matcher"
    default_service = google_compute_backend_bucket.static_site_backend_bucket.id # Default for www.gcp.cookson.pro

    path_rule {
      paths   = ["/api", "/api/*"]
      service = google_compute_backend_service.api_backend_service.id
    }
  }
}

# 8. Create a target HTTPS proxy to use the SSL certificate and URL map
resource "google_compute_target_https_proxy" "https_proxy" {
  project         = data.google_project.cookson_pro.project_id
  name            = "https-proxy-www-gcp-cookson-pro"
  url_map         = google_compute_url_map.cdn_url_map.id
  certificate_map = "//certificatemanager.googleapis.com/${google_certificate_manager_certificate_map.cookson_pro.id}"
}

# 9. Create a global forwarding rule for HTTPS traffic
resource "google_compute_global_forwarding_rule" "https_forwarding_rule" {
  project               = data.google_project.cookson_pro.project_id
  name                  = "https-fwd-rule-www-gcp-cookson-pro"
  target                = google_compute_target_https_proxy.https_proxy.id
  ip_address            = google_compute_global_address.cdn_ip.address
  port_range            = "443"
  load_balancing_scheme = "EXTERNAL_MANAGED"
}


# --- HTTP to HTTPS Redirect (Recommended) ---

resource "google_compute_url_map" "http_redirect_url_map" {
  project = data.google_project.cookson_pro.project_id
  name    = "url-map-http-redirect-www-gcp"
  default_url_redirect {
    https_redirect         = true
    strip_query            = false
    redirect_response_code = "MOVED_PERMANENTLY_DEFAULT" # 301
  }
}

resource "google_compute_target_http_proxy" "http_proxy_redirect" {
  project = data.google_project.cookson_pro.project_id
  name    = "http-proxy-redirect-www-gcp"
  url_map = google_compute_url_map.http_redirect_url_map.id
}

resource "google_compute_global_forwarding_rule" "http_forwarding_rule" {
  project               = data.google_project.cookson_pro.project_id
  name                  = "http-fwd-rule-www-gcp"
  target                = google_compute_target_http_proxy.http_proxy_redirect.id
  ip_address            = google_compute_global_address.cdn_ip.address
  port_range            = "80"
  load_balancing_scheme = "EXTERNAL_MANAGED"
}

# resource "google_storage_bucket_object" "default_index_html" {
#   name   = "index.html"
#   source = "./static/index.html"
#   bucket = google_storage_bucket.static_site_bucket.name
# }

# resource "google_storage_bucket_object" "default_404_html" {
#   name   = "404.html"
#   source = "./static/404.html"
#   bucket = google_storage_bucket.static_site_bucket.name
# }


resource "google_storage_bucket_object" "all_static" {
  for_each       = fileset("./static", "*")
  name           = each.value
  bucket         = google_storage_bucket.static_site_bucket.name
  source         = "./static/${each.value}"
  content_type   = "text/html"
  cache_control  = "public, max-age=1200"
  detect_md5hash = true
}


# Output the IP address of the load balancer
output "cdn_ip_address" {
  description = "The global static IP address of the CDN load balancer."
  value       = google_compute_global_address.cdn_ip.address
}

# Output the certificate name (useful for verification)
output "cdn_certificate_name" {
  description = "The name of the managed SSL certificate."
  value       = google_certificate_manager_certificate.cookson_pro.name
}

# Output the certificate status (useful for verification)
output "cdn_certificate_status" {
  description = "The status of the managed SSL certificate."
  value       = google_certificate_manager_certificate.cookson_pro.managed
}
