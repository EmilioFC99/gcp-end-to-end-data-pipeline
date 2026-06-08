variable "environment" {
  type        = string
  description = "The target deployment environment footprint (e.g., dev, prod)."
  
  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "The environment variable must be strictly 'dev' or 'prod'."
  }
}

variable "project_id" {
  type        = string
  description = "The target GCP Project ID where the bucket will be provisioned."
}