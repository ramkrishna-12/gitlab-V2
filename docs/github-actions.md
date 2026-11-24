# GitHub Actions setup

Two workflows live in `.github/workflows/`:

| Workflow | Trigger | Needs AWS? | What it does |
|---|---|---|---|
| `ci.yml` | every push to `main`, every PR | No | shellcheck, `terraform fmt`/`validate`, Trivy IaC scan (HIGH/CRITICAL), gitleaks over full history, sample-app lint/test/build, yamllint + actionlint. `ci-ok` is the single check to require. |
| `terraform-deploy.yml` | PR touching `terraform/` or `vpn/`; manual run | Yes (OIDC) | PR: `terraform plan` shown in the run summary. Manual: `plan`, `apply` or `destroy`; apply/destroy wait for approval and apply exactly the reviewed plan. |

`ci.yml` works the moment you push. `terraform-deploy.yml` is **skipped, not failed,** until the variables below exist.

## 1. Remote state first (do not skip)
CI must not apply against local state: a runner is thrown away after every run, so Terraform would forget what it built and try to create it all again. Create a state bucket once, by hand:
```bash
BUCKET=tfstate-gitlab-lab-<ACCOUNT_ID>-ap-south-1
aws s3api create-bucket --bucket "$BUCKET" --region ap-south-1 \
  --create-bucket-configuration LocationConstraint=ap-south-1
aws s3api put-bucket-versioning --bucket "$BUCKET" --versioning-configuration Status=Enabled
aws s3api put-public-access-block --bucket "$BUCKET" --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
```
If you already ran `terraform apply` locally, migrate that state: copy `terraform/backend.tf.example` to `terraform/backend_override.tf`, fill in the bucket, run `terraform init -migrate-state`. If you did not, there is nothing to migrate.

## 2. GitHub OIDC -> AWS (no stored AWS keys)
```bash
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com --client-id-list sts.amazonaws.com
```
(An account can have this provider only once; "EntityAlreadyExists" means it is already there.)

Create **two** roles, so a pull request can never change infrastructure:

| Role | Trusted for (`sub` claim) | Permissions |
|---|---|---|
| `gha-tf-plan` | `repo:<OWNER>/<REPO>:pull_request` and `repo:<OWNER>/<REPO>:ref:refs/heads/main` | AWS managed `ReadOnlyAccess` + read/write on the state bucket (plan takes the state lock) |
| `gha-tf-apply` | `repo:<OWNER>/<REPO>:environment:production` only | What this Terraform creates: EC2, VPC, IAM role/instance profile for gitlab, S3 bucket, plus the state bucket. This is broad; scope it down as far as you can and never reuse it elsewhere. |

Trust policy for `gha-tf-apply` (for `gha-tf-plan` change the `sub` list):
```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Federated": "arn:aws:iam::<ACCOUNT_ID>:oidc-provider/token.actions.githubusercontent.com" },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": { "token.actions.githubusercontent.com:aud": "sts.amazonaws.com" },
      "StringLike":   { "token.actions.githubusercontent.com:sub": "repo:<OWNER>/<REPO>:environment:production" }
    }
  }]
}
```
The `sub` condition is the security boundary. Without it, any repository on GitHub could assume your role.

## 3. Repository settings
**Settings > Secrets and variables > Actions > Variables** (these are not secrets):

| Variable | Value |
|---|---|
| `AWS_PLAN_ROLE_ARN` | ARN of `gha-tf-plan` |
| `AWS_APPLY_ROLE_ARN` | ARN of `gha-tf-apply` |
| `TF_STATE_BUCKET` | the state bucket name |
| `ADMIN_SSH_PUBKEY` | contents of your admin **public** key (`~/.ssh/id_ed25519.pub`) |
| `BOOTSTRAP_SSH_CIDR` | `<your-ip>/32` during first setup, empty afterwards |

**Settings > Environments > New environment `production`:** add **Required reviewers** (yourself at minimum) and restrict to the `main` branch. That approval click is what stands between a button press and a real `apply`.

**Settings > Branches > protect `main`:** require a pull request and the `ci-ok` status check.

There are no secrets to add. If you find yourself pasting an AWS access key anywhere, stop: something above is not set up.

## 4. Using it
- Open a PR that changes `terraform/`: the plan appears in the run summary of `terraform-deploy`.
- Build: Actions > terraform-deploy > Run workflow > `apply` > approve in the `production` environment.
- Stop paying: run it with `destroy` (also needs approval).
- The restore VM: change `create_restore_vm` and run `apply`; set it back and `apply` to remove it. (CI uses the variable defaults in `variables.tf`. To override them in CI, add `-var` flags to the plan step.)

## 5. What the pipeline will probably complain about on the first run
I could not run Terraform or Trivy while writing this, so expect to fix a few things:
- `terraform fmt` may want whitespace changes. Run `terraform fmt -recursive` locally and commit.
- Trivy may report findings not in `.trivyignore`. Fix real ones; add accepted ones with a reason. Do not add an ID you do not understand.
- Action versions (`@v4`, `@v3`, `@v5`) and the `:latest` scanner images were current when written. Dependabot will propose bumps; pinning actions to a commit SHA is the stricter option.
