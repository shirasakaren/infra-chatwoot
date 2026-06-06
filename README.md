# Chatwoot-TA — HA Chatwoot on AWS (Terraform + Ansible)

One-command, idempotent deployment of **Chatwoot Community** on AWS with
**High Availability** (multi-AZ EKS, Multi-AZ RDS, Redis primary+replica),
Cloudflare DNS/CDN, ACM TLS, AWS Secrets Manager + ESO, and SES outbound mail.

> Run `./deploy.sh` from your laptop. The script gates at the end of Phase 0
> for you to approve the plan and estimated cost before any billable resource
> is created. Run `./destroy.sh` to tear everything down (a final RDS snapshot
> is taken by default).

---

## Status

| Phase | Description | State |
|------:|------------|-------|
| 0 | Pre-flight, guardrails, remote state, discovery | **Implemented** |
| 1 | Network (VPC, 2 NAT, subnets, routes, SGs)      | **Implemented** |
| 2 | Platform (EKS + nodegroup + LVM-ready EBS, IAM, ECR, S3) | **Implemented** |
| 3 | Data (RDS Multi-AZ + pgvector, Redis HA, Secrets Manager) | **Implemented** |
| 4 | Edge (ACM, Cloudflare records, SES)              | **Implemented** |
| 5 | Chatwoot core (Ansible: LVM, addons, ESO, Helm)  | **Implemented** |
| 6 | Integrations (`.env`-driven, SES + optional)    | **Implemented** |
| 7 | Observability (CloudWatch + Fluent Bit + optional Datadog) | **Implemented** |
| 8 | E2E verification + finalize destroy             | **Implemented** |

The protocol (CLAUDE.md §2) builds one phase at a time, runs its validation
gate, and only continues on PASS.

---

## Architecture (target)

- **Region:** `ap-southeast-1`, 2 AZs (`1a`, `1b`).
- **Network:** new VPC (auto-selected non-overlapping CIDR), public + private
  subnets per AZ, IGW, **2 NAT gateways** for HA egress.
- **Compute:** EKS (latest stable, default 1.32) + managed nodegroup on
  AL2023 `t3.large` (min 2 / desired 2 / max 4) with cluster-autoscaler.
  Each node has a **secondary EBS volume dedicated to LVM** mounted on
  `/data`, configured by Ansible via SSM (no SSH, no bastion).
- **Containers:** Chatwoot images in **ECR**; pods orchestrated by EKS.
- **Data:** **RDS PostgreSQL 16 Multi-AZ** with `vector` (pgvector) extension;
  **ElastiCache Redis 7** primary + replica with auto-failover, TLS + auth
  token.
- **Edge / DNS / TLS:** **Cloudflare** authoritative DNS + CDN (proxied);
  origin is the **ALB** managed by the AWS Load Balancer Controller; ACM
  public cert validated via Cloudflare; SSL mode **Full (Strict)**.
- **Secrets:** **AWS Secrets Manager** + **External Secrets Operator**.
  Secret values are injected at deploy time and never land in tfstate as
  plaintext.
- **Identity:** IAM users/groups/policies (rubric: Manajemen User) + IRSA
  roles per workload (ALB controller, ESO, cluster-autoscaler, Chatwoot S3).
- **Email:** Amazon SES outbound SMTP only; domain + DKIM verified via
  Cloudflare DNS. **Inbound mail is out of scope.**
- **App:** Chatwoot Community via the official Helm chart with 2 web +
  2 Sidekiq replicas, HPA, PodDisruptionBudgets, AZ topology spread.
- **On-prem (DO NOT TOUCH):** Keycloak runs on user's Proxmox behind
  Tailscale, already publicly reachable. Chatwoot consumes it **via env
  vars only** — we never touch Proxmox/Tailscale/Keycloak config.
- **CI/CD:** GitHub Actions with **OIDC → IAM role**; PR plan, gated apply,
  Ansible lint.

### Rubric mapping

| Item | How it's satisfied |
|---|---|
| **LVM** | Ansible-over-SSM configures the secondary EBS as `vg_data/lv_data → /data` on every worker, persisted in `/etc/fstab`. |
| **Manajemen User** | Terraform-managed IAM users/groups/policies + IRSA roles. |
| **Web server** | Chatwoot Rails/Puma web pods served over HTTPS via the ALB (L7) ingress. |
| **Virtualisasi** | On-prem Proxmox (Keycloak host, referenced and untouched) + AWS EC2 (Nitro) as the EKS node substrate. |
| **Docker / Containers** | Chatwoot images in ECR, running as containers in pods. |
| **Kubernetes** | Multi-AZ EKS with managed nodegroup, HPA, ingress, add-ons. |
| **IaC** | Terraform (AWS + Cloudflare) + Ansible (nodes, Helm, verify). |
| **High Availability** | 2 AZs, 2 NAT GWs, ≥2 web + ≥2 Sidekiq with HPA/PDB/topology spread, RDS Multi-AZ, ElastiCache primary+replica with auto-failover, cluster-autoscaler. |

---

## Usage

### Prerequisites

Install locally:

- `terraform >= 1.6`, `ansible >= 2.15`, `kubectl >= 1.28`, `helm >= 3.13`,
  `aws >= 2.13`, `jq >= 1.6`
- `session-manager-plugin` (AWS SSM)
- An AWS profile with admin-equivalent access in `ap-southeast-1`
- A Cloudflare API token scoped to `labmgm.org` (`Zone.Zone:Read` +
  `Zone.DNS:Edit`)

### First run

```bash
cp .env.example .env
# Fill in OWNER, CLOUDFLARE_API_TOKEN, GITHUB_OWNER, GITHUB_REPO (others optional)
./deploy.sh
```

The script will:

1. Run preflight (tools, .env, AWS, Cloudflare, quotas).
2. Bootstrap the remote state backend (S3 + DynamoDB).
3. `terraform init` the main stack against that backend.
4. Run **Phase 0 discovery** — read-only inventory of pre-existing VPCs/EKS
   clusters/Route 53 zones in the account.
5. Auto-select a non-overlapping VPC CIDR from `10.42.0.0/16 …`.
6. Print the do-not-touch summary, selected CIDR, and rough cost.
7. **Pause for typed approval (`proceed`)** before any Phase 1+ work.

### Teardown

```bash
./destroy.sh                  # drains ALBs, takes final RDS snapshot, destroys main stack
./destroy.sh --purge-state    # also removes the bootstrap state bucket + lock table
./destroy.sh --skip-snapshot  # skip the final RDS snapshot (NOT recommended)
```

A destroy removes RDS/ElastiCache, so **app data does not persist across
teardowns** — restore from the final snapshot if you redeploy.

### Cost

Rough estimate while everything is running: **~US$0.6–0.9/hour**
(~US$4–6 for a 5-hour demo). If left on 24/7, **~US$350–500/month**.
The deploy/demo/destroy pattern is the intended lifecycle.

---

## Shared-account guardrails (additive only)

This project is designed for a **shared AWS account with pre-existing
infrastructure**. The protocol is strict:

- Phase 0 runs read-only discovery and writes
  `terraform/discovery/do-not-touch.json`.
- All new resources get a fresh, non-overlapping CIDR and a unique
  `${NAME_PREFIX}` prefix, plus tags `Project=chatwoot-ta`,
  `ManagedBy=terraform`, `Environment=ta`, `Owner=${OWNER}`.
- Terraform state is **isolated** to this project (dedicated S3 backend),
  so `terraform destroy` only ever touches this project's resources.
- If a CIDR or name collides with something pre-existing, deploy.sh **stops**
  rather than reusing or overwriting.

---

## Integration caveats

- **Keycloak (OIDC):** Chatwoot Community has limited native SSO. We wire
  the OIDC env vars Chatwoot supports; full SSO/SCIM is an Enterprise
  feature. Document the limitation rather than pretending it's seamless.
- **MaxMind GeoIP:** requires a free GeoLite2 account + license key in
  `.env`. Skipped if absent.
- **Mobile push (FCM/APNS):** server-side only and only when keys are
  present. Web push (VAPID) keys are auto-generated.
- **SES:** account starts in **sandbox** — fine for "infra up" and demos
  to verified addresses; production sending requires a separate AWS
  approval request.
- **Social channels:** Facebook, Instagram, Twitter/X, Slack are
  intentionally **disabled** (env keys present but blank) by request.

---

## Repository layout

See `CLAUDE.md` §5 for the full intended layout. Phase 0 files now in place:

```
deploy.sh               # entrypoint; Phase 0 implemented, Phase 1+ stubs follow
destroy.sh              # safe teardown
.env.example            # comprehensive, commented
.gitignore
scripts/preflight.sh    # tools + auth + quotas
bootstrap/              # local-state TF -> S3 state bucket + DynamoDB lock
terraform/
  versions.tf
  providers.tf
  backend.tf
  variables.tf
  outputs.tf
  00-discovery.tf       # read-only inventory + non-overlapping CIDR picker
  discovery/            # do-not-touch.json (generated)
ansible/                # playbooks/templates land in Phase 5
.github/workflows/      # plan/apply/lint land alongside Phase 1+
```
