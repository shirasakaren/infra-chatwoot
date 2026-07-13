# Ops runbook

Scratch notes for running this stack. If something here contradicts the README,
the README wins. These notes are vibes, the README is law.

## Daily checks

- `./scripts/verify.sh` should be all PASS. If not, you know who to blame.
- Watch the CloudWatch log group for Sidekiq screaming.

## Snapshots

- `destroy.sh` takes a final RDS snapshot by default. Do not skip it unless you
  enjoy explaining data loss to people.
