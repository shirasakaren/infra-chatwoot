#!/usr/bin/env bash
# quick and dirty RDS snapshot helper. terraform skips the final snapshot on
# destroy (on purpose), so if you want one WITHOUT destroying everything,
# this is your guy. run it before anything scary. it's basically a hug for
# your database.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# shellcheck disable=SC1091
set -a; . "$ROOT/.env"; set +a

DB_ID="$(terraform -chdir="$ROOT/terraform" output -raw rds_instance_id 2>/dev/null || true)"
[[ -n "$DB_ID" ]] || { echo "no rds_instance_id in terraform output, nothing to hug" >&2; exit 1; }

# don't snap while RDS is mid-maintenance, the API gets grumpy
STATE="$(aws rds describe-db-instances --region "${AWS_REGION}" \
  --db-instance-identifier "${DB_ID}" \
  --query 'DBInstances[0].DBInstanceStatus' --output text 2>/dev/null || echo UNKNOWN)"
[[ "$STATE" == "available" ]] || { echo "db state is ${STATE}, not available, not touching it" >&2; exit 1; }

SNAP_ID="${NAME_PREFIX}-manual-$(date -u +%Y%m%d%H%M%S)"
aws rds create-db-snapshot \
  --region "${AWS_REGION}" \
  --db-snapshot-identifier "${SNAP_ID}" \
  --db-instance-identifier "${DB_ID}"

echo "snapshot ${SNAP_ID} requested"
