terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "6.39.0"
    }
  }
}

provider "google" {
  region  = "us-east4-c"
  project = "cookson-pro-gcp"
}