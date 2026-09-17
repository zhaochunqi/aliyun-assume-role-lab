output "account_id" {
  description = "被实验账号的 ID，拼 ARN 用"
  value       = local.account_id
}

output "caller_user_name" {
  value = alicloud_ram_user.caller.name
}

output "caller_access_key_id" {
  description = "调用者 AK（实验器材，用完 destroy）"
  value       = alicloud_ram_access_key.caller.id
  sensitive   = true
}

output "caller_access_key_secret" {
  description = "调用者 SK（实验器材，用完 destroy）"
  value       = alicloud_ram_access_key.caller.secret
  sensitive   = true
}

output "role_name" {
  value = alicloud_ram_role.read_only.role_name
}

output "role_arn" {
  description = "AssumeRole 的 --RoleArn"
  value       = alicloud_ram_role.read_only.arn
}

output "external_id" {
  description = "AssumeRole 的 --ExternalId"
  value       = var.external_id
}

output "region" {
  value = var.region
}

output "probe_hint" {
  description = "跑探针的最短路径"
  value       = "./scripts/probe.sh   # 或按 README 第五节逐条手跑"
}
