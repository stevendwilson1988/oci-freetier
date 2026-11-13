# OCI Free Tier Tenancy

This repo holds scripts that manage an Oracle Cloud Infrastructure (OCI) tenancy.

## The rule: never cost money

The tenancy must stay within Oracle's **Always Free** limits. **No charges, ever.** Every script, change and recommendation in this repo has to meet that rule. When cost and convenience conflict, cost wins.

## Always Free limits (per tenancy, home region)

Check these against Oracle's current list before relying on them, because Oracle changes it:
https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm

| Resource | Always Free limit |
|---|---|
| Ampere A1 compute (`VM.Standard.A1.Flex`) | 4 OCPUs + 24 GB RAM **total across all A1 instances** |
| AMD compute (`VM.Standard.E2.1.Micro`) | 2 instances (1/8 OCPU, 1 GB RAM each) |
| Block + boot volume storage | 200 GB **combined**, 5 volume backups |
| Object Storage | 20 GB combined across all tiers |
| Autonomous Database | 2 instances (Always Free option) |
| Load balancer | 1 flexible LB at 10 Mbps; 1 network load balancer |
| VCNs | 2 |
| Outbound data transfer | 10 TB / month |

## Rules for scripts

1. **Only use Always Free shapes and options.** Use no other compute shapes, no GPU, no paid DB editions and no LB bandwidth over 10 Mbps. Don't raise boot volume performance above the default (Balanced/10 VPU). Don't create paid add-ons such as WAF, extra backups or Data Safe.
2. **Check usage before creating anything.** A script that creates a resource must first count what already exists (for example, total A1 OCPUs and memory, total volume GB, VCN count) and stop if the new resource would push past a limit. Running a script twice must never double the resources.
3. **Prefer idempotent scripts.** Reuse existing resources (for example, a VCN with the same display name) instead of creating duplicates.
4. **Pin sizes explicitly.** Set OCPUs, memory and boot volume size explicitly; don't rely on defaults that Oracle could change.
5. **Clean up completely.** Teardown scripts must also delete boot volumes and backups. Terminating an instance can leave its boot volume behind, and that volume still counts toward the 200 GB.
6. **When in doubt, don't.** If you can't confirm that a resource or option is Always Free, don't create it. Flag it and ask.

## Ask before

- Any change that could incur a charge, even a small one.
- Upgrading the account to Pay As You Go. Don't upgrade: the Free Tier account is the hard guarantee against billing.
- Destructive operations: terminating instances, deleting volumes, VCNs or buckets.
- Changing IAM policies, budgets or compartment quotas.

## Safeguards outside this repo

- Keep the account on **Free Tier**, not Pay As You Go.
- If the account is ever upgraded: create a **budget with an alert** (for example $1) and **compartment quotas** that cap usage at Always Free levels. Quotas are enforced by OCI; this file is not.

## Repo conventions

- Bash plus `oci` CLI plus `jq`. Scripts use `set -euo pipefail`.
- Never commit credentials. `.gitignore` excludes keys and `config`.
