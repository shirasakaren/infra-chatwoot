#!/usr/bin/env bash
# scripts/load-secrets.sh
# takes .env + terraform outputs + the RDS password that AWS is hoarding,
# smushes it all into one big JSON, and shoves it into Secrets Manager.
# run AFTER terraform apply and BEFORE the ansible secrets/helm playbooks.
# it's idempotent, so if you re-run it it just rewrites the same gossip.
#
# why the ceremony? because tfstate is basically a public diary and we don't
# write passwords in diaries. the secret never touches state, never touches
# git, never touches the floor. it lives in Secrets Manager and that's it.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

RED=$'\033[0;31m'; GRN=$'\033[0;32m'; YLW=$'\033[1;33m'; BLU=$'\033[0;34m'; CLR=$'\033[0m'
say() { printf "  %s\n" "$*"; }
hdr() { printf "\n${BLU}==> %s${CLR}\n" "$*"; }
die() { printf "${RED}ERROR:${CLR} %s\n" "$*" >&2; exit 1; }

[[ -f "$ROOT/.env" ]] || die ".env missing — preflight should have caught this."
# shellcheck disable=SC1091
set -a; . "$ROOT/.env"; set +a

REGION="${AWS_REGION:-ap-southeast-1}"

hdr "Reading Terraform outputs"
pushd "$ROOT/terraform" >/dev/null
TF_RDS_ADDR="$(terraform output -raw rds_address)"
TF_RDS_PORT="$(terraform output -raw rds_port)"
TF_RDS_DB="$(terraform output -raw rds_db_name)"
TF_RDS_USER="$(terraform output -raw rds_username)"
TF_RDS_SECRET_ARN="$(terraform output -raw rds_managed_secret_arn)"
TF_REDIS_HOST="$(terraform output -raw redis_primary_endpoint)"
TF_REDIS_PORT="$(terraform output -raw redis_port)"
TF_REDIS_SECRET_ARN="$(terraform output -raw redis_auth_secret_arn)"
TF_S3_BUCKET="$(terraform output -raw s3_bucket_name)"
TF_CHATWOOT_SECRET_NAME="$(terraform output -raw chatwoot_secret_name)"
TF_SES_HOST="$(terraform output -raw ses_smtp_endpoint 2>/dev/null || true)"
TF_SES_USER="$(terraform output -raw ses_smtp_username 2>/dev/null || true)"
TF_SES_PASS="$(terraform output -raw ses_smtp_password 2>/dev/null || true)"
TF_SES_DOMAIN="$(terraform output -raw ses_domain 2>/dev/null || true)"
popd >/dev/null

# SES creds: trust terraform's generated ones unless .env explicitly fights us.
SMTP_ADDRESS="${SMTP_ADDRESS:-$TF_SES_HOST}"
SMTP_USERNAME="${SMTP_USERNAME:-$TF_SES_USER}"
SMTP_PASSWORD="${SMTP_PASSWORD:-$TF_SES_PASS}"
SMTP_DOMAIN="${SMTP_DOMAIN:-$TF_SES_DOMAIN}"

hdr "Fetching managed credentials"
RDS_PASSWORD="$(aws secretsmanager get-secret-value --region "$REGION" \
  --secret-id "$TF_RDS_SECRET_ARN" --query SecretString --output text | jq -r .password)"
[[ -n "$RDS_PASSWORD" && "$RDS_PASSWORD" != "null" ]] || die "Could not read RDS managed password"

REDIS_PAYLOAD="$(aws secretsmanager get-secret-value --region "$REGION" \
  --secret-id "$TF_REDIS_SECRET_ARN" --query SecretString --output text)"
REDIS_AUTH="$(echo "$REDIS_PAYLOAD" | jq -r .auth_token)"
[[ -n "$REDIS_AUTH" && "$REDIS_AUTH" != "null" ]] || die "Could not read Redis auth token"

# the redis token goes inside a URL, and URLs are picky about characters.
# urls are the vegans of strings. we pre-chew the token for them.
urlencode() {
  python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
}
REDIS_AUTH_ENC="$(urlencode "$REDIS_AUTH")"
REDIS_URL="rediss://:${REDIS_AUTH_ENC}@${TF_REDIS_HOST}:${TF_REDIS_PORT}/0"

# no SECRET_KEY_BASE? fine, we'll roll one on the spot like we planned this.
if [[ -z "${SECRET_KEY_BASE:-}" ]]; then
  SECRET_KEY_BASE="$(openssl rand -hex 64)"
  say "SECRET_KEY_BASE auto-generated."
fi

# VAPID keys for web push. node might not have web-push installed, in which
# case we shrug and let the helm chart figure it out. delegation, baby.
if [[ -z "${VAPID_PUBLIC_KEY:-}" || -z "${VAPID_PRIVATE_KEY:-}" ]]; then
  if command -v node >/dev/null 2>&1; then
    VAPID_JSON="$(node -e "const w=require('web-push');console.log(JSON.stringify(w.generateVAPIDKeys()))" 2>/dev/null || true)"
    if [[ -n "$VAPID_JSON" ]]; then
      VAPID_PUBLIC_KEY="$(echo "$VAPID_JSON" | jq -r .publicKey)"
      VAPID_PRIVATE_KEY="$(echo "$VAPID_JSON" | jq -r .privateKey)"
      say "VAPID web-push keys auto-generated."
    fi
  fi
  # Helm chart will fall back to its own auto-generation if both still blank.
fi

# -----------------------------------------------------------------------------
# build the payload. every blank key gets yeeted at the end, which is how
# "empty value = feature off" actually works. no ghosts in the secret.
# -----------------------------------------------------------------------------
hdr "Composing secret payload"
PAYLOAD="$(jq -n \
  --arg pgHost "$TF_RDS_ADDR" \
  --arg pgPort "$TF_RDS_PORT" \
  --arg pgDb "$TF_RDS_DB" \
  --arg pgUser "$TF_RDS_USER" \
  --arg pgPass "$RDS_PASSWORD" \
  --arg redisUrl "$REDIS_URL" \
  --arg redisPass "$REDIS_AUTH" \
  --arg s3 "$TF_S3_BUCKET" \
  --arg region "$REGION" \
  --arg domain "${DOMAIN}" \
  --arg frontendUrl "${FRONTEND_URL}" \
  --arg installName "${INSTALLATION_NAME:-Chatwoot}" \
  --arg locale "${DEFAULT_LOCALE:-en}" \
  --arg railsEnv "${RAILS_ENV:-production}" \
  --arg skb "$SECRET_KEY_BASE" \
  --arg mailerSender "${MAILER_SENDER_EMAIL:-}" \
  --arg smtpAddr "${SMTP_ADDRESS:-}" \
  --arg smtpPort "${SMTP_PORT:-587}" \
  --arg smtpUser "${SMTP_USERNAME:-}" \
  --arg smtpPass "${SMTP_PASSWORD:-}" \
  --arg smtpDomain "${SMTP_DOMAIN:-}" \
  --arg sentry "${SENTRY_DSN:-}" \
  --arg ddApi "${DATADOG_API_KEY:-}" \
  --arg ddApp "${DATADOG_APP_KEY:-}" \
  --arg ddSite "${DATADOG_SITE:-}" \
  --arg scout "${SCOUT_KEY:-}" \
  --arg scoutName "${SCOUT_NAME:-}" \
  --arg maxmind "${MAXMIND_LICENSE_KEY:-}" \
  --arg rack "${ENABLE_RACK_ATTACK:-}" \
  --arg stripe "${STRIPE_SECRET_KEY:-}" \
  --arg openai "${OPENAI_API_KEY:-}" \
  --arg gOauthId "${GOOGLE_OAUTH_CLIENT_ID:-}" \
  --arg gOauthSecret "${GOOGLE_OAUTH_CLIENT_SECRET:-}" \
  --arg azureId "${AZURE_APP_ID:-}" \
  --arg azureSecret "${AZURE_APP_SECRET:-}" \
  --arg azureTenant "${AZURE_TENANT_ID:-}" \
  --arg kcIssuer "${KEYCLOAK_OIDC_ISSUER:-}" \
  --arg kcId "${KEYCLOAK_OIDC_CLIENT_ID:-}" \
  --arg kcSecret "${KEYCLOAK_OIDC_CLIENT_SECRET:-}" \
  --arg vapidPub "${VAPID_PUBLIC_KEY:-}" \
  --arg vapidPriv "${VAPID_PRIVATE_KEY:-}" \
  --arg fcm "${FCM_SERVER_KEY:-}" \
  --arg apnsKey "${APNS_KEY_ID:-}" \
  --arg apnsTeam "${APNS_TEAM_ID:-}" \
  --arg apnsAuth "${APNS_AUTH_KEY:-}" \
  '
  {
    POSTGRES_HOST: $pgHost,
    POSTGRES_PORT: $pgPort,
    POSTGRES_DATABASE: $pgDb,
    POSTGRES_USERNAME: $pgUser,
    POSTGRES_PASSWORD: $pgPass,
    REDIS_URL: $redisUrl,
    REDIS_PASSWORD: $redisPass,
    REDIS_OPENSSL_VERIFY_MODE: "none",
    S3_BUCKET_NAME: $s3,
    AWS_REGION: $region,
    ACTIVE_STORAGE_SERVICE: "amazon",
    SECRET_KEY_BASE: $skb,
    FRONTEND_URL: $frontendUrl,
    DEFAULT_LOCALE: $locale,
    INSTALLATION_NAME: $installName,
    RAILS_ENV: $railsEnv,
    MAILER_SENDER_EMAIL: $mailerSender,
    SMTP_ADDRESS: $smtpAddr,
    SMTP_PORT: $smtpPort,
    SMTP_USERNAME: $smtpUser,
    SMTP_PASSWORD: $smtpPass,
    SMTP_DOMAIN: $smtpDomain,
    SMTP_AUTHENTICATION: "plain",
    SMTP_ENABLE_STARTTLS_AUTO: "true",
    SENTRY_DSN: $sentry,
    DATADOG_API_KEY: $ddApi,
    DATADOG_APP_KEY: $ddApp,
    DATADOG_SITE: $ddSite,
    SCOUT_KEY: $scout,
    SCOUT_NAME: $scoutName,
    MAXMIND_LICENSE_KEY: $maxmind,
    ENABLE_RACK_ATTACK: $rack,
    STRIPE_SECRET_KEY: $stripe,
    OPENAI_API_KEY: $openai,
    GOOGLE_OAUTH_CLIENT_ID: $gOauthId,
    GOOGLE_OAUTH_CLIENT_SECRET: $gOauthSecret,
    AZURE_APP_ID: $azureId,
    AZURE_APP_SECRET: $azureSecret,
    AZURE_TENANT_ID: $azureTenant,
    KEYCLOAK_OIDC_ISSUER: $kcIssuer,
    KEYCLOAK_OIDC_CLIENT_ID: $kcId,
    KEYCLOAK_OIDC_CLIENT_SECRET: $kcSecret,
    VAPID_PUBLIC_KEY: $vapidPub,
    VAPID_PRIVATE_KEY: $vapidPriv,
    FCM_SERVER_KEY: $fcm,
    APNS_KEY_ID: $apnsKey,
    APNS_TEAM_ID: $apnsTeam,
    APNS_AUTH_KEY: $apnsAuth
  }
  | with_entries(select(.value != null and .value != ""))
  ')"

hdr "Writing to Secrets Manager: $TF_CHATWOOT_SECRET_NAME"
aws secretsmanager put-secret-value --region "$REGION" \
  --secret-id "$TF_CHATWOOT_SECRET_NAME" \
  --secret-string "$PAYLOAD" \
  --query 'ARN' --output text >/dev/null

KEYS_COUNT="$(echo "$PAYLOAD" | jq 'keys | length')"
printf "${GRN}Wrote ${KEYS_COUNT} keys to Secrets Manager. ESO will sync into the chatwoot namespace.${CLR}\n"
