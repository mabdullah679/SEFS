# MOTHER: one apply deploys everything. Each block is a child; update one with
#   terraform apply -target=module.<child>
# Component -> child map: docs/COMPONENTS.md

module "network" {
  source = "./modules/network"

  name       = var.name
  vpc_cidr   = var.vpc_cidr
  az_count   = var.az_count
  nat_per_az = var.nat_per_az
}

module "security" {
  source = "./modules/security"

  name   = var.name
  vpc_id = module.network.vpc_id
}

module "efs" {
  source = "./modules/efs"

  name                  = var.name
  private_subnets_by_az = module.network.private_subnets_by_az
  efs_security_group_id = module.security.efs_security_group_id
  kms_key_arn           = var.kms_key_arn
  transition_to_ia      = var.transition_to_ia
  shared_root_path      = var.shared_root_path
  posix_gid             = var.posix_gid
  writer_uid            = var.writer_uid
  reader_uid            = var.reader_uid
  writer_role_arn       = module.apps.writer_task_role_arn
  reader_role_arn       = module.apps.reader_task_role_arn
}

module "backup" {
  source = "./modules/backup"

  name           = var.name
  resource_arns  = [module.efs.file_system_arn]
  retention_days = var.backup_retention_days
  kms_key_arn    = var.kms_key_arn
}

module "images" {
  source = "./modules/images"

  name           = var.name
  writer_context = abspath("${path.root}/apps/writer-python")
  reader_context = abspath("${path.root}/apps/reader-springboot")
}

module "apps" {
  source = "./modules/apps"

  name                    = var.name
  region                  = var.region
  private_subnet_ids      = module.network.private_subnet_ids
  apps_security_group_id  = module.security.apps_security_group_id
  file_system_id          = module.efs.file_system_id
  file_system_arn         = module.efs.file_system_arn
  writer_access_point_id  = module.efs.writer_access_point_id
  writer_access_point_arn = module.efs.writer_access_point_arn
  reader_access_point_id  = module.efs.reader_access_point_id
  reader_access_point_arn = module.efs.reader_access_point_arn
  efs_dependency_ids      = concat([module.efs.file_system_policy_id], values(module.efs.mount_target_ids))
  writer_image            = module.images.writer_image
  reader_image            = module.images.reader_image
  container_mount_path    = var.container_mount_path
  writer_interval_seconds = var.writer_interval_seconds
  reader_poll_seconds     = var.reader_poll_seconds
}
