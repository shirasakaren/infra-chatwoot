#!/usr/bin/env bash
# scripts/verify.sh aka the acceptance checklist nobody asked for but
# everybody has to pass. prints PASS/FAIL like a brutal report card and
# exits non-zero if a single thing is red. the demo lives or dies here.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

RED=$'\033[0;31m'; GRN=$'\033[0;32m'; YLW=$'\033[1;33m'; CLR=$'\033[0m'
PASS=0; FAIL=0

row() {
  local label="$1" status="$2" detail="${3:-}"
  if [[ "$status" == "PASS" ]]; then
    printf "  ${GRN}PASS${CLR}  %-45s  %s\n" "$label" "$detail"
    PASS=$((PASS+1))
  else
    printf "  ${RED}FAIL${CLR}  %-45s  %s\n" "$label" "$detail"
    FAIL=$((FAIL+1))
  fi
}

# shellcheck disable=SC1091
set -a; . "$ROOT/.env"; set +a
REGION="${AWS_REGION}"
CL="${NAME_PREFIX}"

pushd "$ROOT/terraform" >/dev/null

# 0. drift check. if plan says changes, something's been living a double life.
if PLAN_OUT="$(terraform plan -detailed-exitcode -input=false -lock=false 2>&1)"; then
  row "no terraform drift (plan = 0 changes)" PASS
elif [[ "$?" -eq 2 ]]; then
  row "no terraform drift (plan = 0 changes)" FAIL "plan reports pending changes"
else
  row "no terraform drift (plan = 0 changes)" FAIL "terraform plan failed"
fi

# 1. cluster ACTIVE and at least 2 nodes pretending to be useful
CL_STATUS="$(aws eks describe-cluster --region "$REGION" --name "$CL" --query 'cluster.status' --output text 2>/dev/null || echo ERR)"
[[ "$CL_STATUS" == "ACTIVE" ]] && row "EKS cluster ACTIVE" PASS "$CL_STATUS" || row "EKS cluster ACTIVE" FAIL "$CL_STATUS"

READY=$(kubectl get nodes --no-headers 2>/dev/null | awk '$2=="Ready"' | wc -l | tr -d ' ')
[[ "$READY" -ge 2 ]] && row "≥2 nodes Ready" PASS "$READY" || row "≥2 nodes Ready" FAIL "$READY"

# 2. LVM /data on every node. the disks must be in their final form.
ANY_BAD=0
NODE_IIDS="$(aws ec2 describe-instances --region "$REGION" \
  --filters "Name=tag:eks:cluster-name,Values=$CL" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].InstanceId' --output text)"
for IID in $NODE_IIDS; do
  CMD_ID="$(aws ssm send-command --region "$REGION" --document-name "AWS-RunShellScript" \
    --instance-ids "$IID" --parameters 'commands=["lvs --noheadings vg_data/lv_data && grep -q /data /etc/fstab && df -hT /data | tail -1"]' \
    --query 'Command.CommandId' --output text 2>/dev/null || true)"
  [[ -z "$CMD_ID" ]] && { ANY_BAD=1; continue; }
  for _ in $(seq 1 12); do
    sleep 4
    S="$(aws ssm get-command-invocation --region "$REGION" --command-id "$CMD_ID" --instance-id "$IID" \
      --query 'Status' --output text 2>/dev/null || echo Pending)"
    [[ "$S" == "Success" || "$S" == "Failed" ]] && break
  done
  [[ "$S" == "Success" ]] || ANY_BAD=1
done
[[ "$ANY_BAD" -eq 0 ]] && row "LVM vg_data/lv_data mounted on every worker" PASS || row "LVM vg_data/lv_data mounted on every worker" FAIL

# 3. RDS available AND multi-az. one healthy database, one secret twin.
RDS_ID="$(terraform output -raw rds_instance_id 2>/dev/null || true)"
RDS_INFO="$(aws rds describe-db-instances --region "$REGION" --db-instance-identifier "$RDS_ID" \
  --query 'DBInstances[0].[DBInstanceStatus,MultiAZ]' --output text 2>/dev/null || echo "ERR False")"
RDS_STATE="$(echo "$RDS_INFO" | awk '{print $1}')"
RDS_MAZ="$(echo "$RDS_INFO" | awk '{print $2}')"
[[ "$RDS_STATE" == "available" && ( "$RDS_MAZ" == "True" || "$RDS_MAZ" == "true" ) ]] \
  && row "RDS available + Multi-AZ" PASS "$RDS_INFO" \
  || row "RDS available + Multi-AZ" FAIL "$RDS_INFO"

# 4. redis: 2 nodes, auto-failover on. the queue must not ghost us mid-demo.
REDIS_INFO="$(aws elasticache describe-replication-groups --region "$REGION" \
  --replication-group-id "${NAME_PREFIX}-redis" \
  --query 'ReplicationGroups[0].[Status,AutomaticFailover,length(MemberClusters)]' --output text 2>/dev/null || echo "ERR disabled 0")"
R_STATE="$(echo "$REDIS_INFO" | awk '{print $1}')"
R_AF="$(echo "$REDIS_INFO" | awk '{print $2}')"
R_MEM="$(echo "$REDIS_INFO" | awk '{print $3}')"
[[ "$R_STATE" == "available" && "$R_AF" == "enabled" && "${R_MEM:-0}" -ge 2 ]] \
  && row "Redis available + auto-failover + ≥2 nodes" PASS "$REDIS_INFO" \
  || row "Redis available + auto-failover + ≥2 nodes" FAIL "$REDIS_INFO"

# 5. the storage squad: S3, ECR, the secret, the log group.
aws s3api head-bucket --bucket "$(terraform output -raw s3_bucket_name)" --region "$REGION" >/dev/null 2>&1 \
  && row "S3 ActiveStorage bucket exists" PASS \
  || row "S3 ActiveStorage bucket exists" FAIL

ECR_NAME="$(terraform output -raw ecr_repository_url | awk -F/ '{print $NF}')"
aws ecr describe-repositories --region "$REGION" --repository-names "$NAME_PREFIX/$ECR_NAME" >/dev/null 2>&1 \
  && row "ECR repository exists" PASS \
  || row "ECR repository exists" FAIL

aws secretsmanager describe-secret --region "$REGION" --secret-id "${NAME_PREFIX}/chatwoot" >/dev/null 2>&1 \
  && row "Secrets Manager chatwoot secret exists" PASS \
  || row "Secrets Manager chatwoot secret exists" FAIL

aws logs describe-log-groups --region "$REGION" --log-group-name-prefix "/aws/eks/${NAME_PREFIX}/application" \
  --query "logGroups[?logGroupName=='/aws/eks/${NAME_PREFIX}/application']" --output text | grep -q . \
  && row "CloudWatch app log group exists" PASS \
  || row "CloudWatch app log group exists" FAIL

# 6. ACM cert. issued or we're all just hoping really hard.
ACM_ARN="$(terraform output -raw acm_certificate_arn)"
ACM_STATUS="$(aws acm describe-certificate --region "$REGION" --certificate-arn "$ACM_ARN" --query 'Certificate.Status' --output text 2>/dev/null || echo ERR)"
[[ "$ACM_STATUS" == "ISSUED" ]] && row "ACM cert ISSUED" PASS || row "ACM cert ISSUED" FAIL "$ACM_STATUS"

# 7. add-ons running. if any of these are down, HPA and ALB start gaslighting us.
for ds in aws-load-balancer-controller cluster-autoscaler metrics-server; do
  R="$(kubectl -n kube-system get deploy "$ds" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
  [[ "${R:-0}" -ge 1 ]] && row "addon $ds Ready" PASS "$R" || row "addon $ds Ready" FAIL "$R"
done

ESO_R="$(kubectl -n external-secrets get deploy external-secrets -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
[[ "${ESO_R:-0}" -ge 1 ]] && row "external-secrets operator Ready" PASS || row "external-secrets operator Ready" FAIL

ES_READY="$(kubectl -n chatwoot get externalsecret chatwoot-env -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo Unknown)"
[[ "$ES_READY" == "True" ]] && row "ExternalSecret chatwoot-env synced" PASS || row "ExternalSecret chatwoot-env synced" FAIL "$ES_READY"

# 8. chatwoot replicas, HPA, PDB. the HA flex.
WEB="$(kubectl -n chatwoot get deploy -l app.kubernetes.io/component=web -o jsonpath='{range .items[*]}{.status.readyReplicas}{"\n"}{end}' 2>/dev/null | awk '{s+=$1} END{print s+0}')"
SK="$(kubectl -n chatwoot  get deploy -l app.kubernetes.io/component=sidekiq -o jsonpath='{range .items[*]}{.status.readyReplicas}{"\n"}{end}' 2>/dev/null | awk '{s+=$1} END{print s+0}')"
[[ "${WEB:-0}" -ge 2 ]] && row "chatwoot web ≥2 replicas Ready" PASS "$WEB" || row "chatwoot web ≥2 replicas Ready" FAIL "$WEB"
[[ "${SK:-0}"  -ge 2 ]] && row "chatwoot sidekiq ≥2 replicas Ready" PASS "$SK" || row "chatwoot sidekiq ≥2 replicas Ready" FAIL "$SK"

kubectl -n chatwoot get hpa --no-headers 2>/dev/null | grep -q . \
  && row "HPA present" PASS || row "HPA present" FAIL

kubectl -n chatwoot get pdb --no-headers 2>/dev/null | grep -q . \
  && row "PDB present" PASS || row "PDB present" FAIL

# 9. ingress + live HTTPS. the moment we've all been waiting for.
ALB_HOST="$(kubectl -n chatwoot get ingress -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
[[ -n "$ALB_HOST" ]] && row "ingress has ALB hostname" PASS "$ALB_HOST" || row "ingress has ALB hostname" FAIL

CURL_CODE="$(curl -s -o /dev/null -w "%{http_code}" -I "https://${DOMAIN}" --max-time 30 2>/dev/null || echo "000")"
case "$CURL_CODE" in
  200|301|302) row "https://${DOMAIN} returns ${CURL_CODE}" PASS "$CURL_CODE" ;;
  *)           row "https://${DOMAIN} returns 200/302"      FAIL "$CURL_CODE" ;;
esac

# 10. SES DKIM. email without DKIM is just spam with extra steps.
SES_STATUS="$(aws sesv2 get-email-identity --region "$REGION" \
  --email-identity "$(terraform output -raw ses_domain)" \
  --query 'DkimAttributes.Status' --output text 2>/dev/null || echo UNKNOWN)"
[[ "$SES_STATUS" == "SUCCESS" ]] && row "SES domain DKIM verified" PASS || row "SES domain DKIM verified" FAIL "$SES_STATUS (may still be propagating)"

# 11. the "Manajemen User" evidence: groups + IRSA roles, on display.
aws iam get-group --group-name "${NAME_PREFIX}-operators" >/dev/null 2>&1 \
  && row "IAM group ${NAME_PREFIX}-operators exists" PASS \
  || row "IAM group ${NAME_PREFIX}-operators exists" FAIL

for r in irsa-alb-controller irsa-cluster-autoscaler irsa-external-secrets irsa-chatwoot; do
  aws iam get-role --role-name "${NAME_PREFIX}-${r}" >/dev/null 2>&1 \
    && row "IRSA role ${NAME_PREFIX}-${r}" PASS \
    || row "IRSA role ${NAME_PREFIX}-${r}" FAIL
done

# 12. the golden rule: we added, we never touched what was already there.
NEW_VPC="$(terraform output -raw vpc_id)"
if jq -e --arg v "$NEW_VPC" '.existing.vpcs | has($v) | not' "$ROOT/terraform/discovery/do-not-touch.json" >/dev/null 2>&1; then
  row "no pre-existing VPC modified" PASS
else
  row "no pre-existing VPC modified" FAIL "$NEW_VPC overlaps discovery"
fi

popd >/dev/null

printf "\n  ${GRN}PASS=%d${CLR}  ${RED}FAIL=%d${CLR}\n" "$PASS" "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
  printf "${RED}Verification FAILED.${CLR}\n"
  exit 1
fi
printf "${GRN}Verification PASS — Chatwoot-TA is up and healthy at https://${DOMAIN}${CLR}\n"
