terraform {
  required_version = ">= 1.5.0"
  
  backend "gcs" {
    bucket = "tf-state-emilio-flores-dev"
    prefix = "reverse-etl-pipeline/state/dev"
  }

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

provider "google" {
  project = "emilio-flores-portfolio-dev"
  region  = "us-central1"

  default_labels = {
    environment = "dev"
    workload    = "reverse-etl-pipeline"
    managed-by  = "terraform"
    owner       = "emilio-flores"
  }
}