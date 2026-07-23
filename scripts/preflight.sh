#!/usr/bin/env bash
# preflight.sh aka the vibe check before the party.
# makes sure your tools exist, your .env isn't a lie, aws + cloudflare still
# love you, and the account has enough quota for this whole circus.
# exits non-zero on anything actually broken. warnings are just gossip.

set -euo pipefail

# -----------------------------------------------------------------------------
# helpers. tiny and dramatic, like all good helpers.
# -----------------------------------------------------------------------------
RED=$'\033[0;31m'; GRN=$'\033[0;32m'; YLW=$'\033[1;33m'; BLU=$'\033[0;34m'; CLR=$'\033[0m'
PASS=0; FAIL=0; WARN=0
ok()    { printf "  ${GRN}PASS${CLR}  %s\n" "$*"; PASS=$((PASS+1)); }
bad()   { printf "  ${RED}FAIL${CLR}  %s\n" "$*"; FAIL=$((FAIL+1)); }
warn()  { printf "  ${YLW}WARN${CLR}  %s\n" "$*"; WARN=$((WARN+1)); }
hdr()   { printf "\n${BLU}==> %s${CLR}\n" "$*"; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# minimum versions. yes the compare logic below is over-engineered for a
# school project. no, i will not apologize. version numbers are liars.
declare -A MINVER=(
  [terraform]="1.6.0"
  [ansible]="2.15.0"
  [kubectl]="1.28.0"
  [helm]="3.13.0"
  [aws]="2.13.0"
  [jq]="1.6"
)

verlte() {
  # returns 0 if $1 <= $2. sorts versions the way god intended: with sort -V.
  local a b
  a="$(echo "$1" | tr -dc '0-9.')"
  b="$(echo "$2" | tr -dc '0-9.')"
  printf '%s\n%s\n' "$a" "$b" | sort -V -C
}

bin_version() {
  case "$1" in
    terraform) terraform version 2>/dev/null | head -1 | awk '{print $2}' | tr -d 'v' ;;
    ansible)   ansible --version 2>/dev/null | head -1 | awk '{print $NF}' | tr -d ']' ;;
    kubectl)   kubectl version --client -o json 2>/dev/null | jq -r '.clientVersion.gitVersion' | tr -d 'v' 2>/dev/null || kubectl version --client 2>/dev/null | head -1 | awk '{print $3}' | tr -d 'v' ;;
    helm)      helm version --short 2>/dev/null | awk -F+ '{print $1}' | tr -d 'v' ;;
    aws)       aws --version 2>&1 | awk '{print $1}' | awk -F/ '{print $2}' ;;
    jq)        jq --version 2>/dev/null | awk -F- '{print $2}' ;;
    session-manager-plugin) session-manager-plugin --version 2>/dev/null ;;
    *) "$1" --version 2>/dev/null | head -1 ;;
  esac
}

# -----------------------------------------------------------------------------
# 1. required CLIs. every missing tool is a personal insult.
# -----------------------------------------------------------------------------
hdr "Required CLI tools"
for tool in terraform ansible kubectl helm aws jq; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    bad "$tool not installed"
    continue
  fi
  v="$(bin_version "$tool")"
  if [[ -z "$v" ]]; then
    warn "$tool installed (version unknown)"
    continue
  fi
  if verlte "${MINVER[$tool]}" "$v"; then
    ok "$tool $v (>= ${MINVER[$tool]})"
  else
    bad "$tool $v (< ${MINVER[$tool]} required)"
  fi
done

# session-manager-plugin. no version check, we just need it to exist so SSM
# doesn't pretend it can't reach the nodes.
if command -v session-manager-plugin >/dev/null 2>&1; then
  ok "session-manager-plugin installed"
else
  bad "session-manager-plugin missing — install: https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html"
fi

# -----------------------------------------------------------------------------
# 2. .env exists and every key we can't live without is filled in
# -----------------------------------------------------------------------------
hdr ".env / configuration"
if [[ ! -f "$ROOT/.env" ]]; then
  bad ".env not found. Copy .env.example to .env and fill it in."
else
  ok ".env present"
  # shellcheck disable=SC1091
  set -a; . "$ROOT/.env"; set +a

  REQUIRED_CORE=(OWNER AWS_REGION NAME_PREFIX DOMAIN FRONTEND_URL CLOUDFLARE_API_TOKEN CLOUDFLARE_ZONE GITHUB_OWNER GITHUB_REPO)
  for k in "${REQUIRED_CORE[@]}"; do
    if [[ -z "${!k:-}" ]]; then
      bad "missing required key: $k"
    else
      ok "$k set"
    fi
  done

  # region sanity: this whole repo assumes ap-southeast-1. change it and
  # you're on your own, i'm not debugging another region's quirks.
  if [[ "${AWS_REGION:-}" != "ap-southeast-1" ]]; then
    warn "AWS_REGION=${AWS_REGION:-} — this stack is built for ap-southeast-1; override at your own risk"
  fi

  # NAME_PREFIX shape. lowercase, short, no funny business. like a username.
  if [[ -n "${NAME_PREFIX:-}" && ! "$NAME_PREFIX" =~ ^[a-z][a-z0-9-]{2,15}$ ]]; then
    bad "NAME_PREFIX must be lowercase alphanumeric/dash, 3-16 chars, start with a letter (got: $NAME_PREFIX)"
  fi
fi

# -----------------------------------------------------------------------------
# 3. aws identity. who are we even, according to amazon.
# -----------------------------------------------------------------------------
hdr "AWS identity"
if [[ -n "${AWS_PROFILE:-}" ]]; then export AWS_PROFILE; fi
if ID_JSON="$(aws sts get-caller-identity --output json 2>/dev/null)"; then
  ACCOUNT="$(echo "$ID_JSON" | jq -r .Account)"
  ARN="$(echo "$ID_JSON" | jq -r .Arn)"
  ok "AWS auth OK (account=${ACCOUNT}, arn=${ARN})"
  export _CWTA_AWS_ACCOUNT="$ACCOUNT"
else
  bad "aws sts get-caller-identity failed — check AWS_PROFILE / credentials"
fi

# -----------------------------------------------------------------------------
# 4. cloudflare token. does cloudflare even know this token exists.
# -----------------------------------------------------------------------------
hdr "Cloudflare API token"
if [[ -n "${CLOUDFLARE_API_TOKEN:-}" ]]; then
  CF_RESP="$(curl -s -X GET "https://api.cloudflare.com/client/v4/user/tokens/verify" \
    -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
    -H "Content-Type: application/json" || true)"
  CF_OK="$(echo "$CF_RESP" | jq -r '.success // false')"
  if [[ "$CF_OK" == "true" ]]; then
    ok "Cloudflare token valid"
    # make sure the labmgm.org zone actually shows up for this token
    CF_ZONE_RESP="$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=${CLOUDFLARE_ZONE}" \
      -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" || true)"
    CF_ZONE_COUNT="$(echo "$CF_ZONE_RESP" | jq -r '.result | length // 0')"
    if [[ "$CF_ZONE_COUNT" -ge 1 ]]; then
      ok "Cloudflare zone '${CLOUDFLARE_ZONE}' visible to token"
    else
      bad "Cloudflare zone '${CLOUDFLARE_ZONE}' not visible to this token (need Zone.Zone:Read + Zone.DNS:Edit)"
    fi
  else
    bad "Cloudflare token verify failed: $(echo "$CF_RESP" | jq -r '.errors // .' 2>/dev/null || echo "$CF_RESP")"
  fi
else
  bad "CLOUDFLARE_API_TOKEN not set"
fi

# -----------------------------------------------------------------------------
# 5. service quotas. because aws WILL let you start and then ghost you
#    halfway through when you hit a limit. we check first like adults.
# -----------------------------------------------------------------------------
hdr "AWS Service Quotas (region=${AWS_REGION:-ap-southeast-1})"
REGION="${AWS_REGION:-ap-southeast-1}"

quota_value() {
  # $1 = service-code, $2 = quota-code; echoes integer value or empty
  aws service-quotas get-service-quota \
    --region "$REGION" \
    --service-code "$1" --quota-code "$2" \
    --query 'Quota.Value' --output text 2>/dev/null || true
}

# elastic IPs. two NAT gateways want two EIPs, minimum. they're needy.
EIP_Q="$(quota_value ec2 L-0263D0A3)"
if [[ -n "$EIP_Q" && "${EIP_Q%.*}" -ge 5 ]]; then
  ok "Elastic IPs per region: ${EIP_Q%.*} (need >= 5)"
else
  warn "Elastic IPs quota: ${EIP_Q:-unknown} (need >= 5; raise via Service Quotas if low)"
fi

# standard on-demand vCPUs. t3 nodes are cheap but they still count.
VCPU_Q="$(quota_value ec2 L-1216C47A)"
if [[ -n "$VCPU_Q" && "${VCPU_Q%.*}" -ge 16 ]]; then
  ok "Standard on-demand vCPUs: ${VCPU_Q%.*} (need >= 16)"
else
  warn "Standard on-demand vCPU quota: ${VCPU_Q:-unknown} (need >= 16)"
fi

# EKS clusters per region. we only want one, but amazon keeps score.
EKS_Q="$(quota_value eks L-1194D53C)"
if [[ -n "$EKS_Q" && "${EKS_Q%.*}" -ge 1 ]]; then
  ok "EKS clusters per region: ${EKS_Q%.*}"
else
  warn "EKS cluster quota check inconclusive (${EKS_Q:-unknown}) — proceeding"
fi

# -----------------------------------------------------------------------------
# summary. the report card.
# -----------------------------------------------------------------------------
hdr "Preflight summary"
printf "  passed: %d  warned: %d  failed: %d\n" "$PASS" "$WARN" "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
  printf "${RED}Preflight FAILED. Fix the issues above and re-run.${CLR}\n"
  exit 1
fi
printf "${GRN}Preflight PASS.${CLR}\n"
