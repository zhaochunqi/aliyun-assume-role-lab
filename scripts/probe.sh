#!/usr/bin/env bash
#
# 探针：验证「assume role 换成的是角色权限，不是调用者权限的叠加」
#
# ⚠️ 编写环境里没有 aliyun CLI、也没有测试账号，所以本脚本**未实测**。
#    命令、参数名、环境变量名均按官方文档核对（链接见 README 第八节），
#    但错误措辞匹配用的是关键字，CLI 版本不同可能略有差异。
#    首次运行请对照 README 第五节的预期输出逐条看。
#
# 用法：
#   ./scripts/probe.sh
#   ALIYUN_CLI=/path/to/aliyun ./scripts/probe.sh
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CLI="${ALIYUN_CLI:-aliyun}"

die() { printf '错误：%s\n' "$*" >&2; exit 2; }
sec() { printf '\n== %s\n' "$1"; }
ok()  { printf '  [PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
bad() {
  printf '  [FAIL] %s\n' "$1"
  [ -n "${2:-}" ] && printf '         %s\n' "$(head -c 400 <<<"$2" | tr '\n' ' ')"
  FAIL=$((FAIL + 1))
}
skip() { printf '  [SKIP] %s\n' "$1"; SKIP=$((SKIP + 1)); }

PASS=0
FAIL=0
SKIP=0

command -v "$CLI" >/dev/null 2>&1 || die "找不到 aliyun CLI（可用 ALIYUN_CLI 指定路径）。安装方式见 README 前置条件。"
command -v jq >/dev/null 2>&1 || die "找不到 jq（本脚本用它解析 CLI 返回的 JSON）。"
command -v terraform >/dev/null 2>&1 || die "找不到 terraform。"

tfo() { terraform output -raw "$1" 2>/dev/null; }

REGION="$(tfo region)"
ROLE_ARN="$(tfo role_arn)"
EXTERNAL_ID="$(tfo external_id)"
ACR="$(tfo acr_instance_id)"
BASE_AK="$(tfo caller_access_key_id)"
BASE_SK="$(tfo caller_access_key_secret)"

[ -n "$ROLE_ARN" ] || die "取不到 terraform output role_arn，请先 terraform apply。"
[ -n "$BASE_AK" ] || die "取不到调用者 AK，请先 terraform apply。"

printf 'region      = %s\nrole_arn    = %s\nexternal_id = %s\nacr         = %s\n' \
  "$REGION" "$ROLE_ARN" "$EXTERNAL_ID" "${ACR:-（未设置，P1/P4/P5 将跳过）}"

# --- 凭证切换 ---------------------------------------------------------------
# IGNORE_PROFILE 不能省：否则本机 ~/.aliyun/config.json 的默认 profile 可能
# 覆盖掉这里设的 AK，探针会在错误的身份上跑，结论直接作废。
use_caller() {
  export ALIBABA_CLOUD_IGNORE_PROFILE=TRUE
  export ALIBABA_CLOUD_ACCESS_KEY_ID="$BASE_AK"
  export ALIBABA_CLOUD_ACCESS_KEY_SECRET="$BASE_SK"
  unset ALIBABA_CLOUD_SECURITY_TOKEN
}

use_session() { # $1=AK $2=SK $3=SecurityToken
  export ALIBABA_CLOUD_IGNORE_PROFILE=TRUE
  export ALIBABA_CLOUD_ACCESS_KEY_ID="$1"
  export ALIBABA_CLOUD_ACCESS_KEY_SECRET="$2"
  export ALIBABA_CLOUD_SECURITY_TOKEN="$3"
}

# $1=DurationSeconds，其余为额外参数；输出 CLI 的原始返回（含报错）
assume() {
  local dur="$1"
  shift
  use_caller
  "$CLI" sts AssumeRole \
    --RoleArn "$ROLE_ARN" \
    --RoleSessionName "lab-$(date +%s)-${RANDOM}" \
    --DurationSeconds "$dur" \
    --region "$REGION" "$@" 2>&1
}

acr_token() {
  "$CLI" cr GetAuthorizationToken \
    --InstanceId "$ACR" --ExpiresInHours 1 --region "$REGION" 2>&1
}

session_ready() {
  jq -e '.Credentials.SecurityToken' >/dev/null 2>&1 <<<"$1"
}

load_session() {
  use_session \
    "$(jq -r '.Credentials.AccessKeyId' <<<"$1")" \
    "$(jq -r '.Credentials.AccessKeySecret' <<<"$1")" \
    "$(jq -r '.Credentials.SecurityToken' <<<"$1")"
}

# --- P1 阴性对照 ------------------------------------------------------------
sec "P1 阴性对照：调用者直接向 ACR 要凭证（预期被拒）"
if [ -z "$ACR" ]; then
  skip "未设置 acr_instance_id"
else
  use_caller
  RES="$(acr_token)"
  if grep -qiE 'NoPermission|Forbidden|AccessDenied|not authorized' <<<"$RES"; then
    ok "被拒，阴性对照成立"
  else
    bad "未被拒——对照不成立，后面 P4 的成功无法归因到『权限来自角色』" "$RES"
  fi
fi

# --- P2 扮演 ----------------------------------------------------------------
sec "P2 扮演角色（带 ExternalId，900 秒）"
ASSUME_OUT="$(assume 900 --ExternalId "$EXTERNAL_ID")"
if session_ready "$ASSUME_OUT"; then
  SESS_EXPIRATION="$(jq -r '.Credentials.Expiration' <<<"$ASSUME_OUT")"
  ok "扮演成功：$(jq -r '.AssumedRoleUser.Arn' <<<"$ASSUME_OUT")（Expiration=$SESS_EXPIRATION）"
  load_session "$ASSUME_OUT"
else
  bad "扮演失败" "$ASSUME_OUT"
  ASSUME_OUT=""
fi

# --- P3 身份 ----------------------------------------------------------------
sec "P3 验身份：IdentityType 应为 AssumedRoleUser"
if [ -z "$ASSUME_OUT" ]; then
  skip "依赖 P2"
else
  GCI="$("$CLI" sts GetCallerIdentity --region "$REGION" 2>&1)"
  IT="$(jq -r '.IdentityType // empty' <<<"$GCI" 2>/dev/null)"
  ARN="$(jq -r '.Arn // empty' <<<"$GCI" 2>/dev/null)"
  if [ "$IT" = "AssumedRoleUser" ]; then
    ok "IdentityType=AssumedRoleUser，Arn=$ARN"
  else
    bad "IdentityType=${IT:-（取不到）}——环境变量没替换成功？" "$GCI"
  fi
fi

# --- P4 权限 ----------------------------------------------------------------
sec "P4 用会话凭证向 ACR 要凭证（预期成功）"
if [ -z "$ACR" ] || [ -z "$ASSUME_OUT" ]; then
  skip "依赖 acr_instance_id 与 P2"
else
  RES="$(acr_token)"
  if [ -n "$(jq -r '.AuthorizationToken // empty' <<<"$RES" 2>/dev/null)" ]; then
    ok "拿到凭证：TempUsername=$(jq -r '.TempUsername' <<<"$RES")  ExpireTime=$(jq -r '.ExpireTime' <<<"$RES")"
    printf '         对比：会话 Expiration=%s（ExpireTime 应取两者较小值）\n' "${SESS_EXPIRATION:-?}"
  else
    bad "仍然失败" "$RES"
  fi
fi

# --- P5 交集语义 ------------------------------------------------------------
sec "P5 交集语义：会话策略只给 cr:ListRepository，再要 ACR 凭证应被拒"
SESSION_POLICY='{"Version":"1","Statement":[{"Effect":"Allow","Action":["cr:ListRepository"],"Resource":["*"]}]}'
if [ -z "$ACR" ]; then
  skip "未设置 acr_instance_id"
else
  P5_OUT="$(assume 900 --ExternalId "$EXTERNAL_ID" --Policy "$SESSION_POLICY")"
  if session_ready "$P5_OUT"; then
    load_session "$P5_OUT"
    RES="$(acr_token)"
    if grep -qiE 'NoPermission|Forbidden|AccessDenied|not authorized' <<<"$RES"; then
      ok "被拒（角色允许 cr:*，但会话策略没给 GetAuthorizationToken）"
    else
      bad "未被拒——交集语义不成立" "$RES"
    fi
  else
    skip "带会话策略的扮演本身没成功，P5 未覆盖：$(head -c 200 <<<"$P5_OUT" | tr '\n' ' ')"
  fi
fi

# --- P6 边界 ----------------------------------------------------------------
sec "P6 DurationSeconds 边界：899 应报错，900 应成功"
R899="$(assume 899 --ExternalId "$EXTERNAL_ID")"
if session_ready "$R899"; then
  bad "899 竟然成功了——边界与官方文档（最小 900）不符" "$R899"
else
  if grep -qiE 'DurationSeconds|InvalidParameter' <<<"$R899"; then
    ok "899 被拒：$(head -c 160 <<<"$R899" | tr '\n' ' ')"
  else
    bad "899 失败，但错误不像边界问题（值得看一眼）" "$R899"
  fi
fi

R900="$(assume 900 --ExternalId "$EXTERNAL_ID")"
if session_ready "$R900"; then
  ok "900 成功"
else
  bad "900 竟然失败了" "$R900"
fi

# --- P7 条件键 --------------------------------------------------------------
sec "P7 信任策略条件键：不带 ExternalId 扮演应被拒"
R_NOEXT="$(assume 900)"
if session_ready "$R_NOEXT"; then
  bad "不带 ExternalId 也扮演成功——信任策略里的 sts:ExternalId 没生效" "$R_NOEXT"
else
  if grep -qiE 'NoPermission|Forbidden|AccessDenied|not authorized' <<<"$R_NOEXT"; then
    ok "被拒，条件键生效"
  else
    bad "失败原因不像条件键不匹配（值得看一眼）" "$R_NOEXT"
  fi
fi

# --- 汇总 -------------------------------------------------------------------
printf '\n===== 汇总：PASS=%d FAIL=%d SKIP=%d =====\n' "$PASS" "$FAIL" "$SKIP"
if [ "$FAIL" -gt 0 ]; then
  printf '有失败项。分诊表见 README 第六节。\n'
  exit 1
fi
printf '全部通过。别忘了 terraform destroy 并人工确认 RAM 用户与 AK 已删。\n'
