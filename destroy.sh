#!/usr/bin/env bash
# destroy.sh — safe, state-scoped teardown of Chatwoot-TA.
#
# Order (matters):
#   1. Typed confirmation of the project name.
#   2. Delete Kubernetes ingresses so the ALB controller cleanly removes the
#      ALB *before* TF tries to destroy the VPC/SGs/ENIs.
#   3. helm uninstall chatwoot (drops Service/Deployment/HPA/PDB).
#   4. Remove the Ansible-managed Cloudflare app DNS record (Terraform doesn't
#      own it).
#   5. Final RDS snapshot (unless --skip-snapshot).
#   6. terraform destroy on the main stack (state-scoped — only touches our
#      resources).
#   7. Optional --purge-state: empty + destroy the bootstrap S3 bucket and
#      DynamoDB lock table.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

RED=$'\033[0;31m'; GRN=$'\033[0;32m'; YLW=$'\033[1;33m'; BLU=$'\033[0;34m'; CLR=$'\033[0m'
say() { printf "  %s\n" "$*"; }
hdr() { printf "\n${BLU}========== %s ==========${CLR}\n" "$*"; }
die() { printf "${RED}ERROR:${CLR} %s\n" "$*" >&2; exit 1; }

PURGE_STATE=0
SKIP_SNAPSHOT=0
for arg in "$@"; do
  case "$arg" in
    --purge-state)   PURGE_STATE=1 ;;
    --skip-snapshot) SKIP_SNAPSHOT=1 ;;
    -h|--help)
      cat <<EOF
Usage: ./destroy.sh [--purge-state] [--skip-snapshot]

  --purge-state    Also destroy the bootstrap state bucket + lock table.
  --skip-snapshot  Skip final RDS snapshot (NOT recommended).
EOF
      exit 0 ;;
    *) die "Unknown flag: $arg" ;;
  esac
done

[[ -f "$ROOT/.env" ]] || die ".env not found; cannot determine project naming."
# shellcheck disable=SC1091
set -a; . "$ROOT/.env"; set +a
export CLOUDFLARE_API_TOKEN
export TF_VAR_owner="${OWNER}"
export TF_VAR_name_prefix="${NAME_PREFIX}"
export TF_VAR_region="${AWS_REGION}"
export TF_VAR_domain="${DOMAIN}"
export TF_VAR_cloudflare_zone="${CLOUDFLARE_ZONE}"
export TF_VAR_github_owner="${GITHUB_OWNER:-}"
export TF_VAR_github_repo="${GITHUB_REPO:-}"

# -----------------------------------------------------------------------------
# 1. Confirmation
# -----------------------------------------------------------------------------
hdr "Confirmation"
printf "${YLW}This will DESTROY Chatwoot-TA (project=%s, region=%s).${CLR}\n" \
  "${NAME_PREFIX}" "${AWS_REGION}"
printf "Type the project name (${NAME_PREFIX}) to confirm: "
read -r CONFIRM
[[ "$CONFIRM" == "${NAME_PREFIX}" ]] || die "Confirmation mismatch. Aborting."

# -----------------------------------------------------------------------------
# 2/3. Drain K8s-managed AWS resources first
# -----------------------------------------------------------------------------
if command -v kubectl >/dev/null 2>&1; then
  if aws eks update-kubeconfig --region "${AWS_REGION}" --name "${NAME_PREFIX}" \
       --alias "${NAME_PREFIX}" >/dev/null 2>&1 \
     && kubectl cluster-info >/dev/null 2>&1; then
    hdr "Draining ingresses + uninstalling Chatwoot"
    if helm list -A 2>/dev/null | awk '{print $1}' | grep -qx chatwoot; then
      helm uninstall chatwoot -n chatwoot --wait || true
    fi
    kubectl delete ingress --all --all-namespaces --ignore-not-found=true --wait=true || true

    say "Waiting up to 5 min for the controller-managed ALB to be deleted…"
    for _ in $(seq 1 30); do
      REMAINING="$(aws elbv2 describe-load-balancers --region "${AWS_REGION}" \
        --query "LoadBalancers[?starts_with(LoadBalancerName, \`${NAME_PREFIX}\`)].LoadBalancerArn" \
        --output text 2>/dev/null || true)"
      [[ -z "$REMAINING" ]] && break
      sleep 10
    done
  else
    say "EKS not reachable — skipping K8s drain step."
  fi
fi

# -----------------------------------------------------------------------------
# 4. Remove Ansible-managed Cloudflare app record
# -----------------------------------------------------------------------------
if [[ -n "${CLOUDFLARE_API_TOKEN:-}" ]]; then
  hdr "Removing Cloudflare app DNS record (Ansible-managed)"
  CF_ZONE_ID="$(curl -s -X GET \
    "https://api.cloudflare.com/client/v4/zones?name=${CLOUDFLARE_ZONE}" \
    -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
    -H "Content-Type: application/json" | jq -r '.result[0].id // empty')"
  if [[ -n "$CF_ZONE_ID" ]]; then
    REC_ID="$(curl -s -X GET \
      "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records?name=${DOMAIN}" \
      -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
      -H "Content-Type: application/json" | jq -r '.result[0].id // empty')"
    if [[ -n "$REC_ID" ]]; then
      curl -s -X DELETE \
        "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records/${REC_ID}" \
        -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" >/dev/null
      say "Cloudflare CNAME for ${DOMAIN} removed."
    else
      say "No Cloudflare record for ${DOMAIN} to remove."
    fi
  fi
fi

# -----------------------------------------------------------------------------
# 5/6. Final RDS snapshot + terraform destroy
# -----------------------------------------------------------------------------
if [[ -d "$ROOT/terraform/.terraform" ]]; then
  pushd "$ROOT/terraform" >/dev/null

  if [[ "$SKIP_SNAPSHOT" -eq 0 ]]; then
    DB_ID="$(terraform output -raw rds_instance_id 2>/dev/null || true)"
    if [[ -n "$DB_ID" ]]; then
      SNAP_ID="${NAME_PREFIX}-final-$(date -u +%Y%m%d%H%M%S)"
      hdr "Final RDS snapshot: ${SNAP_ID}"
      aws rds create-db-snapshot --region "${AWS_REGION}" \
        --db-snapshot-identifier "${SNAP_ID}" \
        --db-instance-identifier "${DB_ID}" >/dev/null
      aws rds wait db-snapshot-completed --region "${AWS_REGION}" \
        --db-snapshot-identifier "${SNAP_ID}"
      say "Snapshot ${SNAP_ID} ready."
      say "Restore with: ./deploy.sh after setting RESTORE_FROM_SNAPSHOT=${SNAP_ID}"
    fi
  fi

  hdr "terraform destroy (main stack)"
  terraform destroy -input=false -auto-approve
  popd >/dev/null
else
  say "Main stack not initialized; nothing to destroy there."
fi

# -----------------------------------------------------------------------------
# 7. Optional: purge bootstrap state backend
# -----------------------------------------------------------------------------
if [[ "$PURGE_STATE" -eq 1 ]]; then
  hdr "Purging bootstrap state backend"
  if [[ -d "$ROOT/bootstrap/.terraform" ]]; then
    pushd "$ROOT/bootstrap" >/dev/null
    BUCKET="$(terraform output -raw state_bucket 2>/dev/null || true)"
    if [[ -n "$BUCKET" ]]; then
      say "Emptying versioned bucket s3://${BUCKET}…"
      aws s3api list-object-versions --bucket "$BUCKET" --region "${AWS_REGION}" \
        --output json 2>/dev/null \
        | jq -c '{Objects: [(.Versions // []) + (.DeleteMarkers // [])
                  | .[] | {Key:.Key, VersionId:.VersionId}]}' \
        | while IFS= read -r batch; do
            [[ "$(echo "$batch" | jq '.Objects | length')" -gt 0 ]] || continue
            aws s3api delete-objects --bucket "$BUCKET" --region "${AWS_REGION}" \
              --delete "$batch" >/dev/null || true
          done
    fi
    terraform destroy -input=false -auto-approve \
      -var "region=${AWS_REGION}" \
      -var "name_prefix=${NAME_PREFIX}" \
      -var "owner=${OWNER}"
    popd >/dev/null
  fi
fi

printf "${GRN}Destroy complete.${CLR}\n"
