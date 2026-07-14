# Ops runbook

Scratch notes for running this stack. If something here contradicts the README,
the README wins. These notes are vibes, the README is law.

## Daily checks

- `./scripts/verify.sh` should be all PASS. If not, you know who to blame.
- Watch the CloudWatch log group for Sidekiq screaming.

## Snapshots

- `destroy.sh` takes a final RDS snapshot by default. Do not skip it unless you
  enjoy explaining data loss to people.

## Restore from a snapshot

1. Find the snapshot: `aws rds describe-db-snapshots --db-instance-identifier cwta-pg`
2. Restore it: `aws rds restore-db-instance-from-db-snapshot --db-instance-identifier cwta-pg-restored --db-snapshot-identifier <snap-id> --db-subnet-group-name cwta-rds`
3. Point a fresh `.env` at the restored instance and redeploy.
4. Pat yourself on the back. Restores are the only fun part of databases.
