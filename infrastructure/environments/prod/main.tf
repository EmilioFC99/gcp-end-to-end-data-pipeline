module "gcs" {
  source      = "../../modules/cloud-storage"
  environment = "prod"
  project_id  = "emilio-flores-portafolio-prod"
}