resource "google_storage_bucket" "raw_zone" {
  name          = "reverse-etl-raw-${var.environment}"
  location      = "us-central1"
  project       = var.project_id
  
  # Allow Terraform to easily destroy the dev bucket, but protect the prod bucket
  force_destroy = var.environment == "dev" ? true : false
  
  uniform_bucket_level_access = true
}