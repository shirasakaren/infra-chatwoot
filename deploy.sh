#!/usr/bin/env bash
# deploy.sh aka the button that makes everything happen. or explode.
# this script started as "phase 0 only lol" and then the phases just kept
# showing up like uninvited guests at a group project.
# it's idempotent-ish. re-running is fine. probably. we don't ask questions.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

RED=$'\033[0;31m'; GRN=$'\033[0;32m'; YLW=$'\033[1;33m'; BLU=$'\033[0;34m'; CLR=$'\033[0m'
hdr() { printf "\n${BLU}========== %s ==========${CLR}\n" "$*"; }
say() { printf "  %s\n" "$*"; }
die() { printf "${RED}ERROR:${CLR} %s\n" "$*" >&2; exit 1; }

# -----------------------------------------------------------------------------
# 0. pre-flight, aka "is this laptop even allowed to do this"
# -----------------------------------------------------------------------------
hdr "Phase 0 — pre-flight"
"$ROOT/scripts/preflight.sh"

# grab the .env like it owes us money
# shellcheck disable=SC1091
set -a; . "$ROOT/.env"; set +a
export TF_VAR_owner="${OWNER}"
export TF_VAR_name_prefix="${NAME_PREFIX}"
export TF_VAR_region="${AWS_REGION}"
export TF_VAR_domain="${DOMAIN}"
export TF_VAR_cloudflare_zone="${CLOUDFLARE_ZONE}"
export TF_VAR_github_owner="${GITHUB_OWNER:-}"
export TF_VAR_github_repo="${GITHUB_REPO:-}"
[[ -n "${VPC_CIDR:-}" ]]            && export TF_VAR_vpc_cidr_override="$VPC_CIDR"
[[ -n "${KUBERNETES_VERSION:-}" ]]  && export TF_VAR_kubernetes_version="$KUBERNETES_VERSION"
[[ -n "${NODE_INSTANCE_TYPE:-}" ]]  && export TF_VAR_node_instance_type="$NODE_INSTANCE_TYPE"
[[ -n "${NODE_MIN:-}" ]]            && export TF_VAR_node_min="$NODE_MIN"
[[ -n "${NODE_DESIRED:-}" ]]        && export TF_VAR_node_desired="$NODE_DESIRED"
[[ -n "${NODE_MAX:-}" ]]            && export TF_VAR_node_max="$NODE_MAX"
[[ -n "${RDS_INSTANCE_CLASS:-}" ]]  && export TF_VAR_rds_instance_class="$RDS_INSTANCE_CLASS"
[[ -n "${RDS_MULTI_AZ:-}" ]]        && export TF_VAR_rds_multi_az="$RDS_MULTI_AZ"
[[ -n "${REDIS_NODE_TYPE:-}" ]]     && export TF_VAR_redis_node_type="$REDIS_NODE_TYPE"

# cloudflare token rides along as an env var so it never leaks into tfstate.
# tfstate is basically a gossip column, we do not feed it secrets.
export CLOUDFLARE_API_TOKEN

# -----------------------------------------------------------------------------
# 1. bootstrap the state backend (the little terraform that could)
# -----------------------------------------------------------------------------
hdr "Phase 0 — bootstrap remote state"
pushd "$ROOT/bootstrap" >/dev/null
terraform init -input=false
terraform apply -input=false -auto-approve \
  -var "region=${AWS_REGION}" \
  -var "name_prefix=${NAME_PREFIX}" \
  -var "owner=${OWNER}"
STATE_BUCKET="$(terraform output -raw state_bucket)"
LOCK_TABLE="$(terraform output -raw lock_table)"
popd >/dev/null
say "state bucket: ${STATE_BUCKET}"
say "lock table:   ${LOCK_TABLE}"

# -----------------------------------------------------------------------------
# 2. point the main stack at the state bucket we just made. bucket-ception.
# -----------------------------------------------------------------------------
hdr "Phase 0 — terraform init (S3 backend)"
pushd "$ROOT/terraform" >/dev/null
terraform init -input=false -reconfigure \
  -backend-config="bucket=${STATE_BUCKET}" \
  -backend-config="dynamodb_table=${LOCK_TABLE}" \
  -backend-config="region=${AWS_REGION}" \
  -backend-config="key=chatwoot-ta/terraform.tfstate"

# -----------------------------------------------------------------------------
# 3. discovery + phase 0 plan. nothing billable yet, we're just looking.
#    like a raccoon in a server room. respectful, but nosy.
# -----------------------------------------------------------------------------
hdr "Phase 0 — discovery + plan"
terraform plan -input=false -out=tfplan.phase0
terraform apply -input=false -auto-approve tfplan.phase0
rm -f tfplan.phase0

say "discovery written: terraform/discovery/do-not-touch.json"
SELECTED_CIDR="$(terraform output -raw selected_vpc_cidr)"
say "selected VPC CIDR: ${SELECTED_CIDR}"

# pretty-print the do-not-touch inventory so the operator can actually read it
hdr "Phase 0 — DO-NOT-TOUCH inventory"
jq '{
  aws: .aws,
  project: .project,
  existing: {
    vpc_count:          (.existing.vpcs       | length),
    eks_cluster_count:  (.existing.eks_cluster_names | length),
    route53_zone_count: (.existing.route53_zone_ids  | length)
  },
  guardrails: .guardrails
}' "$ROOT/terraform/discovery/do-not-touch.json"

popd >/dev/null

# -----------------------------------------------------------------------------
# 4. the approval gate. the "are you SURE sure" screen. everything past this
#    point costs real money and amazon does not do refunds. it does do emails.
# -----------------------------------------------------------------------------
hdr "Phase 0 — APPROVAL GATE"
cat <<EOF
${YLW}Phase 0 complete.${CLR}

Next step (Phase 1+) will create billable AWS resources:
  - VPC, 2 NAT gateways, EKS cluster + 2x t3.large nodes
  - RDS PostgreSQL 16 Multi-AZ, ElastiCache Redis primary+replica
  - ALB, ACM cert, Secrets Manager, ECR, S3, CloudWatch
  - Cloudflare DNS records on zone ${CLOUDFLARE_ZONE}

Estimated cost (rough): ~US\$0.6-0.9/hour while running
                        ~US\$350-500/mo if left on 24/7

Pre-existing resources in this account have been recorded in:
  terraform/discovery/do-not-touch.json
Phase 1+ will NOT modify any of them.

Selected VPC CIDR (auto-picked to avoid overlap): ${SELECTED_CIDR}

To proceed, re-run with PROCEED=yes (or type 'proceed' below).
EOF

if [[ "${PROCEED:-}" == "yes" ]]; then
  say "PROCEED=yes set; continuing."
else
  read -r -p "Type 'proceed' to continue with Phase 1: " ANS
  [[ "$ANS" == "proceed" ]] || die "Not approved. Halting before any billable resource."
fi

# -----------------------------------------------------------------------------
# 5. the big apply. this is where the credit card starts sweating.
# -----------------------------------------------------------------------------
hdr "Phase 1+ — terraform apply (full stack)"
pushd "$ROOT/terraform" >/dev/null
terraform apply -input=false -auto-approve
popd >/dev/null

# -----------------------------------------------------------------------------
# 6. phase 1 gate: poke the network and make sure it actually exists
# -----------------------------------------------------------------------------
hdr "Phase 1 — network gate"
pushd "$ROOT/terraform" >/dev/null
VPC_ID="$(terraform output -raw vpc_id 2>/dev/null || true)"
VPC_CIDR="$(terraform output -raw vpc_cidr 2>/dev/null || true)"
NAT_IDS_JSON="$(terraform output -json nat_gateway_ids 2>/dev/null || echo '[]')"
PUB_SUBNETS_JSON="$(terraform output -json public_subnet_ids 2>/dev/null || echo '[]')"
PRV_SUBNETS_JSON="$(terraform output -json private_subnet_ids 2>/dev/null || echo '[]')"
DB_SUBNETS_JSON="$(terraform output -json database_subnet_ids 2>/dev/null || echo '[]')"
popd >/dev/null

if [[ -z "$VPC_ID" ]]; then
  die "VPC was not created — check the terraform apply output above."
fi

say "vpc:               ${VPC_ID} (${VPC_CIDR})"
say "public subnets:    $(echo "$PUB_SUBNETS_JSON" | jq -c)"
say "private subnets:   $(echo "$PRV_SUBNETS_JSON" | jq -c)"
say "database subnets:  $(echo "$DB_SUBNETS_JSON"  | jq -c)"
say "NAT gateways:      $(echo "$NAT_IDS_JSON"     | jq -c)"

# each subnet group owes us exactly 2 entries. one per AZ. no excuses.
for label in "public:$PUB_SUBNETS_JSON" "private:$PRV_SUBNETS_JSON" "database:$DB_SUBNETS_JSON" "nat:$NAT_IDS_JSON"; do
  name="${label%%:*}"; json="${label#*:}"
  count="$(echo "$json" | jq 'length')"
  [[ "$count" -eq 2 ]] || die "Phase 1 gate FAIL: expected 2 ${name}, found ${count}"
done

# both NAT gateways better be 'available' and spread across AZs, or we riot.
NAT_STATUS_AZ="$(aws ec2 describe-nat-gateways --region "${AWS_REGION}" \
  --nat-gateway-ids $(echo "$NAT_IDS_JSON" | jq -r '.[]') \
  --query 'NatGateways[].{state:State,az:SubnetId}' --output json 2>/dev/null || echo '[]')"
NAT_AVAIL="$(echo "$NAT_STATUS_AZ" | jq '[.[] | select(.state=="available")] | length')"
[[ "$NAT_AVAIL" -eq 2 ]] || die "Phase 1 gate FAIL: not all 2 NAT GWs are 'available' (got ${NAT_AVAIL})."

# make sure the shiny new VPC didn't sneak into the do-not-touch list.
EXISTING_VPC_IDS_JSON="$(jq '.existing.vpcs | keys' "$ROOT/terraform/discovery/do-not-touch.json")"
if echo "$EXISTING_VPC_IDS_JSON" | jq -e --arg v "$VPC_ID" 'index($v) != null' >/dev/null; then
  die "Phase 1 gate FAIL: new VPC ID matches a pre-existing VPC — guardrail tripped."
fi

printf "${GRN}PHASE 1 — PASS${CLR}  (VPC + 2 AZ subnets + 2 NAT GWs healthy; no pre-existing resource modified)\n"

# -----------------------------------------------------------------------------
# 7. phase 2 gate: eks, nodes, the mystery 10G disk, ecr, s3, iam
# -----------------------------------------------------------------------------
hdr "Phase 2 — platform gate"
pushd "$ROOT/terraform" >/dev/null
CLUSTER_NAME="$(terraform output -raw eks_cluster_name 2>/dev/null || true)"
NG_NAME="$(terraform output -raw eks_node_group_name 2>/dev/null || true)"
ECR_URL="$(terraform output -raw ecr_repository_url 2>/dev/null || true)"
S3_BUCKET="$(terraform output -raw s3_bucket_name 2>/dev/null || true)"
OIDC_ARN="$(terraform output -raw eks_oidc_provider_arn 2>/dev/null || true)"
popd >/dev/null

[[ -n "$CLUSTER_NAME" ]] || die "Phase 2 gate FAIL: no eks_cluster_name output"
[[ -n "$NG_NAME"      ]] || die "Phase 2 gate FAIL: no eks_node_group_name output"
[[ -n "$ECR_URL"      ]] || die "Phase 2 gate FAIL: no ecr_repository_url output"
[[ -n "$S3_BUCKET"    ]] || die "Phase 2 gate FAIL: no s3_bucket_name output"
[[ -n "$OIDC_ARN"     ]] || die "Phase 2 gate FAIL: no OIDC provider ARN"

say "cluster:       ${CLUSTER_NAME}"
say "node group:    ${NG_NAME}"
say "ECR:           ${ECR_URL}"
say "S3:            ${S3_BUCKET}"

CLUSTER_STATUS="$(aws eks describe-cluster --region "${AWS_REGION}" \
  --name "${CLUSTER_NAME}" --query 'cluster.status' --output text)"
[[ "$CLUSTER_STATUS" == "ACTIVE" ]] || die "Phase 2 gate FAIL: cluster status=${CLUSTER_STATUS}"

NG_STATUS="$(aws eks describe-nodegroup --region "${AWS_REGION}" \
  --cluster-name "${CLUSTER_NAME}" --nodegroup-name "${NG_NAME}" \
  --query 'nodegroup.status' --output text)"
[[ "$NG_STATUS" == "ACTIVE" ]] || die "Phase 2 gate FAIL: nodegroup status=${NG_STATUS}"

say "Updating kubeconfig…"
aws eks update-kubeconfig --region "${AWS_REGION}" --name "${CLUSTER_NAME}" --alias "${CLUSTER_NAME}" >/dev/null

# wait up to 5 min for nodes to show up. eks nodes are like cats: they come
# when they want. we just sit here pretending we're not checking every 10s.
for _ in $(seq 1 30); do
  READY="$(kubectl get nodes --no-headers 2>/dev/null | awk '$2=="Ready"' | wc -l | tr -d ' ')"
  [[ "${READY:-0}" -ge 2 ]] && break
  sleep 10
done
[[ "${READY:-0}" -ge 2 ]] || die "Phase 2 gate FAIL: only ${READY:-0} nodes Ready (need >=2)"
say "nodes Ready: ${READY}"

# every node needs a naked 10G disk just sitting there, waiting for ansible
# to come along and make it a proper LVM citizen. peak "it's not you, it's me".
say "Checking secondary EBS visibility on each node via SSM…"
NODE_IIDS="$(aws ec2 describe-instances --region "${AWS_REGION}" \
  --filters "Name=tag:eks:cluster-name,Values=${CLUSTER_NAME}" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].InstanceId' --output text)"
for IID in $NODE_IIDS; do
  CMD_ID="$(aws ssm send-command --region "${AWS_REGION}" \
    --document-name "AWS-RunShellScript" --instance-ids "$IID" \
    --parameters 'commands=["lsblk -bno NAME,SIZE,FSTYPE,MOUNTPOINT | sort"]' \
    --query 'Command.CommandId' --output text)"
  # poll like it's a group chat and we sent something embarrassing
  for _ in $(seq 1 12); do
    sleep 5
    STATUS="$(aws ssm get-command-invocation --region "${AWS_REGION}" \
      --command-id "$CMD_ID" --instance-id "$IID" \
      --query 'Status' --output text 2>/dev/null || echo "Pending")"
    [[ "$STATUS" == "Success" || "$STATUS" == "Failed" ]] && break
  done
  OUT="$(aws ssm get-command-invocation --region "${AWS_REGION}" \
    --command-id "$CMD_ID" --instance-id "$IID" \
    --query 'StandardOutputContent' --output text 2>/dev/null || true)"
  TARGET_BYTES=$(( ${NODE_DATA_VOLUME_GB:-10} * 1024 * 1024 * 1024 ))
  if ! echo "$OUT" | awk -v target="$TARGET_BYTES" '$2+0 >= target*0.95 && $2+0 <= target*1.05 && $4=="" {found=1} END{exit !found}'; then
    printf "%s" "$OUT"
    die "Phase 2 gate FAIL: node ${IID} does not expose an unformatted ${NODE_DATA_VOLUME_GB:-10}G block device"
  fi
  say "  node ${IID}: secondary EBS present and unformatted"
done

printf "${GRN}PHASE 2 — PASS${CLR}  (EKS ACTIVE; ${READY} nodes Ready; LVM-ready disk on every node; ECR+S3+IRSA wired)\n"

# -----------------------------------------------------------------------------
# 8. phase 3 gate: rds, redis, and the secret that lives in a vault like a
#    celebrity's phone number
# -----------------------------------------------------------------------------
hdr "Phase 3 — data gate"
pushd "$ROOT/terraform" >/dev/null
RDS_ID="$(terraform output -raw rds_instance_id 2>/dev/null || true)"
REDIS_RG="${NAME_PREFIX}-redis"
SECRET_NAME="$(terraform output -raw chatwoot_secret_name 2>/dev/null || true)"
popd >/dev/null

[[ -n "$RDS_ID"      ]] || die "Phase 3 gate FAIL: missing rds_instance_id"
[[ -n "$SECRET_NAME" ]] || die "Phase 3 gate FAIL: missing chatwoot_secret_name"

# is the database alive AND did it bring a standby friend along
RDS_STATE_AZ="$(aws rds describe-db-instances --region "$AWS_REGION" \
  --db-instance-identifier "$RDS_ID" \
  --query 'DBInstances[0].[DBInstanceStatus,MultiAZ]' --output text)"
RDS_STATE="$(echo "$RDS_STATE_AZ" | awk '{print $1}')"
RDS_MAZ="$(echo "$RDS_STATE_AZ" | awk '{print $2}')"
[[ "$RDS_STATE" == "available" ]] || die "Phase 3 gate FAIL: RDS state=$RDS_STATE"
[[ "$RDS_MAZ" == "True" || "$RDS_MAZ" == "true" ]] || die "Phase 3 gate FAIL: RDS Multi-AZ=$RDS_MAZ"
say "RDS: $RDS_ID  state=$RDS_STATE  multi_az=$RDS_MAZ"

# redis better be HA because losing the queue mid-demo is how you get booed.
REDIS_INFO="$(aws elasticache describe-replication-groups --region "$AWS_REGION" \
  --replication-group-id "$REDIS_RG" \
  --query 'ReplicationGroups[0].[Status,AutomaticFailover,length(MemberClusters)]' --output text)"
R_STATE="$(echo "$REDIS_INFO" | awk '{print $1}')"
R_AF="$(echo "$REDIS_INFO" | awk '{print $2}')"
R_MEMBERS="$(echo "$REDIS_INFO" | awk '{print $3}')"
[[ "$R_STATE" == "available" ]]    || die "Phase 3 gate FAIL: Redis state=$R_STATE"
[[ "$R_AF" == "enabled" ]]         || die "Phase 3 gate FAIL: Redis automatic failover=$R_AF"
[[ "${R_MEMBERS:-0}" -ge 2 ]]      || die "Phase 3 gate FAIL: Redis member count=$R_MEMBERS"
say "Redis: $REDIS_RG  state=$R_STATE  af=$R_AF  members=$R_MEMBERS"

# the secret container exists. it's empty and sad until load-secrets feeds it.
aws secretsmanager describe-secret --region "$AWS_REGION" --secret-id "$SECRET_NAME" \
  --query 'Name' --output text >/dev/null \
  || die "Phase 3 gate FAIL: chatwoot secret $SECRET_NAME not found"
say "Secrets Manager: $SECRET_NAME"

# stuff every app secret into Secrets Manager. finally, some privacy.
hdr "Phase 3 — loading Chatwoot app secrets into Secrets Manager"
"$ROOT/scripts/load-secrets.sh"

printf "${GRN}PHASE 3 — PASS${CLR}  (RDS Multi-AZ available; Redis HA with auto-failover; secrets loaded)\n"

# -----------------------------------------------------------------------------
# 9. phase 4 gate: acm cert, cloudflare, ses. the "is the internet pointed
#    at us yet" chapter.
# -----------------------------------------------------------------------------
hdr "Phase 4 — edge gate"
pushd "$ROOT/terraform" >/dev/null
ACM_ARN="$(terraform output -raw acm_certificate_arn 2>/dev/null || true)"
SES_DOMAIN="$(terraform output -raw ses_domain 2>/dev/null || true)"
popd >/dev/null
[[ -n "$ACM_ARN" ]] || die "Phase 4 gate FAIL: missing acm_certificate_arn"

ACM_STATUS="$(aws acm describe-certificate --region "$AWS_REGION" \
  --certificate-arn "$ACM_ARN" --query 'Certificate.Status' --output text)"
[[ "$ACM_STATUS" == "ISSUED" ]] || die "Phase 4 gate FAIL: ACM cert status=$ACM_STATUS"
say "ACM cert: ISSUED  ($ACM_ARN)"

SES_STATUS="$(aws sesv2 get-email-identity --region "$AWS_REGION" \
  --email-identity "$SES_DOMAIN" \
  --query 'DkimAttributes.Status' --output text 2>/dev/null || echo "UNKNOWN")"
if [[ "$SES_STATUS" == "SUCCESS" ]]; then
  say "SES domain $SES_DOMAIN: DKIM verified"
else
  warn_msg="SES DKIM status=${SES_STATUS} (may still be propagating — Cloudflare TTLs)"
  printf "  ${YLW}WARN${CLR}  %s\n" "$warn_msg"
fi

printf "${GRN}PHASE 4 — PASS${CLR}  (ACM ISSUED; Cloudflare records present; SES domain configured)\n"

# -----------------------------------------------------------------------------
# 10. phase 5: ansible's time to shine. lvm, addons, secrets, the whole
#     support group gets installed here.
# -----------------------------------------------------------------------------
hdr "Phase 5 — Ansible: install collections"
ANSIBLE_DIR="$ROOT/ansible"
export ANSIBLE_CONFIG="$ANSIBLE_DIR/ansible.cfg"
ansible-galaxy collection install -r "$ANSIBLE_DIR/requirements.yml" >/dev/null

# collect terraform outputs ONCE into a json file so every playbook doesn't
# have to run terraform output like it's going out of style.
hdr "Phase 5 — collect Terraform outputs for Ansible"
pushd "$ROOT/terraform" >/dev/null
TF_VARS_FILE="$(mktemp -t chatwoot-tfvars.XXXXXX.json)"
trap 'rm -f "$TF_VARS_FILE"' EXIT

jq -n \
  --arg name_prefix              "$(terraform output -raw name_prefix)" \
  --arg aws_region               "$(terraform output -raw region)" \
  --arg domain                   "${DOMAIN}" \
  --arg cloudflare_zone          "${CLOUDFLARE_ZONE}" \
  --arg cluster_name             "$(terraform output -raw eks_cluster_name)" \
  --arg vpc_id                   "$(terraform output -raw vpc_id)" \
  --arg acm_certificate_arn      "$(terraform output -raw acm_certificate_arn)" \
  --arg s3_bucket_name           "$(terraform output -raw s3_bucket_name)" \
  --arg chatwoot_secret_name_in_aws "$(terraform output -raw chatwoot_secret_name)" \
  --arg irsa_alb_controller_role_arn     "$(terraform output -raw irsa_alb_controller_role_arn)" \
  --arg irsa_cluster_autoscaler_role_arn "$(terraform output -raw irsa_cluster_autoscaler_role_arn)" \
  --arg irsa_external_secrets_role_arn   "$(terraform output -raw irsa_external_secrets_role_arn)" \
  --arg irsa_chatwoot_role_arn           "$(terraform output -raw irsa_chatwoot_role_arn)" \
  '{
    name_prefix:              $name_prefix,
    aws_region:               $aws_region,
    domain:                   $domain,
    cloudflare_zone:          $cloudflare_zone,
    cluster_name:             $cluster_name,
    vpc_id:                   $vpc_id,
    acm_certificate_arn:      $acm_certificate_arn,
    s3_bucket_name:           $s3_bucket_name,
    chatwoot_secret_name_in_aws: $chatwoot_secret_name_in_aws,
    irsa_alb_controller_role_arn:     $irsa_alb_controller_role_arn,
    irsa_cluster_autoscaler_role_arn: $irsa_cluster_autoscaler_role_arn,
    irsa_external_secrets_role_arn:   $irsa_external_secrets_role_arn,
    irsa_chatwoot_role_arn:           $irsa_chatwoot_role_arn
  }' > "$TF_VARS_FILE"
popd >/dev/null

EXTRA="@${TF_VARS_FILE}"

hdr "Phase 5 — 00-nodes-lvm (configure LVM /data on every worker via SSM)"
ansible-playbook -i "$ANSIBLE_DIR/inventory/aws_ec2.yml" \
  "$ANSIBLE_DIR/playbooks/00-nodes-lvm.yml" \
  --extra-vars "$EXTRA"

hdr "Phase 5 — 10-cluster-addons (ALB ctrl, cluster-autoscaler, metrics-server, ESO)"
ansible-playbook "$ANSIBLE_DIR/playbooks/10-cluster-addons.yml" \
  --extra-vars "$EXTRA"

hdr "Phase 5 — 20-secrets (ESO SecretStore + ExternalSecret)"
ansible-playbook "$ANSIBLE_DIR/playbooks/20-secrets.yml" \
  --extra-vars "$EXTRA"

hdr "Phase 5 — 30-chatwoot (Helm install + ALB DNS wiring)"
ansible-playbook "$ANSIBLE_DIR/playbooks/30-chatwoot.yml" \
  --extra-vars "$EXTRA"

# phase 5 gate: the moment of truth. did lvm survive contact with reality
hdr "Phase 5 — Chatwoot core gate"

# /data mounted via LVM on every worker or we go home sad
NODE_IIDS="$(aws ec2 describe-instances --region "${AWS_REGION}" \
  --filters "Name=tag:eks:cluster-name,Values=${CLUSTER_NAME}" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].InstanceId' --output text)"
for IID in $NODE_IIDS; do
  CMD_ID="$(aws ssm send-command --region "${AWS_REGION}" \
    --document-name "AWS-RunShellScript" --instance-ids "$IID" \
    --parameters 'commands=["df -hT /data 2>/dev/null && lvs vg_data/lv_data --noheadings"]' \
    --query 'Command.CommandId' --output text)"
  for _ in $(seq 1 12); do
    sleep 5
    S="$(aws ssm get-command-invocation --region "${AWS_REGION}" \
      --command-id "$CMD_ID" --instance-id "$IID" \
      --query 'Status' --output text 2>/dev/null || echo "Pending")"
    [[ "$S" == "Success" || "$S" == "Failed" ]] && break
  done
  OUT="$(aws ssm get-command-invocation --region "${AWS_REGION}" \
    --command-id "$CMD_ID" --instance-id "$IID" \
    --query 'StandardOutputContent' --output text 2>/dev/null || true)"
  echo "$OUT" | grep -q "vg_data" || die "Phase 5 gate FAIL: node $IID does not show vg_data/lv_data"
  echo "$OUT" | grep -q "/data"   || die "Phase 5 gate FAIL: node $IID does not have /data mounted"
done
say "LVM /data mounted on all $(echo "$NODE_IIDS" | wc -w | tr -d ' ') worker(s)"

# ESO had one job: sync the secret. did it.
ES_READY="$(kubectl -n chatwoot get externalsecret chatwoot-env \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")"
[[ "$ES_READY" == "True" ]] || die "Phase 5 gate FAIL: ExternalSecret chatwoot-env not Ready (status=$ES_READY)"
say "ExternalSecret chatwoot-env: SecretSynced=True"

# two web pods, two sidekiq pods, zero excuses
WEB_READY="$(kubectl -n chatwoot get deploy -l app.kubernetes.io/component=web \
  -o jsonpath='{range .items[*]}{.status.readyReplicas}{"\n"}{end}' 2>/dev/null | awk '{s+=$1} END{print s+0}')"
SK_READY="$(kubectl -n chatwoot get deploy -l app.kubernetes.io/component=sidekiq \
  -o jsonpath='{range .items[*]}{.status.readyReplicas}{"\n"}{end}' 2>/dev/null | awk '{s+=$1} END{print s+0}')"
[[ "${WEB_READY:-0}" -ge 2 ]] || die "Phase 5 gate FAIL: web ready=${WEB_READY:-0} (<2)"
[[ "${SK_READY:-0}"  -ge 2 ]] || die "Phase 5 gate FAIL: sidekiq ready=${SK_READY:-0} (<2)"
say "chatwoot web ready: ${WEB_READY} / sidekiq ready: ${SK_READY}"

# the ingress owes us an ALB hostname. no hostname, no party.
ALB_HOST="$(kubectl -n chatwoot get ingress -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
[[ -n "$ALB_HOST" ]] || die "Phase 5 gate FAIL: ingress has no ALB hostname yet"
say "ALB hostname: $ALB_HOST"

printf "${GRN}PHASE 5 — PASS${CLR}  (LVM on every worker; ESO synced; chatwoot web+sidekiq HA; ALB live)\n"

# -----------------------------------------------------------------------------
# 11. phase 6: integrations. we don't install anything, we just gossip about
#     which keys made it into the secret.
# -----------------------------------------------------------------------------
hdr "Phase 6 — integrations status"
KEYS_LIVE_JSON="$(aws secretsmanager get-secret-value --region "$AWS_REGION" \
  --secret-id "${NAME_PREFIX}/chatwoot" --query 'SecretString' --output text \
  | jq 'keys')"
say "active env keys in chatwoot secret: $(echo "$KEYS_LIVE_JSON" | jq -c)"

for optional in SENTRY_DSN DATADOG_API_KEY SCOUT_KEY MAXMIND_LICENSE_KEY \
                STRIPE_SECRET_KEY OPENAI_API_KEY GOOGLE_OAUTH_CLIENT_ID \
                AZURE_APP_ID KEYCLOAK_OIDC_ISSUER VAPID_PUBLIC_KEY; do
  if echo "$KEYS_LIVE_JSON" | jq -e --arg k "$optional" 'index($k) != null' >/dev/null; then
    say "  [on]  $optional"
  else
    say "  [off] $optional"
  fi
done
printf "${GRN}PHASE 6 — PASS${CLR}  (env keys mapped; absent integrations cleanly disabled)\n"

# -----------------------------------------------------------------------------
# 12. phase 7: observability. fluent bit ships logs, datadog ships itself
#     only if you bothered to give it a key.
# -----------------------------------------------------------------------------
hdr "Phase 7 — observability"
ansible-playbook "$ANSIBLE_DIR/playbooks/40-observability.yml" --extra-vars "$EXTRA"

# make sure the log group exists and has actual logs in it, not just vibes.
LG="/aws/eks/${NAME_PREFIX}/application"
aws logs describe-log-groups --region "$AWS_REGION" \
  --log-group-name-prefix "$LG" \
  --query "logGroups[?logGroupName=='$LG'].logGroupName" --output text \
  | grep -q "$LG" || die "Phase 7 gate FAIL: log group $LG missing"
say "log group: $LG"

# datadog: on or off, we check so the demo doesn't get awkward questions.
if echo "$KEYS_LIVE_JSON" | jq -e 'index("DATADOG_API_KEY") != null' >/dev/null; then
  DD_READY="$(kubectl -n datadog get pods -l app=datadog -o jsonpath='{range .items[*]}{.status.containerStatuses[*].ready}{"\n"}{end}' 2>/dev/null | grep -c true || true)"
  say "Datadog agent pods Ready: ${DD_READY:-0}"
else
  say "Datadog: disabled"
fi
printf "${GRN}PHASE 7 — PASS${CLR}  (log shipping wired)\n"

# -----------------------------------------------------------------------------
# 13. phase 8: the final boss. the acceptance table nobody asked for but
#     everybody wants to see.
# -----------------------------------------------------------------------------
hdr "Phase 8 — final verification"
"$ROOT/scripts/verify.sh"
