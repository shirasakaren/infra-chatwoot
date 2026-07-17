#!/usr/bin/env bash
# when the ALB controller ghosted you and an orphan ALB is holding the VPC
# hostage, this script finds it and deletes it. it should never be needed.
# it is needed. that's the joke.
set -euo pipefail

# this deletes real billable infrastructure, so you have to literally type
# the word CONFIRM or it refuses to do anything. think twice, then think again.
[[ "${WIPE_CONFIRM:-}" == "CONFIRM" ]] || { echo "set WIPE_CONFIRM=CONFIRM if you mean it" >&2; exit 1; }
