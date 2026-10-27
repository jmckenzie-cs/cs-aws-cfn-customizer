# AWS Organization Onboarding to CrowdStrike Falcon Cloud Security
## Asset inventory + IOM only, CloudFormation + least-privilege template customizer (two-person runbook)

Scope: **quick setup only.** Asset inventory and IOM assessments. No real-time visibility, DSPM, vulnerability scanning, 1-click sensor deployment, or IDP.

Sources:
- CrowdStrike docs: "Prepare for AWS Registration" and "Register an AWS Organization Using CloudFormation"
- https://github.com/jmckenzie-cs/cs-aws-cfn-customizer (README and `customize-cs-templates.sh`)

## Roles

| Role | Works in | Owns |
|---|---|---|
| **Falcon Admin** | Falcon console | Registration wizard, final validation |
| **AWS Admin** | AWS console + CLI | S3 bucket, template customization, stack deployment |

Two handoffs:
- **Handoff A (Falcon -> AWS):** the Falcon registration link, used only as input to the customizer script. The AWS Admin must not open it.
- **Handoff B (AWS -> Falcon):** `RootStackArn` and `ReaderRoleArn`.

> **Security note:** The customizer README warns the Falcon link may contain a client secret. Quick setup shouldn't need API credentials, but treat the link as sensitive anyway: send it through a secrets channel, not plain Slack/email, and never commit it.

Because only asset inventory is enabled, the customizer's caveat (it repoints only the asset inventory nested stack) does not limit you here. The whole deployment uses the patched template.

---

## Phase 0: Planning (both, ~15 min)

### 0.1 Decisions to record

| Decision | Notes |
|---|---|
| Registration scope | Whole org (root ID `r-xxxx`) or specific OUs (`ou-xxxx-xxxxxxxx,ou-...`, child OUs included) |
| Deploy from | Management account, or delegated admin (the management account is then **not** monitored) |
| Setup type | **Quick setup** (fixed) |
| Template source region | Default `us-east-1`. Change only if SCPs block it |

### 0.2 Falcon-side prerequisites (Falcon Admin)
- Active Falcon Cloud Security subscription.
- Falcon role that can register accounts: Falcon Administrator, Cloud Security Manager, or CSPM Manager.

### 0.3 AWS-side prerequisites (AWS Admin)
- [ ] Organization ID (`o-...`)
- [ ] Management (or delegated admin) account ID
- [ ] Root ID (`r-...`) or list of OU IDs
- [ ] **CloudFormation StackSets trusted access** enabled with AWS Organizations
- [ ] If using a delegated admin: registered as delegated administrator for CloudFormation StackSets
- [ ] Permissions to create stacks, StackSets, IAM roles and S3 buckets in the deployment account
- [ ] No accounts in the org already registered individually (deprovision them first; an org can be registered to only one CID)
- [ ] If SCPs block regions: allow these IAM calls to us-east-1 for the reader role: `iam:ListAttachedRolePolicies`, `GetRolePolicy`, `GetPolicy`, `ListAccountAliases`, `ListRolePolicies`, `GetPolicyVersion`
- [ ] If you restrict by IP: add CrowdStrike IP ranges to allowlists
- [ ] Everything runs in **AWS CloudShell** (no local tools needed). It provides `aws`, `curl`, `perl`. A copy of the script from the private repo (see Phase 1 step 3)

---

## Phase 1: Prepare template hosting (AWS Admin, can start immediately)

1. Sign in to the AWS console as the **management (or delegated admin) account**, in the region where you'll deploy, and open **AWS CloudShell** (terminal icon in the top bar). It runs with your console credentials; no CLI setup needed. Confirm identity:
   ```bash
   aws sts get-caller-identity
   ```
   CloudShell has `aws`, `curl`, `perl` and `git`, but not `gh`. It also creates the bucket in whatever region CloudShell is running in unless you pass `--region`.
2. Create the S3 bucket for the patched templates.
   - us-east-1:
     ```bash
     aws s3api create-bucket --bucket <your-bucket-name> --region us-east-1
     ```
   - Other regions:
     ```bash
     aws s3api create-bucket --bucket <your-bucket-name> --region <region> \
       --create-bucket-configuration LocationConstraint=<region>
     ```
   - Keep Block Public Access on. The deploying principal needs `s3:GetObject` on the bucket (inferred from how CloudFormation works, not from the README; verify in Phase 3). Pick a region your SCPs allow.
3. Get the script into CloudShell. The repo is private and CloudShell has no `gh`, so pick one:
   - **Upload (simplest):** on your workstation, download `customize-cs-templates.sh` (`gh repo clone jmckenzie-cs/cs-aws-cfn-customizer`, or download the file from GitHub). In CloudShell choose **Actions > Upload file** and select it. Then:
     ```bash
     chmod +x customize-cs-templates.sh
     ```
   - **Clone with a token:** use a short-lived, read-only fine-grained GitHub token scoped to this repo (`git clone https://github.com/jmckenzie-cs/cs-aws-cfn-customizer.git`, enter the token as the password), then revoke the token. Run `cd cs-aws-cfn-customizer` and `chmod +x customize-cs-templates.sh`.

What the script does: downloads the latest CrowdStrike templates, replaces the `SecurityAudit` managed policy and ~140-action inline policy on `CrowdStrikeCSPMReaderRole` with a 16-action inline policy, rewrites nested `TemplateURL`s to your bucket, rewrites the launch URL's `templateURL=`, and optionally uploads.

Resulting reader role permissions (for your security review):

| Service | Actions |
|---|---|
| CloudFormation | `DescribeStacks`, `DescribeStackResources`, `DescribeStackSet` |
| EC2 | `Describe*`, `GetEbsDefaultKmsKeyId`, `GetEbsEncryptionByDefault` |
| IAM | `GenerateCredentialReport`, `GenerateServiceLastAccessedDetails`, `Get*`, `List*`, `SimulateCustomPolicy`, `SimulatePrincipalPolicy` |
| Organizations | `Describe*`, `List*` |
| EventBridge | `Describe*`, `List*` |

> This is narrower than the default role. If IOM assessments later report access-denied for a service, compare the denied action against this list. Re-run the script when CrowdStrike updates its templates.

---

## Phase 2: Run the registration wizard (Falcon Admin)

1. Go to **Connectors > Cloud connectors > Cloud connections**, open the **AWS** tab, click **Add new account**. (**Save and exit** is available at any point; resume via **Setup incomplete**.)
2. **Step 1: Registration parameters**
   - (US-GOV-1 only) choose AWS GovCloud or Commercial.
   - Select **AWS Organization**.
   - Enter the **Organization ID**, the **management or delegated admin account ID** (tick **This is a delegated admin account** if applicable), and the **root ID or OU list**. The AWS Admin supplies these values.
   - Deployment method: **CloudFormation template**.
   - Click **Continue with quick setup**. This skips the feature, advanced settings and API credential steps and goes straight to Step 5.
3. **Step 5: Deploy stack** screen.
   - Do not click through to deploy. Copy the link behind **Open CloudFormation template** (right-click > Copy link address) to send to the AWS Admin. Neither of you should open it: it points at CrowdStrike's unmodified template.
   - Leave the wizard open (or Save and exit). You'll return to it in Phase 4.

> Quick setup uses the default role. Do not look for a "use existing role" option: the customizer patches the default `CrowdStrikeCSPMReaderRole` in the template, so you don't need a custom one.

### Handoff A (Falcon -> AWS), via secrets channel
- [ ] Falcon registration link (copied from **Open CloudFormation template**), shared as text through a secrets channel. It is only pasted into the script; the AWS Admin does not open it. The AWS Admin just needs to be signed in to the management (or delegated admin) account
- [ ] Confirmation of org ID / scope entered, so both sides match
- [ ] Note that the wizard is waiting on `RootStackArn` and `ReaderRoleArn`

---

## Phase 3: Customize and deploy (AWS Admin)

1. In CloudShell (signed in to the management or delegated admin account), run the customizer with just the bucket name:
   ```bash
   ./customize-cs-templates.sh --bucket <your-bucket-name>
   ```
2. When prompted, paste the Falcon link (no quoting needed). Answer yes when asked whether to upload to S3.
   - `--region` is optional: the script auto-detects the bucket region with the AWS CLI. `--output-dir` defaults to the current directory, and `--force` is only needed to overwrite existing output files.
   - Only `templateURL=` is rewritten; other parameters are preserved.
   - If the pasted link gets cut off (a terminal line-length limit the README warns about), save it to a file and use `--falcon-url-file <file>` instead, then delete the file in Cleanup.
   - The script prints a new, rewritten link. Copy that one from the terminal and open it in a new browser tab. This is the only link opened in AWS. Patched templates are written to the current directory; delete them in Cleanup.
3. Verify before deploying:
   - Templates are in the bucket: `aws s3 ls s3://<your-bucket-name>/`
   - The rewritten URL's `templateURL=` points at your bucket.
   - The patched reader role has only the 16-action inline policy and no `SecurityAudit`. Get security sign-off if needed.
4. In a new browser tab, signed in to the same management (or delegated admin) account, open the rewritten URL.
   - Keep stack name `CrowdStrike-Integration`.
   - Optionally add tags (up to 50).
   - Review the remaining parameters, acknowledge the IAM capabilities, click **Create stack**.
5. Wait for `CREATE_COMPLETE` on the root stack. Check the StackSets console for per-account instance status.
6. On the root stack's **Outputs** tab, copy **RootStackArn** and **ReaderRoleArn**.

### Handoff B (AWS -> Falcon)
- [ ] `RootStackArn`
- [ ] `ReaderRoleArn`

### Cleanup
- In CloudShell, delete the script and the patched templates it wrote to the current directory (check with `ls`). CloudShell's home directory persists between sessions, so don't leave them there. Revoke any GitHub token used.
- Scrub the URL from chat/tickets.
- Keep the S3 bucket; stack updates still reference it.

---

## Phase 4: Finish registration (Falcon Admin)

1. Return to the wizard's Step 5 screen.
2. Enter **ReaderRoleArn** and **RootStackArn**.
3. Click **Validate and complete**.

## Phase 5: Verify (both)

Falcon Admin:
- On the **AWS** tab, the management account and member accounts should start appearing with **Assets** (and IOM) **Active**. This can take several minutes.
- **Cloud security > Assets > Explorer > Assets explorer**, expand AWS under Provider.

AWS Admin:
- StackSet instances are `CURRENT` across target accounts/OUs.
- Spot-check a member account: `CrowdStrikeCSPMReaderRole` exists with only the 16-action inline policy.

New accounts added to the org/OUs register automatically.

---

## Troubleshooting

| Symptom | Likely cause / action |
|---|---|
| Template can't be retrieved at stack creation | Deploying principal lacks `s3:GetObject`, or the bucket region is blocked by an SCP |
| Can't get the repo in CloudShell | Private repo and no `gh`: use Actions > Upload file, or a read-only token |
| Pasted link truncated at the prompt | Save it to a file and use `--falcon-url-file` |
| Bucket created in wrong region | CloudShell defaults to its own region; pass `--region` explicitly |
| StackSet failure | Trusted access not enabled, or not signed in to the management/delegated admin account |
| Access-denied findings in assessments | Reader role is narrower than default; compare against the 16-action list |
| CrowdStrike releases new templates | Re-run the customizer, re-upload, and update the stack |

## Adding features later
Not in scope now. CrowdStrike's "Troubleshooting and Maintenance for AWS Accounts" doc covers adding features after registration. Note that features beyond asset inventory pull templates CrowdStrike hosts, outside the customizer's reach.

## Open items to verify before the first real run
- The flags and behavior above were checked against `customize-cs-templates.sh`.
- Confirm with CrowdStrike that running a patched template is supported for your environment.
- Confirm the bucket-read behavior (Phase 1) in a test deployment.
