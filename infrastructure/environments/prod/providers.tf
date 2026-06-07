terraform {
  required_version = ">= 1.5.0"
  
  backend "gcs" {
    bucket = "tf-state-emilio-flores-portfolio"
    prefix = "reverse-etl-pipeline/state/prod" # CRITICAL: Prod State Isolation
  }

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

provider "google" {
  project = "emilio-flores-portfolio-prod"
  region  = "us-central1"

  default_labels = {
    environment = "prod"
    workload    = "reverse-etl-pipeline"
    managed-by  = "terraform"
    owner       = "emilio-flores"
  }
}