#!/usr/bin/env bash
# quick and dirty RDS snapshot helper. terraform skips the final snapshot on
# destroy (on purpose), so if you want one WITHOUT destroying everything,
# this is your guy. run it before anything scary. it's basically a hug for
# your database.
set -euo pipefail
