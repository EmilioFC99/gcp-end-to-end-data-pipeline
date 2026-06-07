variable "project_id" {
  type        = string
  description = "The target GCP Project ID (the shared spoke environment)"
}

variable "environment" {
  type        = string
  description = "The deployment environment footprint (dev or prod)"
}

variable "region" {
  type        = string
  description = "The primary compute and storage region"
  default     = "us-central1"
}

variable "resource_prefix" {
  type        = string
  description = "A unique prefix for this pipeline to prevent naming collisions in the shared projects"
  default     = "reverse-etl"
}