#!/usr/bin/env bash
# when the ALB controller ghosted you and an orphan ALB is holding the VPC
# hostage, this script finds it and deletes it. it should never be needed.
# it is needed. that's the joke.
set -euo pipefail
