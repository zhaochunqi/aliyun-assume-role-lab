variable "region" {
  description = "RAM 是全局资源，但 provider 与 aliyun CLI 都需要一个 region；ACR 实例也按这个 region 查。"
  type        = string
  default     = "cn-hangzhou"
}

variable "name_prefix" {
  description = "所有实验对象的名字前缀，便于辨认与清理。"
  type        = string
  default     = "lab-assume-role"
}

variable "external_id" {
  description = "信任策略里的 sts:ExternalId 条件值，同时用于 AssumeRole 的 --ExternalId 参数。P7 会故意不带它。"
  type        = string
  default     = "lab-external-id-2026"
}
