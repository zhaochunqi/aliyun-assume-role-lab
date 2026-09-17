data "alicloud_account" "current" {}

locals {
  account_id = data.alicloud_account.current.id
  prefix     = var.name_prefix

  # 调用者的 ARN —— 作为角色信任策略的 Principal，钉到具体用户而不是整个账号
  caller_arn = "acs:ram::${local.account_id}:user/${alicloud_ram_user.caller.name}"
}

# ---------------------------------------------------------------------------
# 1) 调用者：一个只有「扮演下面那一个角色」权限的 RAM 用户，ACR 权限为零
# ---------------------------------------------------------------------------
resource "alicloud_ram_user" "caller" {
  name     = "${local.prefix}-caller"
  comments = "实验器材：阴性对照用的调用者，除 AssumeRole 外无任何权限。用完即删。"
  force    = true
}

resource "alicloud_ram_access_key" "caller" {
  user_name = alicloud_ram_user.caller.name
}

# 调用者侧策略：只授权扮演这一个角色 ARN，不做任何通配
resource "alicloud_ram_policy" "caller_assume" {
  policy_name = "${local.prefix}-caller-assume"
  description = "只允许扮演 ${local.prefix}-acr-reader 这一个角色"

  policy_document = jsonencode({
    Version = "1"
    Statement = [{
      Effect   = "Allow"
      Action   = ["sts:AssumeRole"]
      Resource = [alicloud_ram_role.acr_reader.arn]
    }]
  })
}

resource "alicloud_ram_user_policy_attachment" "caller_assume" {
  policy_name = alicloud_ram_policy.caller_assume.policy_name
  policy_type = alicloud_ram_policy.caller_assume.type
  user_name   = alicloud_ram_user.caller.name
}

# ---------------------------------------------------------------------------
# 2) 被扮演的角色：信任策略钉到 caller 用户 ARN + sts:ExternalId 条件
# ---------------------------------------------------------------------------
resource "alicloud_ram_role" "acr_reader" {
  role_name   = "${local.prefix}-acr-reader"
  description = "实验器材：带 ACR 拉取权限、只信任 caller 用户且必须带 ExternalId。"

  # 3600 秒：让 P6 的「899 报错 / 900 成功」边界可测，同时把实验窗口压到最小
  max_session_duration = 3600

  assume_role_policy_document = jsonencode({
    Version = "1"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { RAM = [local.caller_arn] }
      Condition = {
        StringEquals = { "sts:ExternalId" = var.external_id }
      }
    }]
  })

  force = true
}

# 角色侧策略：ACR 拉取
resource "alicloud_ram_policy" "acr_pull" {
  policy_name = "${local.prefix}-acr-pull"
  description = "ACR 拉取所需动作；cr:GetAuthorizationToken 的资源类型为「全部资源」，不支持资源级授权"

  policy_document = jsonencode({
    Version = "1"
    Statement = [{
      Effect = "Allow"
      Action = [
        "cr:GetAuthorizationToken",
        "cr:PullRepository",
      ]
      Resource = ["*"]
    }]
  })
}

resource "alicloud_ram_role_policy_attachment" "acr_pull" {
  policy_name = alicloud_ram_policy.acr_pull.policy_name
  policy_type = alicloud_ram_policy.acr_pull.type
  role_name   = alicloud_ram_role.acr_reader.role_name
}
