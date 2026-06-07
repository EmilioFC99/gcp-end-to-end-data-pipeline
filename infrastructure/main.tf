terraform {
  required_version = ">= 1.5.0"
  
  backend "gcs" {
    bucket = "tf-state-emilio-flores-portfolio"
    # This prefix guarantees we only use and edit this project's infrastructure
    prefix = "reverse-etl-pipeline/state"
  }

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region

  # These labels are enforced globally for this project
  default_labels = {
    environment = var.environment
    workload    = "reverse-etl-pipeline"
    managed-by  = "terraform"
    owner       = "emilio-flores"
  }
}