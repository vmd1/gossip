#!/bin/bash
# Uploads the Gossip signing certificate (see create-signing-cert.sh) to GitHub as secrets of the `release`
# environment, and restricts that environment to the `main` branch.
#
# Why an environment: this repo is public. Secrets in a plain repository secret are readable by any workflow
# on any branch (anyone who can push a branch could print the key). An environment limited to `main` is only
# readable by jobs running on `main` that declare `environment: release`, so PR workflows, fork PRs and
# feature branches never see the key. Whoever holds the key can sign an app that inherits users'
# Accessibility / Input Monitoring grants, so treat it as sensitive.
#
#   set-ci-signing-secrets.sh [owner/repo]       (needs `gh` authenticated with admin rights on the repo)
#
# Secrets are streamed from files to `gh` (never put on a command line or echoed).
set -euo pipefail

NAME="gossip.vmd1.dev"
STORE="${GOSSIP_SIGNING_DIR:-$HOME/.gossip-signing}"
P12="$STORE/$NAME.p12"
PASSFILE="$STORE/$NAME.password"
ENVIRONMENT="release"
REPO="${1:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}"

[ -f "$P12" ] && [ -f "$PASSFILE" ] || { echo "Missing $P12 / $PASSFILE: run create-signing-cert.sh first." >&2; exit 1; }

# Environment limited to the main branch (idempotent).
gh api -X PUT "repos/$REPO/environments/$ENVIRONMENT" \
  -F "deployment_branch_policy[protected_branches]=false" \
  -F "deployment_branch_policy[custom_branch_policies]=true" >/dev/null
existing="$(gh api "repos/$REPO/environments/$ENVIRONMENT/deployment-branch-policies" -q '.branch_policies[].name' || true)"
if ! grep -qx "main" <<<"$existing"; then
  gh api -X POST "repos/$REPO/environments/$ENVIRONMENT/deployment-branch-policies" -f name=main -f type=branch >/dev/null
fi

base64 < "$P12" | tr -d '\n' | gh secret set SIGNING_CERT_P12_BASE64 --env "$ENVIRONMENT" --repo "$REPO"
gh secret set SIGNING_CERT_PASSWORD --env "$ENVIRONMENT" --repo "$REPO" < "$PASSFILE"

echo "Environment \"$ENVIRONMENT\" on $REPO is restricted to: $(gh api "repos/$REPO/environments/$ENVIRONMENT/deployment-branch-policies" -q '[.branch_policies[].name]|join(", ")')"
echo "Secrets set: $(gh secret list --env "$ENVIRONMENT" --repo "$REPO" | awk '{print $1}' | tr '\n' ' ')"
