locals {
  tags = merge(
    {
      ProjectName       = var.project
      ProjectRepository = var.repository
      Environment       = var.environment
      ManagedBy         = var.managed_by
      DeployedBy        = var.deployed_by
      AccountAlias      = var.account_alias
    },
    var.additional_tags
  )
}

output "tags" {
  description = "Merged tags for resource tagging"
  value       = local.tags
}
