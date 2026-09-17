data "alicloud_account" "current" {}

locals {
  account_id = data.alicloud_account.current.id
  prefix     = var.name_prefix

  # 调用者的 ARN —— 作为角色信任策略的 Principal，钉到具体用户而不是整个账号
  caller_arn = "acs:ram::${local.account_id}:user/${alicloud_ram_user.caller.name}"
}

# ---------------------------------------------------------------------------
# 1) 调用者：一个只有「扮演下面那一个角色」权限的 RAM 用户，靶子动作权限为零
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
  description = "只允许扮演 ${local.prefix}-read-only 这一个角色"

  policy_document = jsonencode({
    Version = "1"
    Statement = [{
      Effect   = "Allow"
      Action   = ["sts:AssumeRole"]
      Resource = [alicloud_ram_role.read_only.arn]
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
resource "alicloud_ram_role" "read_only" {
  role_name   = "${local.prefix}-read-only"
  description = "实验器材：带一个只读动作、只信任 caller 用户且必须带 ExternalId。"

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

# 角色侧策略：探针靶子动作。
#
# 最初想把靶子设成 ACR 企业版 cr:GetAuthorizationToken（生产里「跨账号拉镜像」
# 的真实场景），但 ACR 企业版实例只能包年包月，基础版 ¥564/月起
# （用 bssopenapi GetSubscriptionPrice 在 cn-hangzhou 实查），
# 为一个只验证权限语义的实验不值得。改用 ram:ListUsers：
# 免费、不需要任何真实资源，语义完全一样——「角色有、调用者没有、会话策略可收窄」。
#
# 想换回 ACR 时：把 Action 换成 ["cr:GetAuthorizationToken"]，
# 并把探针靶子指向一个真实企业版实例（cri-...，个人版 crpi-... 不行）。
resource "alicloud_ram_policy" "role_read" {
  policy_name = "${local.prefix}-role-read"
  description = "探针靶子：允许 ram:ListUsers。角色有、调用者没有，用来验证 assume role 的权限来源。"

  policy_document = jsonencode({
    Version = "1"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ram:ListUsers"]
      Resource = ["*"]
    }]
  })
}

resource "alicloud_ram_role_policy_attachment" "role_read" {
  policy_name = alicloud_ram_policy.role_read.policy_name
  policy_type = alicloud_ram_policy.role_read.type
  role_name   = alicloud_ram_role.read_only.role_name
}
