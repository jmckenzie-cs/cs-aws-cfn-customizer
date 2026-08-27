#!/usr/bin/env bash
set -euo pipefail

# ══════════════════════════════════════════════════════════════════════════════
# customize-cs-templates.sh
#
# Downloads CrowdStrike's CloudFormation onboarding templates and patches them
# to use a least-privilege IAM reader role hosted in your own S3 bucket.
#
# Usage:
#   ./customize-cs-templates.sh [OPTIONS]
#
# Options:
#   --bucket <name>          S3 bucket name to host the templates
#   --region <region>        Bucket region (default: auto-detect via AWS CLI)
#   --falcon-url <url>       Falcon console launch URL to rewrite
#   --falcon-url-file <path> File containing the Falcon launch URL (avoids shell line-length limits)
#   --upload                 Upload patched templates to S3 without prompting
#   --output-dir <dir>       Directory to write patched templates (default: .)
#   --force                  Overwrite existing output files
#   --help                   Show this help
# ══════════════════════════════════════════════════════════════════════════════

# ── Constants ─────────────────────────────────────────────────────────────────
CS_BASE_URL="https://cs-prod-cloudconnect-templates-use1-4721cdb0.s3.amazonaws.com/modular"
ROOT_TEMPLATE="cs_aws_root.yaml"
INVENTORY_TEMPLATE="cs_aws_asset_inventory-1.3.yaml"

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; BOLD='\033[1m'; RESET='\033[0m'
err()  { echo -e "${RED}ERROR:${RESET} $*" >&2; }
warn() { echo -e "${YELLOW}WARN:${RESET}  $*" >&2; }
ok()   { echo -e "${GREEN}OK:${RESET}    $*"; }
info() { echo -e "${BOLD}$*${RESET}"; }

# ── Defaults ──────────────────────────────────────────────────────────────────
BUCKET=""
REGION=""
FALCON_URL=""
FALCON_URL_FILE=""
DO_UPLOAD=""
OUTPUT_DIR="."
FORCE=false

# ── Arg parsing ───────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --bucket)          BUCKET="$2";          shift 2 ;;
    --region)          REGION="$2";          shift 2 ;;
    --falcon-url)      FALCON_URL="$2";      shift 2 ;;
    --falcon-url-file) FALCON_URL_FILE="$2"; shift 2 ;;
    --upload)          DO_UPLOAD=true;       shift   ;;
    --output-dir)      OUTPUT_DIR="$2";      shift 2 ;;
    --force)           FORCE=true;           shift   ;;
    --help)
      sed -n '/^# Usage:/,/^# ══/p' "$0" | grep -v '^# ══' | sed 's/^# //'
      exit 0 ;;
    *) err "Unknown option: $1"; exit 1 ;;
  esac
done

# ── Helpers ───────────────────────────────────────────────────────────────────
require_cmd() {
  command -v "$1" &>/dev/null || { err "Required command not found: $1"; exit 1; }
}

count_pattern() {
  # count non-overlapping occurrences of pattern in file
  perl -0777 -ne "my \$c=()= /$(echo "$1")/gm; print \$c" "$2"
}

assert_count() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$actual" -ne "$expected" ]]; then
    err "Expected $expected substitution(s) for '$label', got $actual."
    err "CrowdStrike may have updated the template structure. Review manually."
    exit 1
  fi
}

# ── Step 1: Bucket name ───────────────────────────────────────────────────────
echo
info "── CrowdStrike Template Customizer ──────────────────────────────────────"
echo

if [[ -z "$BUCKET" ]]; then
  read -rp "Enter your S3 bucket name: " BUCKET
fi
[[ -n "$BUCKET" ]] || { err "Bucket name cannot be empty."; exit 1; }

# ── Step 2: Region auto-detect ────────────────────────────────────────────────
if [[ -z "$REGION" ]]; then
  if command -v aws &>/dev/null; then
    raw=$(aws s3api get-bucket-location --bucket "$BUCKET" 2>/dev/null \
          | grep -o '"[a-z0-9-]*"' | tr -d '"' || true)
    if [[ -z "$raw" || "$raw" == "null" ]]; then
      REGION="us-east-1"
      ok "Bucket region detected: $REGION"
    else
      REGION="$raw"
      ok "Bucket region detected: $REGION"
    fi
  else
    warn "AWS CLI not found — cannot auto-detect bucket region."
    read -rp "Enter bucket region [us-east-1]: " REGION
    REGION="${REGION:-us-east-1}"
  fi
fi

BUCKET_URL="https://${BUCKET}.s3.${REGION}.amazonaws.com"
INVENTORY_URL="${BUCKET_URL}/${INVENTORY_TEMPLATE}"
ROOT_URL="${BUCKET_URL}/${ROOT_TEMPLATE}"

info "Bucket URL: $BUCKET_URL"

# ── Step 3: Download templates ────────────────────────────────────────────────
require_cmd curl
require_cmd perl

mkdir -p "$OUTPUT_DIR"

ROOT_OUT="${OUTPUT_DIR}/${ROOT_TEMPLATE}"
INVENTORY_OUT="${OUTPUT_DIR}/${INVENTORY_TEMPLATE}"

for f in "$ROOT_OUT" "$INVENTORY_OUT"; do
  if [[ -f "$f" ]] && [[ "$FORCE" != true ]]; then
    err "File already exists: $f  (use --force to overwrite)"
    exit 1
  fi
done

echo
info "── Downloading templates from CrowdStrike ───────────────────────────────"

for tmpl in "$ROOT_TEMPLATE" "$INVENTORY_TEMPLATE"; do
  out="${OUTPUT_DIR}/${tmpl}"
  echo "  Fetching $tmpl ..."
  curl -fsSL "${CS_BASE_URL}/${tmpl}" -o "$out"
  # Guard against AccessDenied XML or other non-YAML responses
  if ! grep -q "^AWSTemplateFormatVersion" "$out"; then
    err "$tmpl does not appear to be a valid CloudFormation template."
    err "First bytes: $(head -c 120 "$out")"
    rm -f "$out"
    exit 1
  fi
  ok "$tmpl downloaded"
done

# ── Step 4: Patch cs_aws_root.yaml ───────────────────────────────────────────
echo
info "── Patching $ROOT_TEMPLATE ─────────────────────────────────────────────"

# 4a. Repoint the two asset-inventory TemplateURL !Sub blocks to the customer bucket.
#     Each block is uniquely identified by the trailing AssetInventoryVersion: line.
REPLACEMENT="      TemplateURL: ${INVENTORY_URL}"

# Pass the replacement as an env var so special chars in the URL don't
# interfere with Perl's regex delimiter or string interpolation.
patched_root=$(REPL="$REPLACEMENT" perl -0777 -pe \
  's/[ ]+TemplateURL: !Sub\n[ ]+# Use region-specific bucket URLs\n[ ]+-[^\n]*\n(?:[ ]+[^\n]*\n)*?[ ]+AssetInventoryVersion: "[^"]*"\n/$ENV{REPL}\n/g' \
  "$ROOT_OUT")

actual=$(echo "$patched_root" | grep -c "TemplateURL: ${INVENTORY_URL}" || true)
assert_count "asset-inventory TemplateURL" 2 "$actual"
echo "$patched_root" > "$ROOT_OUT"
ok "Replaced $actual TemplateURL blocks"

# Sanity: other TemplateURL !Sub blocks must still be present
remaining=$(grep -c "TemplateURL: !Sub" "$ROOT_OUT" || true)
if [[ "$remaining" -lt 10 ]]; then
  err "Unexpected: only $remaining 'TemplateURL: !Sub' blocks remain (expected ≥10)."
  err "Other feature templates may have been accidentally modified."
  exit 1
fi
ok "$remaining other TemplateURL blocks untouched"

# 4b. Add Default for RoleName so the console field pre-fills.
if grep -q "^  RoleName:" "$ROOT_OUT" && ! grep -q "Default: 'CrowdStrikeCSPMReaderRole'" "$ROOT_OUT"; then
  perl -i -0777 -pe \
    "s|(  RoleName:\n    Description:[^\n]*\n    Type: String)|\$1\n    Default: 'CrowdStrikeCSPMReaderRole'|m" \
    "$ROOT_OUT"
  ok "Added RoleName default"
fi

# ── Step 5: Patch cs_aws_asset_inventory-1.3.yaml ────────────────────────────
echo
info "── Patching $INVENTORY_TEMPLATE ────────────────────────────────────────"

# Embedded least-privilege policy block (indentation matches the upstream file).
# Note: defined as a literal string (not heredoc) to preserve leading whitespace.
POLICY_BLOCK='      Policies:
        - PolicyDocument:
            Version: '"'"'2012-10-17'"'"'
            Statement:
              - Effect: Allow
                Resource: '"'"'*'"'"'
                Action:
                  - cloudformation:DescribeStacks
                  - cloudformation:DescribeStackResources
                  - cloudformation:DescribeStackSet
                  - ec2:Describe*
                  - ec2:GetEbsDefaultKmsKeyId
                  - ec2:GetEbsEncryptionByDefault
                  - iam:GenerateCredentialReport
                  - iam:GenerateServiceLastAccessedDetails
                  - iam:Get*
                  - iam:List*
                  - iam:SimulateCustomPolicy
                  - iam:SimulatePrincipalPolicy
                  - organizations:Describe*
                  - organizations:List*
                  - events:Describe*
                  - events:List*
                  - ssm:DescribeInstanceInformation
                  - ssm:GetInventory
                  - ssm:ListInventoryEntries
          PolicyName: cspm_least_privilege'

# Replace from ManagedPolicyArns: through PolicyName: cspm_config (inclusive).
patched_inv=$(REPL="$POLICY_BLOCK" perl -0777 -pe \
  's/[ ]+ManagedPolicyArns:\n(?:.*\n)*?[ ]+PolicyName: cspm_config\n/$ENV{REPL}\n/m' \
  "$INVENTORY_OUT")

actual_inv=$(echo "$patched_inv" | grep -c "PolicyName: cspm_least_privilege" || true)
assert_count "cspm_least_privilege policy" 1 "$actual_inv"

if echo "$patched_inv" | grep -q "SecurityAudit\|cspm_config"; then
  err "Original policy artefacts still present after patch — aborting."
  exit 1
fi

echo "$patched_inv" > "$INVENTORY_OUT"
ok "Removed SecurityAudit managed policy + cspm_config inline policy"
ok "Inserted cspm_least_privilege policy (19 actions)"

# ── Step 6: Falcon URL rewrite ────────────────────────────────────────────────
echo
info "── Falcon Console Launch URL ────────────────────────────────────────────"

# Load from file if provided (avoids shell line-length limits when pasting long URLs)
if [[ -n "$FALCON_URL_FILE" ]]; then
  [[ -f "$FALCON_URL_FILE" ]] || { err "File not found: $FALCON_URL_FILE"; exit 1; }
  FALCON_URL=$(tr -d '[:space:]' < "$FALCON_URL_FILE")
fi

if [[ -z "$FALCON_URL" ]]; then
  echo "  Paste the launch URL from the Falcon console onboarding workflow."
  echo "  TIP: If the URL is too long to paste, save it to a file and use:"
  echo "       --falcon-url-file <path>"
  echo "  Press Enter to skip."
  read -rp "  URL: " FALCON_URL
fi

REWRITTEN_URL=""
if [[ -n "$FALCON_URL" ]]; then
  REWRITTEN_URL=$(echo "$FALCON_URL" | sed "s|templateURL=[^&#]*|templateURL=${ROOT_URL}|")
  echo
  ok "Rewritten URL (only templateURL= was changed):"
  echo
  echo "  $REWRITTEN_URL"
  echo
  warn "This URL may contain your Falcon client secret — do not share it publicly."
fi

# ── Step 7: Upload (opt-in) ───────────────────────────────────────────────────
echo
info "── Upload to S3 ─────────────────────────────────────────────────────────"

if [[ -z "$DO_UPLOAD" ]]; then
  read -rp "Upload patched templates to s3://${BUCKET}/ now? [y/N]: " ans
  [[ "$(echo "$ans" | tr '[:upper:]' '[:lower:]')" == "y" ]] && DO_UPLOAD=true || DO_UPLOAD=false
fi

if [[ "$DO_UPLOAD" == true ]]; then
  require_cmd aws
  echo "  Uploading $INVENTORY_TEMPLATE ..."
  aws s3 cp "$INVENTORY_OUT" "s3://${BUCKET}/${INVENTORY_TEMPLATE}"
  ok "Uploaded $INVENTORY_TEMPLATE"
  echo "  Uploading $ROOT_TEMPLATE ..."
  aws s3 cp "$ROOT_OUT" "s3://${BUCKET}/${ROOT_TEMPLATE}"
  ok "Uploaded $ROOT_TEMPLATE"
else
  echo "  Skipped. Run these commands when ready:"
  echo
  echo "    aws s3 cp ${INVENTORY_OUT} s3://${BUCKET}/${INVENTORY_TEMPLATE}"
  echo "    aws s3 cp ${ROOT_OUT} s3://${BUCKET}/${ROOT_TEMPLATE}"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo
info "── Summary ──────────────────────────────────────────────────────────────"
echo "  Bucket:    s3://${BUCKET}  (region: ${REGION})"
echo "  Templates: ${OUTPUT_DIR}/${ROOT_TEMPLATE}"
echo "             ${OUTPUT_DIR}/${INVENTORY_TEMPLATE}"
echo "  Uploaded:  ${DO_UPLOAD}"
if [[ -n "$REWRITTEN_URL" ]]; then
  echo "  Launch URL: ready (printed above)"
fi
echo
