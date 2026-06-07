variable "environment" {}
variable "project_id" {}

resource "google_storage_bucket" "raw_zone" {
  name          = "reverse-etl-raw-${var.environment}"
  location      = "us-central1"
  force_destroy = var.environment == "dev" ? true : false
  
  uniform_bucket_level_access = true
}