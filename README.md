# cs-aws-cfn-customizer

Patches CrowdStrike's CloudFormation onboarding templates to use a least-privilege IAM reader role hosted in your own S3 bucket.

## What it does

1. Downloads the latest templates directly from CrowdStrike
2. Replaces the broad `SecurityAudit` managed policy with a focused 16-action policy
3. Rewrites the nested `TemplateURL` references to point at your S3 bucket
4. Optionally rewrites the Falcon console launch URL so it points at your templates
5. Optionally uploads both templates to your bucket

## Prerequisites

- `curl` and `perl` (both included on macOS, most Linux distros and AWS CloudShell)
- AWS CLI (only required for region auto-detect and uploading)
- Intended to run in **AWS CloudShell**, signed in to the management (or delegated admin) account. No local tools needed.

For the full two-person runbook (Falcon Admin + AWS Admin, quick setup, asset inventory + IOM only), see [aws-org-cfn-onboarding-guide.md](aws-org-cfn-onboarding-guide.md).

## Download

This repo is private and CloudShell has no `gh`, so pick one:

- **Upload (simplest):** on your workstation, run `gh repo clone jmckenzie-cs/cs-aws-cfn-customizer` (or download `customize-cs-templates.sh` from GitHub). In CloudShell choose **Actions > Upload file**, then:
  ```bash
  chmod +x customize-cs-templates.sh
  ```
- **Clone with a token:** use a short-lived, read-only fine-grained GitHub token scoped to this repo:
  ```bash
  git clone https://github.com/jmckenzie-cs/cs-aws-cfn-customizer.git
  cd cs-aws-cfn-customizer
  chmod +x customize-cs-templates.sh
  ```
  Enter the token as the password, then revoke it.

## Usage

```bash
chmod +x customize-cs-templates.sh
./customize-cs-templates.sh
```

The script will prompt for everything it needs. To skip prompts, use flags:

```bash
./customize-cs-templates.sh \
  --bucket <your-bucket-name> \
  --falcon-url "<url-from-falcon-console>" \
  --upload
```

### All options

| Flag | Description |
|---|---|
| `--bucket <name>` | S3 bucket name to host the templates |
| `--region <region>` | Bucket region (default: auto-detected via AWS CLI) |
| `--falcon-url <url>` | Falcon console launch URL to rewrite |
| `--falcon-url-file <path>` | File containing the Falcon launch URL (avoids terminal line-length limits) |
| `--upload` | Upload patched templates to S3 without prompting |
| `--output-dir <dir>` | Directory to write patched templates (default: current directory) |
| `--force` | Overwrite existing output files |
| `--help` | Show usage |

## Step-by-step

### 1. Create an S3 bucket

```bash
aws s3api create-bucket --bucket <your-bucket-name> --region us-east-1
```

For regions other than `us-east-1`:
```bash
aws s3api create-bucket \
  --bucket <your-bucket-name> \
  --region <region> \
  --create-bucket-configuration LocationConstraint=<region>
```

### 2. Run the script

```bash
./customize-cs-templates.sh --bucket <your-bucket-name>
```

When prompted for the Falcon console launch URL, paste the link behind **Open CloudFormation template** on the wizard's **Step 5: Deploy stack** screen (Connectors > Cloud connectors > Cloud connections > AWS > Add new account, then **Continue with quick setup**). Copy the link address; do not open it, since it points at CrowdStrike's unmodified template. The script will rewrite only the `templateURL=` parameter, preserving all other values.

> **Tip:** The Falcon URL can be very long and may exceed your terminal's paste limit. If you can't paste it interactively, save it to a text file first and use the `--falcon-url-file` flag:
> ```bash
> # Save the URL to a file (paste works fine in a text editor)
> echo "https://console.aws.amazon.com/cloudformation/..." > falcon-url.txt
>
> ./customize-cs-templates.sh --bucket <your-bucket-name> --falcon-url-file falcon-url.txt
> ```

### 3. Upload to S3

The script will ask if you want to upload. If you choose no, it prints the exact `aws s3 cp` commands to run later.

### 4. Deploy

Open the rewritten URL in a new browser tab, signed in to the same management (or delegated admin) account. It will pre-fill all parameters in the CloudFormation console, including the stack name **`CrowdStrike-Integration`**. Review, acknowledge the IAM capabilities and click **Create stack**. Once the root stack reaches `CREATE_COMPLETE`, copy **RootStackArn** and **ReaderRoleArn** from its **Outputs** tab and enter them in the Falcon wizard.

### 5. Clean up

CloudShell's home directory persists between sessions. Delete the script, the patched templates and any saved URL file (`ls` to check), and revoke any GitHub token used. Keep the S3 bucket: stack updates still reference it.

## IAM permissions granted

The patched role (`CrowdStrikeCSPMReaderRole`) receives a single inline policy with these actions:

| Service | Actions |
|---|---|
| CloudFormation | `DescribeStacks`, `DescribeStackResources`, `DescribeStackSet` |
| EC2 | `Describe*`, `GetEbsDefaultKmsKeyId`, `GetEbsEncryptionByDefault` |
| IAM | `GenerateCredentialReport`, `GenerateServiceLastAccessedDetails`, `Get*`, `List*`, `SimulateCustomPolicy`, `SimulatePrincipalPolicy` |
| Organizations | `Describe*`, `List*` |
| EventBridge | `Describe*`, `List*` |

The AWS-managed `SecurityAudit` policy and the default ~140-action inline policy are removed.

## Notes

- Only the asset inventory nested stack is repointed to your bucket. All other feature templates (DSPM, sensor management, real-time visibility) continue to resolve from CrowdStrike's hosted templates.
- The Falcon console URL may contain a client secret. Quick setup shouldn't need API credentials, but treat the link as sensitive anyway: send it through a secrets channel, not plain Slack/email, and never commit it.
- Because the guide's scope is asset inventory + IOM only, the single repointed nested stack covers the whole deployment.
- Re-run the script any time CrowdStrike updates their templates to pull the latest version and re-apply patches.
