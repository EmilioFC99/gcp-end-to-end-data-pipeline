module "gcs" {
  source      = "../../modules/cloud-storage"
  environment = "dev"
  project_id  = "emilio-flores-portafolio-dev"
}