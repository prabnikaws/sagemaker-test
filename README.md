# Notebook Output Stripping — Repo Artifacts

Pre-built files for preventing PII leakage through Jupyter notebook outputs. These files are deployed to each regional notebook repository to enforce output stripping at commit time, staging time, and PR merge time.

## Table of Contents

1. [What This Does](#what-this-does)
2. [File Inventory](#file-inventory)
3. [For Admins: Initial Setup](#for-admins-initial-setup)
   - [Option A: Deploy Repo Files Only](#option-a-deploy-repo-files-only)
   - [Option B: Deploy Repo Files + Custom Docker Image](#option-b-deploy-repo-files--custom-docker-image)
4. [For Users: Getting Started](#for-users-getting-started)
   - [If Your Admin Deployed the Custom Docker Image](#if-your-admin-deployed-the-custom-docker-image)
   - [If No Custom Docker Image (Manual Setup)](#if-no-custom-docker-image-manual-setup)
5. [How It Works](#how-it-works)
6. [Troubleshooting](#troubleshooting)

---

## What This Does

Jupyter notebooks (`.ipynb` files) store cell outputs inline in the JSON file. If a user queries a Red (PII) table and commits the notebook, the PII ends up in Git history. These artifacts prevent that with three layers:

| Layer | Where | What It Does |
|-------|-------|-------------|
| Pre-commit hook | Developer's machine | Strips outputs automatically before `git commit` completes |
| Git clean filter | Developer's machine | Strips outputs on `git add`, even if the pre-commit hook isn't installed |
| GitHub Actions | GitHub server | Blocks any PR to `main` that contains notebook outputs |

---

## File Inventory

```
notebook-repo-artifacts/
│
├── README.md                              ← This file
│
├── scripts/
│   └── strip_notebook_outputs.py          ← Zero-dependency Python script that strips outputs
│
├── .pre-commit-config.yaml                ← Pre-commit hook configuration (Layer 1)
├── .gitattributes                         ← Git clean filter configuration (Layer 2)
│
├── .github/
│   └── workflows/
│       └── reject-outputs.yaml            ← GitHub Actions workflow (Layer 3)
│
├── setup.sh                               ← One-command setup for developers
│
└── docker/
    ├── Dockerfile                         ← Custom SageMaker JupyterLab image with pre-commit baked in
    ├── post-checkout                      ← Git hook that auto-installs pre-commit on clone
    └── build-and-push.sh                  ← Script to build and push the Docker image to ECR
```

---

## For Admins: Initial Setup

You need to do two things: deploy the repo files to `main`, and optionally build and deploy the custom Docker image.

### Option A: Deploy Repo Files Only

This is the minimum setup. Users will need to run `./setup.sh` once in their JupyterLab terminal after cloning.

1. Copy the files to your notebook repo:

```bash
# From this infrastructure repo's root
NOTEBOOK_REPO="/path/to/your-notebook-repo"

cp -r notebook-repo-artifacts/scripts ${NOTEBOOK_REPO}/
cp notebook-repo-artifacts/.pre-commit-config.yaml ${NOTEBOOK_REPO}/
cp notebook-repo-artifacts/.gitattributes ${NOTEBOOK_REPO}/
cp -r notebook-repo-artifacts/.github ${NOTEBOOK_REPO}/
cp notebook-repo-artifacts/setup.sh ${NOTEBOOK_REPO}/
```

2. Set executable permissions, commit, and push:

```bash
cd ${NOTEBOOK_REPO}
chmod +x setup.sh scripts/strip_notebook_outputs.py
git add -A
git commit -m "Add notebook output stripping (pre-commit + clean filter + CI)"
git push origin main
```

3. Configure GitHub branch protection on `main`:
   - Require status checks to pass: select `check-outputs`
   - Restrict who can push to `main`: team leads only
   - Disable force pushes
   - Enable "Do not allow bypassing the above settings"

4. Repeat for each regional notebook repo.

### Option B: Deploy Repo Files + Custom Docker Image

This eliminates the manual `./setup.sh` step for users. When they launch a JupyterLab space with the custom image and clone a repo, the hooks are installed automatically.

Do everything in Option A first, then:

1. Build and push the Docker image:

```bash
cd notebook-repo-artifacts/docker
./build-and-push.sh

# Or for a different region:
REGION=eu-central-1 ./build-and-push.sh
```

2. The script prints the `aws sagemaker` CLI commands to attach the image to your domain. Run them, filling in:
   - `<execution-role-arn>`: an IAM role with ECR pull permissions
   - `<domain-id>`: found via SageMaker Unified Studio → Project details → Project ID → SageMaker AI console → Environment configuration → Domains → search for domain containing your Project ID

3. For multi-region deployments, push the image to ECR in each region and attach to each region's domain.

4. Communicate to users that they should select the `sagemaker-jupyterlab-precommit` image when creating JupyterLab spaces.

---

## For Users: Getting Started

### If Your Admin Deployed the Custom Docker Image

1. Open SageMaker Unified Studio → your project
2. When creating or configuring a JupyterLab space, select `sagemaker-jupyterlab-precommit` from the image dropdown
3. Launch the space
4. Clone your notebook repo — the hooks are installed automatically on clone

That's it. No manual setup needed.

### If No Custom Docker Image (Manual Setup)

1. Open SageMaker Unified Studio → your project → launch JupyterLab
2. Open a terminal: File → New → Terminal
3. Navigate to your notebook repo:

```bash
cd /home/sagemaker-user/your-notebook-repo
```

4. Run the setup script:

```bash
./setup.sh
```

5. Verify it worked:

```bash
pre-commit --version
git config --get filter.strip-notebooks.clean
# Should print: python scripts/strip_notebook_outputs.py
```

From this point on:
- Every `git commit` that includes `.ipynb` files strips outputs automatically
- Every `git add` of a `.ipynb` file strips outputs via the clean filter
- If you forget to set up, the `.gitattributes` `required=true` setting causes `git add` to fail, reminding you to run `./setup.sh`

You only need to run `./setup.sh` once per JupyterLab space. If your space is deleted and recreated, run it again.

---

## How It Works

The strip script (`scripts/strip_notebook_outputs.py`) is a zero-dependency Python script that:
- Removes all cell outputs from `.ipynb` files
- Clears execution counts
- Strips transient cell metadata (collapsed, scrolled, ExecuteTime, etc.)
- Uses only Python stdlib (`json`, `sys`) — no pip packages, no supply chain risk
- Has no opt-out mechanism — for PII repos, there must be no bypass path

It supports three modes:
- File args: `python scripts/strip_notebook_outputs.py notebook.ipynb`
- Check mode: `python scripts/strip_notebook_outputs.py --check notebook.ipynb` (exits 1 if outputs found)
- Stdin/stdout: `cat notebook.ipynb | python scripts/strip_notebook_outputs.py`

---

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| Pre-commit hook doesn't run | Hook not installed | Run `./setup.sh` from the repo root |
| `git add` fails with "required filter not available" | `.gitattributes` has `required=true` but filter not configured | Run `./setup.sh` — this error is intentional to force setup |
| GitHub Actions check fails on PR | Outputs committed despite local hooks | Someone pushed without running `./setup.sh`. Strip outputs and push again: `python scripts/strip_notebook_outputs.py *.ipynb && git add -A && git commit --amend` |
| `python scripts/strip_notebook_outputs.py` gives "No such file" | Wrong directory or script not in repo | Run `git pull` to get the latest `main` which includes the script |
| `./setup.sh` fails with "permission denied" | Script not executable | Run `chmod +x setup.sh` then try again |
| `./build-and-push.sh` fails with ECR auth error | AWS CLI not configured or missing permissions | Run `aws sts get-caller-identity` to verify credentials. Need `ecr:*` permissions. |
