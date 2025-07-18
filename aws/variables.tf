variable "hosted_zone_domain" {
  type = string
}
variable "domain_name" {
  type = string
}
variable "api_origin_domain" {
  type = string
}
variable "content_s3_bucket_name" {
  type = string
}
variable "log_bucket_name" {
  type = string
}
variable "api_version" {
  description = "The version of the API to deploy, update when the API code for cookson_pro_api changes"
  type        = string
  default     = "v1.0.0"
}
