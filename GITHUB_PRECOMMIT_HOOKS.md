# Notebook Output Stripping and Protection

Implementation guide for preventing PII leakage through Jupyter notebook outputs. Uses a multi-layer defense approach. The strip script and output detection logic apply regardless of whether notebooks are stored in GitHub or S3.

> **Note:** SageMaker Unified Studio now uses S3 for notebook storage instead of GitHub. The GitHub-specific layers (pre-commit hooks, git clean filters, GitHub Actions) in this document apply only if your team uses a separate GitHub repo for notebook version control outside of SageMaker. For S3-based notebook governance (bucket policies, Lambda triggers, regional isolation), see [S3_NOTEBOOK_GOVERNANCE.md](S3_NOTEBOOK_GOVERNANCE.md).

## Table of Contents

1. [Threat Model](#threat-model)
2. [Defense Layers](#defense-layers)
3. [Prerequisites](#prerequisites)
4. [Target Repository Layout](#target-repository-layout)
5. [Step-by-Step Implementation](#step-by-step-implementation)
   - [Step 1: Create the Strip Script](#step-1-create-the-strip-script)
   - [Step 2: Configure the Pre-Commit Hook (Layer 1)](#step-2-configure-the-pre-commit-hook-layer-1)
   - [Step 3: Configure the Git Clean Filter (Layer 2)](#step-3-configure-the-git-clean-filter-layer-2)
   - [Step 4: Add the GitHub Actions Workflow (Layer 3)](#step-4-add-the-github-actions-workflow-layer-3)
   - [Step 5: Create the Developer Setup Script](#step-5-create-the-developer-setup-script)
6. [Enforceability Analysis](#enforceability-analysis)
   - [Making Layer 3 Mandatory](#making-layer-3-mandatory)
   - [Why Layers 1 and 2 Still Matter](#why-layers-1-and-2-still-matter)
   - [How Changes Get to Main (The Actual Workflow)](#how-changes-get-to-main-the-actual-workflow)
   - [Gap: Outputs on Feature Branches](#gap-outputs-on-feature-branches)
7. [Developer Onboarding](#developer-onboarding)
8. [Setup on SageMaker Unified Studio V2](#setup-on-sagemaker-unified-studio-v2)
   - [One-Time Setup (Run Once Per JupyterLab Space)](#one-time-setup-run-once-per-jupyterlab-space)
   - [Why This Persists Across Restarts](#why-this-persists-across-restarts)
   - [If the Repo Is Re-Cloned](#if-the-repo-is-re-cloned)
   - [When Setup Needs to Be Rerun](#when-setup-needs-to-be-rerun)
   - [Known Gaps](#known-gaps)
9. [Custom Docker Image (Centralized Enforcement)](#custom-docker-image-centralized-enforcement)
10. [Repository Structure](#repository-structure)
11. [GitHub Access Control](#github-access-control)
12. [Branch Protection Rules](#branch-protection-rules)
13. [Adding a New Regional Repository](#adding-a-new-regional-repository)
14. [Verification](#verification)
15. [Troubleshooting](#troubleshooting)

---

## Threat Model

Jupyter notebooks store cell outputs (query results, DataFrames, plots) inline in the `.ipynb` JSON file. If a user queries a Red (PII) table and commits the notebook, the PII is now in Git history — visible to anyone with repo access, including contractors who should only see Blue/Green data.

```
User queries Red table → Output in notebook JSON → git commit → PII in GitHub
```

The goal: strip ALL outputs from ALL notebooks unconditionally before they reach GitHub. No opt-out, no exceptions.

---

## Defense Layers

| Layer | Where It Runs | Mechanism | What It Catches |
|-------|---------------|-----------|-----------------|
| 1 | Developer's machine | Pre-commit hook | Strips outputs automatically before `git commit` completes |
| 2 | Developer's machine | `.gitattributes` clean filter | Strips outputs on `git add`, even if the pre-commit hook is not installed |
| 3 | GitHub server | GitHub Actions workflow | Blocks any pull request that contains notebook outputs (fail-closed) |

If all three layers fail, regional repo separation (described in [Repository Structure](#repository-structure)) contains the blast radius to a single sovereignty zone.

---

## Prerequisites

Before starting, ensure you have:

| Requirement | Why |
|-------------|-----|
| A GitHub repository where notebooks will be stored | All files in this guide go into that repo |
| Python 3.6+ installed on developer machines | The strip script uses Python stdlib only — no pip packages required |
| `pip` available (for installing `pre-commit`) | Layer 1 uses the [pre-commit](https://pre-commit.com/) framework |
| Admin access to the GitHub repo | Required to configure branch protection rules and required status checks |

---

## Target Repository Layout

Everything in this guide goes into the GitHub repository where your team stores Jupyter notebooks. This is NOT the Terraform infrastructure repo you are reading this document from.

After completing all steps, your notebook repository will contain these new files:

```
your-notebook-repo/                     ← The GitHub repo where notebooks are stored
│
├── scripts/
│   └── strip_notebook_outputs.py       ← Python script that strips outputs (Step 1)
│
├── .pre-commit-config.yaml             ← Pre-commit hook configuration (Step 2)
│
├── .gitattributes                      ← Git clean filter configuration (Step 3)
│
├── .github/
│   └── workflows/
│       └── reject-outputs.yaml         ← GitHub Actions CI workflow (Step 4)
│
├── setup.sh                            ← One-command setup for new developers (Step 5)
│
└── (your existing notebooks and folders)
```

If your repo already has a `.gitattributes` file, you will add a line to it rather than creating a new one.

---

## Step-by-Step Implementation

### Step 1: Create the Strip Script

This is a zero-dependency Python script that unconditionally strips all cell outputs, execution counts, and transient metadata from Jupyter notebooks. It uses only the Python standard library (`json`, `sys`) — no `nbformat`, no pip packages, no supply chain risk.

Design decisions:
- No `keep_output` or `init_cell` opt-out — for PII repos, there must be no bypass path
- Operates on raw JSON (`json` stdlib only)
- Supports file args, stdin/stdout piping, and `--check` mode for CI

Create the file and directory:

```bash
# 1. Open a terminal and cd into your notebook repository
cd /path/to/your-notebook-repo

# 2. Create the scripts/ directory if it doesn't exist
mkdir -p scripts

# 3. Create the file scripts/strip_notebook_outputs.py with the content below

# 4. Make it executable
chmod +x scripts/strip_notebook_outputs.py
```

Contents of `scripts/strip_notebook_outputs.py`:

```python
#!/usr/bin/env python3
"""Strip all outputs and execution counts from Jupyter notebooks.

Zero dependencies — operates on raw JSON. Unconditionally strips ALL
outputs with no opt-out mechanism.

Usage:
  strip_notebook_outputs.py <file.ipynb> [file2.ipynb ...]
  strip_notebook_outputs.py --check <file.ipynb> [...]   (exit 1 if outputs found)
  cat file.ipynb | strip_notebook_outputs.py              (stdin/stdout)
"""
import json, sys

STRIP_CELL_METADATA_KEYS = [
    "collapsed", "scrolled", "ExecuteTime", "execution",
    "heading_collapsed", "hidden"
]

def strip_notebook(nb):
    for cell in nb.get("cells", []):
        if "outputs" in cell:
            cell["outputs"] = []
        if "execution_count" in cell:
            cell["execution_count"] = None
        if "metadata" in cell:
            for key in STRIP_CELL_METADATA_KEYS:
                cell["metadata"].pop(key, None)
    nb.get("metadata", {}).pop("signature", None)
    nb.get("metadata", {}).pop("widgets", None)
    return nb

def has_outputs(nb):
    for cell in nb.get("cells", []):
        if cell.get("outputs"):
            return True
        if cell.get("execution_count") is not None:
            return True
    return False

def main():
    check_mode = "--check" in sys.argv or "--verify" in sys.argv
    files = [f for f in sys.argv[1:] if not f.startswith("--")]

    if not files and not sys.stdin.isatty():
        nb = json.load(sys.stdin)
        if check_mode:
            sys.exit(1 if has_outputs(nb) else 0)
        json.dump(strip_notebook(nb), sys.stdout, indent=1, ensure_ascii=False)
        sys.stdout.write("\n")
        return

    failed = False
    for filepath in files:
        if not filepath.endswith(".ipynb"):
            continue
        with open(filepath, "r", encoding="utf-8") as f:
            nb = json.load(f)
        if check_mode:
            if has_outputs(nb):
                print(f"FAIL: {filepath} contains outputs", file=sys.stderr)
                failed = True
        else:
            with open(filepath, "w", encoding="utf-8") as f:
                json.dump(strip_notebook(nb), f, indent=1, ensure_ascii=False)
                f.write("\n")

    if check_mode and failed:
        sys.exit(1)

if __name__ == "__main__":
    main()
```

Verify the script works:

```bash
# Still in your notebook repo directory
# The script has no --help flag. To verify it runs, use --check on a test file.
# With no arguments and no piped input, it exits silently (expected behavior).
python scripts/strip_notebook_outputs.py
# Should exit with code 0 and no output — this means it loaded correctly.
```

### Step 2: Configure the Pre-Commit Hook (Layer 1)

The [pre-commit](https://pre-commit.com/) framework runs the strip script automatically every time a developer runs `git commit`. If any `.ipynb` file is staged, the hook strips its outputs before the commit completes.

Create the file `.pre-commit-config.yaml` in the root of your notebook repository:

```bash
# 1. Make sure you are in the root of your notebook repo
cd /path/to/your-notebook-repo

# 2. Create .pre-commit-config.yaml with the content below
```

Contents of `.pre-commit-config.yaml`:

```yaml
repos:
  - repo: local
    hooks:
      - id: strip-notebook-outputs
        name: Strip notebook outputs
        entry: python scripts/strip_notebook_outputs.py
        language: system
        types: [jupyter]
```

This is a local hook — it references `scripts/strip_notebook_outputs.py` which already exists in the same repo. It does not download anything from the internet at commit time.

Install the hook into your local git configuration:

```bash
# 1. Install the pre-commit package (one-time, per machine)
pip install pre-commit

# 2. Install the hook into this repo's .git/hooks/ directory
pre-commit install
```

After this, every `git commit` that includes `.ipynb` files will automatically run the strip script on those files before committing.

### Step 3: Configure the Git Clean Filter (Layer 2)

The git clean filter strips outputs at `git add` time — before the file even reaches the staging area. This catches cases where a developer clones the repo but forgets to run `pre-commit install`.

There are two parts: a `.gitattributes` file (committed to the repo) and a local git config (per developer).

**Part A — `.gitattributes` file (committed to the repo):**

If your repo already has a `.gitattributes` file, add this line to it. If not, create a new file called `.gitattributes` in the repo root:

```
*.ipynb filter=strip-notebooks
```

This tells git: "For every `.ipynb` file, run the `strip-notebooks` filter before staging."

**Part B — Local git config (each developer runs this once after cloning):**

```bash
# Run these three commands from the root of your notebook repo
git config filter.strip-notebooks.clean "python scripts/strip_notebook_outputs.py"
git config filter.strip-notebooks.smudge cat
git config filter.strip-notebooks.required true
```

What each command does:

| Command | Effect |
|---------|--------|
| `git config filter.strip-notebooks.clean ...` | Tells git to pipe `.ipynb` files through the strip script when staging |
| `git config filter.strip-notebooks.smudge cat` | On checkout, pass the file through unchanged (outputs are already stripped) |
| `git config filter.strip-notebooks.required true` | If the filter is missing (not configured), git operations on `.ipynb` files will fail rather than silently passing unstripped content |

The `required=true` setting is critical — without it, a developer who skips setup would silently commit unstripped notebooks.

### Step 4: Add the GitHub Actions Workflow (Layer 3)

This is the server-side safety net. It runs on every pull request (blocking merge if outputs are found) and on every push to any branch (alerting if outputs are detected). Even if both local layers were bypassed, this catches it.

Create the directory and file:

```bash
# From the root of your notebook repo
mkdir -p .github/workflows
```

Create `.github/workflows/reject-outputs.yaml` with this content:

```yaml
name: Reject Notebook Outputs
on:
  pull_request:
  push:
    paths:
      - '**/*.ipynb'
jobs:
  check-outputs:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Check for outputs
        id: check
        run: |
          NOTEBOOKS=$(find . -name '*.ipynb')
          if [ -z "$NOTEBOOKS" ]; then
            echo "No notebooks found."
            exit 0
          fi
          python scripts/strip_notebook_outputs.py --check $NOTEBOOKS
        continue-on-error: ${{ github.event_name == 'push' }}
      - name: Alert on push with outputs
        if: ${{ github.event_name == 'push' && steps.check.outcome == 'failure' }}
        run: |
          echo "::warning::Notebook outputs detected on branch ${{ github.ref_name }}. Run: python scripts/strip_notebook_outputs.py *.ipynb"
      - name: Fail PR with outputs
        if: ${{ github.event_name == 'pull_request' && steps.check.outcome == 'failure' }}
        run: |
          echo "ERROR: Notebook outputs detected. Run: python scripts/strip_notebook_outputs.py *.ipynb"
          exit 1
```

This workflow does two things:
- On pull requests: fails hard if outputs are found, blocking the merge into `main`
- On pushes to any branch: detects outputs and logs a warning, but does not fail the workflow (the push has already happened — failing would only create noise without preventing anything)

No `pip install` step is needed — the strip script has zero dependencies and runs on any Python 3.6+ installation (GitHub Actions runners include Python by default).

### Step 5: Create the Developer Setup Script

To avoid asking every developer to remember three separate git config commands and a pip install, create a `setup.sh` script in the repo root that does everything in one command.

Create `setup.sh` in the root of your notebook repo:

```bash
#!/bin/bash
# Configure notebook output stripping for this repository.
# Run this once after cloning: ./setup.sh
set -e

echo "Configuring git clean filter for notebook output stripping..."
git config filter.strip-notebooks.clean "python scripts/strip_notebook_outputs.py"
git config filter.strip-notebooks.smudge cat
git config filter.strip-notebooks.required true

echo "Installing pre-commit hooks..."
pip install pre-commit
pre-commit install

echo ""
echo "Done. Notebook output stripping is now configured."
echo "  - Pre-commit hook: strips outputs on every 'git commit'"
echo "  - Git clean filter: strips outputs on every 'git add'"
echo "  - Both are local to this repo clone only."
```

Make it executable:

```bash
chmod +x setup.sh
```

Commit all five files to the repo:

```bash
git add scripts/strip_notebook_outputs.py \
       .pre-commit-config.yaml \
       .gitattributes \
       .github/workflows/reject-outputs.yaml \
       setup.sh
git commit -m "Add notebook output stripping (pre-commit + clean filter + CI)"
git push
```

### Pre-Built Artifacts

Ready-to-use copies of all five files are available in the `notebook-repo-artifacts/` directory of this infrastructure repo. You can copy them directly into your notebook repo without creating them from scratch:

```
notebook-repo-artifacts/
├── scripts/
│   └── strip_notebook_outputs.py
├── .pre-commit-config.yaml
├── .gitattributes
├── .github/
│   └── workflows/
│       └── reject-outputs.yaml
└── setup.sh
```

To deploy them to your notebook repo:

```bash
# From this infrastructure repo's root
cp -r notebook-repo-artifacts/scripts /path/to/your-notebook-repo/
cp notebook-repo-artifacts/.pre-commit-config.yaml /path/to/your-notebook-repo/
cp notebook-repo-artifacts/.gitattributes /path/to/your-notebook-repo/
cp -r notebook-repo-artifacts/.github /path/to/your-notebook-repo/
cp notebook-repo-artifacts/setup.sh /path/to/your-notebook-repo/

# Then in the notebook repo
cd /path/to/your-notebook-repo
chmod +x setup.sh scripts/strip_notebook_outputs.py
git add -A
git commit -m "Add notebook output stripping (pre-commit + clean filter + CI)"
git push origin main
```

If you don't have local access to the notebook repo (e.g., you can only access it from SageMaker), you can push these files via the GitHub web UI:

1. Go to your notebook repo on GitHub
2. Click "Add file" → "Upload files"
3. Upload `scripts/strip_notebook_outputs.py`, `.pre-commit-config.yaml`, `.gitattributes`, `.github/workflows/reject-outputs.yaml`, and `setup.sh`
4. Commit directly to `main`
5. Then from a SageMaker JupyterLab terminal, set the executable bit:

```bash
cd /home/sagemaker-user/your-notebook-repo
git pull
chmod +x setup.sh scripts/strip_notebook_outputs.py
git add -A
git commit -m "Set executable permissions"
git push
```

Once these files are on `main`, every branch created from `main` inherits them. Users clone or pull, run `./setup.sh` once, and the hooks are active.

---

## Enforceability Analysis

Layers 1 and 2 run on the developer's machine. A developer can bypass them. Layer 3 runs on GitHub's servers and is the only layer that can be made mandatory.

| Layer | Server-Enforced? | Bypass Methods |
|-------|:-----------------:|----------------|
| 1 — Pre-commit hook | No | `git commit --no-verify` skips all pre-commit hooks. Developer can also uninstall the hook with `pre-commit uninstall`. |
| 2 — Git clean filter | No | Developer can run `git config --unset filter.strip-notebooks.clean` to remove the filter. The `required=true` flag causes `git add` to fail if the filter is missing, but a developer can also unset that with `git config --unset filter.strip-notebooks.required`. |
| 3 — GitHub Actions CI | Yes (with correct branch protection) | Cannot be bypassed by non-admin users if branch protection is configured correctly. See below. |

### Making Layer 3 Mandatory

The GitHub Actions workflow only blocks merges if branch protection rules enforce it. Without the right settings, a developer can push directly to `main` or an admin can merge without checks passing.

Required branch protection settings (GitHub → Repo → Settings → Branches → `main`):

| Setting | Required Value | What Happens If Missing |
|---------|---------------|------------------------|
| Require status checks to pass before merging | Enabled, with `check-outputs` selected | PRs can merge even if notebooks contain outputs |
| Require branches to be up to date before merging | Enabled | Stale PRs could bypass the check if the workflow was added after the PR was created |
| Restrict who can push to matching branches | Team leads / admins only | Anyone with write access can push directly to `main`, bypassing CI entirely |
| Do not allow bypassing the above settings | Enabled | Without this, repo admins can merge PRs that fail status checks |
| Allow force pushes | Disabled | Force pushes to `main` bypass all checks |

If all five settings are configured, Layer 3 is mandatory for all users including admins. No one can get unstripped notebooks into `main` without either:
- Changing the branch protection rules (requires admin access, visible in audit log)
- Deleting or modifying the GitHub Actions workflow file (visible in PR diff and git history)

### Why Layers 1 and 2 Still Matter

Even though they're bypassable, Layers 1 and 2 serve a different purpose:

- They prevent accidental commits — most PII leaks are mistakes, not malicious acts
- They strip outputs before they enter git history — Layer 3 only blocks the merge, but the outputs are already in the PR branch history
- They provide immediate feedback — the developer sees the strip happen at commit time, not 2 minutes later when CI runs
- Layer 2's `required=true` flag forces developers to run `setup.sh`, which is a forcing function for awareness

The defense model is: Layers 1 and 2 prevent accidents, Layer 3 prevents policy violations.

### How Changes Get to Main (The Actual Workflow)

Branch protection does not prevent developers from pushing notebooks to GitHub. It only controls how changes reach the `main` branch. Developers can push freely to their own branches — the gate is at the merge step.

```
Developer's machine          GitHub                        main branch
─────────────────          ──────                        ───────────
                                                         (protected)
1. Edit notebook
   (outputs present)
        │
2. git commit               
   (Layer 1 strips outputs)
        │
3. git push origin feature/my-work
        ├──────────────────▶ feature/my-work branch
        │                    (no restrictions,
        │                     push succeeds)
        │
4. Open Pull Request         PR: feature/my-work → main
        │                         │
        │                    5. GitHub Actions runs
        │                       check-outputs workflow
        │                         │
        │                    ┌────┴────┐
        │                    │ Outputs │
        │                    │ found?  │
        │                    └────┬────┘
        │                   No   │   Yes
        │                    │   │
        │              CI passes │  CI fails
        │              PR can    │  PR blocked
        │              merge     │  (developer strips
        │                 │      │   and pushes again)
        │                 ▼      │
        │              Merge ◄───┘ (after fix)
        │                 │
        │                 ▼
        │              main updated
        │              (clean notebooks only)
```

What each participant can do:

| Action | Allowed? | Why |
|--------|:--------:|-----|
| Push notebooks to a feature branch | Yes | Branch protection only applies to `main` |
| Push notebooks with outputs to a feature branch | Yes | No restrictions on feature branches — but Layers 1 and 2 strip outputs locally before push |
| Open a PR to `main` | Yes | Anyone with write access can open PRs |
| Merge a PR to `main` when CI fails | No | Branch protection requires `check-outputs` to pass |
| Push directly to `main` (no PR) | No | Branch protection restricts direct pushes to admins/team leads |
| Force-push to `main` | No | Branch protection disables force pushes |

The net effect: developers work normally (edit, commit, push, open PRs), but unstripped notebooks can never reach `main`.

### Gap: Outputs on Feature Branches

Branch protection only gates merges into `main`. If a developer bypasses Layers 1 and 2 (or never runs `setup.sh`), they can push notebooks with outputs to a feature branch. That data is then in GitHub's git history — visible to anyone with read access to the repo, even if it never reaches `main`.

This is a real gap. Here are the options to address it:

| Option | How It Works | Plan Required | Limitations |
|--------|-------------|:-------------:|-------------|
| Push ruleset: file size limit | GitHub push rulesets (GA Sept 2024) can block pushes containing files over a size threshold. Notebooks with outputs are typically much larger than stripped ones. Setting a size limit (e.g., 50KB) catches most cases where outputs are present. | GitHub Team | Heuristic — a small notebook with outputs may slip under the limit, and a large notebook with only code cells may be blocked. Requires tuning the threshold per repo. |
| Push ruleset: block `.ipynb` entirely | Block all `.ipynb` files from being pushed. Notebooks are edited in SageMaker and never stored in git. | GitHub Team | Notebooks can't be version-controlled at all. Only viable if the repo is used for non-notebook code and notebooks live elsewhere. |
| GitHub Actions on `push` (all branches) | The workflow in [Step 4](#step-4-add-the-github-actions-workflow-layer-3) already triggers on `push` in addition to `pull_request`. Cannot reject the push after it happens, but detects outputs and logs a warning. Can be extended to post Slack alerts, auto-create issues, or trigger cleanup PRs. | GitHub Free | Detection only — the data is already in git history by the time the action runs. |
| GitHub pre-receive hooks | Server-side hooks that run before a push is accepted. Can inspect file content and reject the push. | GitHub Enterprise Server (self-hosted only) | Not available on GitHub.com or GitHub Enterprise Cloud. |
| Accept the risk with mitigations | Rely on Layers 1 and 2 for accident prevention, Layer 3 for main-branch enforcement, regional repo separation for blast radius containment, and restricted repo access (only regional team members see branch data). | Any | Outputs can exist in feature branch history until the branch is deleted. |

Why push rulesets can't fully solve this: push rulesets operate on file metadata (path, extension, size) — not file content. There is no GitHub-native way to inspect the contents of a `.ipynb` file server-side before a push is accepted on GitHub.com. The `check-outputs` script needs to parse the JSON to determine if outputs are present, and push rulesets don't support custom content inspection.

The file size heuristic is the strongest server-side option available on GitHub Team. A stripped notebook is typically under 10KB for a normal-sized notebook (code cells only). A notebook with DataFrame outputs, plots, or query results can easily be 100KB–10MB. Setting a push ruleset with a file size limit of 50–100KB for `*.ipynb` files catches the majority of cases where outputs are accidentally included.

To configure a push ruleset with file size limit:

1. Go to your repository → Settings → Rules → Rulesets
2. Click "New ruleset" → "New push ruleset"
3. Under "Restrict file size", set the maximum file size (e.g., 100KB)
4. Optionally restrict to `*.ipynb` file paths only
5. Set bypass permissions to "No bypass" (or restrict to repo admins)

If you are on GitHub Enterprise, push rulesets can also be applied at the organization level across all notebook repos.

If you are on GitHub.com (non-Enterprise) with GitHub Team plan, the practical approach is:

1. Push ruleset with file size limit on `*.ipynb` files (catches most output-containing notebooks server-side)
2. The workflow in [Step 4](#step-4-add-the-github-actions-workflow-layer-3) detects any that slip through the size limit
3. Set a branch retention policy to auto-delete feature branches after merge (reduces the window where outputs sit in history)
4. Rely on regional repo separation and team-scoped access to limit who can see branch data

If you are on GitHub Free, the only server-side option is the GitHub Actions push-trigger workflow (detection, not prevention).

---

## Developer Onboarding

When a new developer clones the notebook repo, they run one command:

```bash
# 1. Clone the repo
git clone https://github.com/your-org/your-notebook-repo.git
cd your-notebook-repo

# 2. Run the setup script
./setup.sh
```

That's it. From this point on:
- Every `git add` of a `.ipynb` file strips outputs (clean filter)
- Every `git commit` that includes `.ipynb` files strips outputs (pre-commit hook)
- Every pull request is checked server-side (GitHub Actions)

If a developer skips `./setup.sh`:
- The `.gitattributes` `required=true` setting causes `git add` of `.ipynb` files to fail with a filter error, forcing them to run setup
- Even if they force-push, the GitHub Actions workflow blocks the PR

---

## Setup on SageMaker Unified Studio V2

If you cannot install pre-commit hooks on your local machine (e.g., corporate laptop restrictions), you can run the setup from the JupyterLab terminal inside SageMaker Unified Studio V2. This is the instance that connects to your GitHub repo.

SageMaker Unified Studio V2 does not support classic lifecycle configurations through the console. The JupyterLab environments are provisioned through DataZone environment profiles, not directly through the SageMaker domain API. There is no "Lifecycle configuration" tab in the V2 console.

Instead, use the persistent EBS volume to make the setup survive app restarts.

### One-Time Setup (Run Once Per JupyterLab Space)

1. Open SageMaker Unified Studio in your browser
2. Open your project
3. Launch JupyterLab (click the JupyterLab icon in the project)
4. In JupyterLab, go to File → New → Terminal
5. Find where your repo is cloned:

```bash
ls /home/sagemaker-user/
```

6. Create a persistent setup script on the EBS volume:

```bash
cat > /home/sagemaker-user/.setup-precommit.sh << 'SETUP_EOF'
#!/bin/bash
# Auto-install pre-commit hooks for notebook output stripping.
# This script is sourced from .bashrc on every terminal open.

REPO_DIR="/home/sagemaker-user/your-notebook-repo"  # <-- Change this to your actual repo path

if [ -d "$REPO_DIR/.git" ]; then
  cd "$REPO_DIR"

  # Install pre-commit if not already installed
  if ! command -v pre-commit &> /dev/null; then
    pip install -q pre-commit 2>/dev/null
  fi

  # Install the hook if not already present
  if [ ! -f "$REPO_DIR/.git/hooks/pre-commit" ]; then
    pre-commit install 2>/dev/null
  fi

  # Configure git clean filter
  git config filter.strip-notebooks.clean "python scripts/strip_notebook_outputs.py"
  git config filter.strip-notebooks.smudge cat
  git config filter.strip-notebooks.required true

  cd - > /dev/null
fi
SETUP_EOF
chmod +x /home/sagemaker-user/.setup-precommit.sh
```

7. Add it to your bash profile so it runs automatically on every terminal open:

```bash
# Check if already added (avoid duplicates)
grep -q '.setup-precommit.sh' /home/sagemaker-user/.bashrc || \
  echo 'source /home/sagemaker-user/.setup-precommit.sh' >> /home/sagemaker-user/.bashrc
```

8. Run it now:

```bash
source /home/sagemaker-user/.setup-precommit.sh
```

9. Verify it worked:

```bash
cd /home/sagemaker-user/your-notebook-repo
pre-commit --version
git config --get filter.strip-notebooks.clean
# Should print: python scripts/strip_notebook_outputs.py
```

### Why This Persists Across Restarts

| What | Where It Lives | Survives App Restart? |
|------|---------------|:---------------------:|
| `.setup-precommit.sh` | `/home/sagemaker-user/` (EBS volume) | Yes |
| `.bashrc` entry | `/home/sagemaker-user/` (EBS volume) | Yes |
| `pre-commit` pip package | System Python (container filesystem) | No — reinstalled automatically by the script |
| `.git/hooks/pre-commit` | Inside the repo clone (EBS volume) | Yes, unless repo is re-cloned |
| Git clean filter config | `.git/config` inside the repo (EBS volume) | Yes, unless repo is re-cloned |

The `/home/sagemaker-user/` directory is on a persistent EBS volume that survives JupyterLab app stop/start cycles. The container filesystem (where pip packages are installed) is ephemeral, but the `.bashrc` trigger reinstalls `pre-commit` automatically the next time you open a terminal.

### If the Repo Is Re-Cloned

If you delete and re-clone the repo, the `.git/hooks/` directory is reset. The next time you open a terminal, the `.bashrc` trigger will detect the missing hook and reinstall it automatically — no manual action needed.

### When Setup Needs to Be Rerun

Each user in SageMaker Unified Studio V2 gets their own JupyterLab space with its own EBS volume. The setup script lives on that user's volume only — it does not apply to other users automatically.

| Scenario | Need to Rerun? | Why |
|----------|:--------------:|-----|
| JupyterLab app stopped and restarted | No | EBS volume persists. `.bashrc` trigger reinstalls `pre-commit` pip package on next terminal open. |
| JupyterLab space deleted and recreated | Yes | New space = new EBS volume. Everything is gone. Run the full one-time setup again. |
| EBS volume replaced (space storage reset) | Yes | Same as above — new volume, no `.bashrc`, no script. |
| Repo deleted and re-cloned in the same space | No | `.bashrc` trigger detects the fresh `.git/` directory and reinstalls the hook automatically. |
| A different user opens their own JupyterLab space | Yes | Each user has their own EBS volume. Setup is per-user, not shared across the team. |
| User opens a Code Editor space (not JupyterLab) | Yes | Code Editor spaces have separate EBS volumes. The setup must be repeated there. |
| User switches from bash to zsh | Partial | `.bashrc` only runs for bash. Add `source /home/sagemaker-user/.setup-precommit.sh` to `.zshrc` instead. |

### Known Gaps

| Gap | Impact | Mitigation |
|-----|--------|------------|
| JupyterLab git UI (sidebar panel) may not trigger pre-commit hooks | Commits made through the JupyterLab git extension UI may bypass the pre-commit hook because the extension may call git without going through the shell. | The git clean filter (Layer 2) is configured in `.git/config` and should still strip outputs on `git add` regardless of how git is invoked. The GitHub Actions workflow (Layer 3) catches anything that slips through. Test this in your environment to confirm. |
| Setup is per-user, not centrally managed | Every user who commits notebooks must run the one-time setup on their own space. There is no way to push the setup to all users from a central location in V2. | Document the setup in onboarding instructions. Consider a custom Docker image with `pre-commit` pre-installed if the team is large. |
| No lifecycle configuration support in V2 | Unlike classic SageMaker Studio, V2 does not expose lifecycle configurations through the console or API for JupyterLab spaces provisioned via DataZone. | The `.bashrc` approach on the persistent EBS volume is the current workaround. Use the custom Docker image approach below for centralized enforcement. |

---

## Custom Docker Image (Centralized Enforcement)

For teams that want pre-commit hooks provisioned automatically for every user without manual setup, you can build a custom Docker image with `pre-commit` pre-installed and a git template that auto-configures hooks on every clone. This uses the SageMaker Unified Studio BYOI (Bring Your Own Image) feature.

This approach eliminates the per-user `.bashrc` setup — every user who launches a JupyterLab space with this image gets the hooks automatically.

### Comparison: `.bashrc` vs Custom Docker Image

| | `.bashrc` on EBS (Option A) | Custom Docker Image (Option B) |
|---|---|---|
| Auto-provisions for all users | No — each user runs setup once | Yes — baked into the image |
| Survives space deletion | No — new EBS = redo setup | Yes — image is centrally managed |
| Maintenance | None | Must rebuild when base image updates |
| Requires ECR + IAM setup | No | Yes |
| Best for | Small teams, quick setup | Larger teams, compliance enforcement |

### Step 1: Create the Dockerfile

The base image must be `sagemaker-distribution` version 2.6 or higher (required by Unified Studio). You extend it with `pre-commit` and a git template that auto-installs hooks on every clone.

Create a file called `Dockerfile`:

```dockerfile
FROM public.ecr.aws/sagemaker/sagemaker-distribution:2.6-cpu

ARG NB_USER="sagemaker-user"
ARG NB_UID=1000
ARG NB_GID=100
ENV MAMBA_USER=$NB_USER

USER root

# Install pre-commit
RUN pip install pre-commit

# Create a global git template with a post-checkout hook
# that auto-installs pre-commit and the git clean filter
# whenever a repo with .pre-commit-config.yaml is cloned
RUN mkdir -p /etc/git-templates/hooks && \
    cat > /etc/git-templates/hooks/post-checkout << 'HOOKEOF'
#!/bin/bash
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
if [ -f "$REPO_ROOT/.pre-commit-config.yaml" ]; then
  cd "$REPO_ROOT"
  pre-commit install 2>/dev/null
  git config filter.strip-notebooks.clean "python scripts/strip_notebook_outputs.py"
  git config filter.strip-notebooks.smudge cat
  git config filter.strip-notebooks.required true
fi
HOOKEOF

RUN chmod +x /etc/git-templates/hooks/post-checkout

# Set the global git template so every git clone/init uses it
RUN git config --system init.templateDir /etc/git-templates

USER $MAMBA_USER
```

Do NOT add an `ENTRYPOINT` — SageMaker manages the entrypoint. See [Dockerfile specifications](https://docs.aws.amazon.com/sagemaker-unified-studio/latest/userguide/byoi-specifications.html).

### Step 2: Build and push to ECR

Run these commands from a machine with Docker installed (your laptop, a CI runner, or a Cloud9 instance):

```bash
# Set variables
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION=us-west-2  # Change to your region
IMAGE_NAME=sagemaker-jupyterlab-precommit
TAG=latest

# Build the image
docker build -t ${IMAGE_NAME}:${TAG} .

# Create the ECR repository (skip if it already exists)
aws ecr create-repository \
  --repository-name ${IMAGE_NAME} \
  --region ${REGION} 2>/dev/null

# Login to ECR
aws ecr get-login-password --region ${REGION} | \
  docker login --username AWS \
  --password-stdin ${AWS_ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com

# Tag and push
docker tag ${IMAGE_NAME}:${TAG} \
  ${AWS_ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${IMAGE_NAME}:${TAG}

docker push \
  ${AWS_ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${IMAGE_NAME}:${TAG}
```

### Step 3: Find the SageMaker AI domain for your Unified Studio project

Each Unified Studio project has an associated SageMaker AI domain. You need to find it to attach the image.

1. Open SageMaker Unified Studio → your project → "Project details" tab
2. Copy the Project ID
3. Open the SageMaker AI console (`console.aws.amazon.com/sagemaker`)
4. In the left nav, under "Environment configuration", click "Domains"
5. Search for the domain name that contains your Project ID
6. Click the domain name to open its details

See [View the SageMaker AI domain details associated with your project](https://docs.aws.amazon.com/sagemaker-unified-studio/latest/userguide/view-project-details.html) for the full instructions.

### Step 4: Attach the image to the domain

You can do this via the console or CLI.

**Via the SageMaker AI console:**

1. In the left nav under "Environment configuration", click "Images"
2. Click "Create image"
3. Provide:
   - Image name: `sagemaker-jupyterlab-precommit`
   - IAM role: select a role with ECR pull permissions (`ecr:GetDownloadUrlForLayer`, `ecr:BatchGetImage`, `ecr:BatchCheckLayerAvailability`)
   - Image source: `{account-id}.dkr.ecr.{region}.amazonaws.com/sagemaker-jupyterlab-precommit:latest`
4. Click "Submit" and wait for the image status to show "Created"
5. Go to "Domains" → click your domain → look for the option to attach custom images
6. Attach the image you just created

**Via the CLI:**

```bash
DOMAIN_ID=<your-domain-id>
ROLE_ARN=<execution-role-arn>
IMAGE_URI=${AWS_ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${IMAGE_NAME}:${TAG}

# Create the SageMaker Image
aws sagemaker create-image \
  --image-name ${IMAGE_NAME} \
  --role-arn ${ROLE_ARN} \
  --region ${REGION}

# Create an image version
aws sagemaker create-image-version \
  --image-name ${IMAGE_NAME} \
  --base-image ${IMAGE_URI} \
  --region ${REGION}

# Create an app image config for JupyterLab
aws sagemaker create-app-image-config \
  --app-image-config-name ${IMAGE_NAME}-config \
  --jupyter-lab-app-image-config '{}' \
  --region ${REGION}

# Attach to the domain
aws sagemaker update-domain \
  --domain-id ${DOMAIN_ID} \
  --default-user-settings '{
    "JupyterLabAppSettings": {
      "CustomImages": [
        {
          "ImageName": "'${IMAGE_NAME}'",
          "AppImageConfigName": "'${IMAGE_NAME}'-config"
        }
      ]
    }
  }' \
  --region ${REGION}
```

### Step 5: Users select the image in Unified Studio

1. Open SageMaker Unified Studio → your project
2. When creating or configuring a JupyterLab space, the custom image appears in the image selection dropdown
3. Select `sagemaker-jupyterlab-precommit`
4. Launch the space

When a user clones a repo that has a `.pre-commit-config.yaml`, the `post-checkout` hook fires automatically and configures the pre-commit hook and git clean filter. No manual setup needed.

See [Launch your custom image in Amazon SageMaker Unified Studio](https://docs.aws.amazon.com/sagemaker-unified-studio/latest/userguide/byoi.html) for the full instructions.

### Pre-Built Docker Artifacts

Ready-to-use Docker artifacts are available in the `notebook-repo-artifacts/docker/` directory of this infrastructure repo:

```
notebook-repo-artifacts/docker/
├── Dockerfile           ← Custom image extending sagemaker-distribution:2.6-cpu
├── post-checkout        ← Git hook that auto-installs pre-commit on clone
└── build-and-push.sh    ← Script to build, push to ECR, and print attach commands
```

To build and deploy:

```bash
cd notebook-repo-artifacts/docker

# Build and push to ECR (defaults to us-west-2)
./build-and-push.sh

# Or override the region
REGION=eu-central-1 ./build-and-push.sh
```

The script builds the image, pushes it to ECR, and prints the exact `aws sagemaker` CLI commands to attach it to your domain. You'll need to fill in two values:

| Placeholder | Where to Find It |
|-------------|-----------------|
| `<execution-role-arn>` | An IAM role with ECR pull permissions (`ecr:GetDownloadUrlForLayer`, `ecr:BatchGetImage`, `ecr:BatchCheckLayerAvailability`). This can be the SageMaker execution role for your domain. |
| `<domain-id>` | SageMaker Unified Studio → your project → "Project details" tab → copy Project ID → SageMaker AI console → "Environment configuration" → "Domains" → find the domain containing your Project ID |

### Maintenance

| Task | When | How |
|------|------|-----|
| Rebuild the image | When AWS releases a new `sagemaker-distribution` version you want to adopt | Update the `FROM` line in the Dockerfile, rebuild, push to ECR, create a new image version |
| Update pre-commit version | When a new `pre-commit` version is needed | Same as above |
| Multi-region deployment | If you have Unified Studio projects in multiple regions | Push the image to ECR in each region and attach to each region's domain |

### References

- [BYOI Overview — SageMaker Unified Studio](https://docs.aws.amazon.com/sagemaker-unified-studio/latest/userguide/byoi.html)
- [Dockerfile Specifications — SageMaker Unified Studio](https://docs.aws.amazon.com/sagemaker-unified-studio/latest/userguide/byoi-specifications.html)
- [How to BYOI — SageMaker Unified Studio](https://docs.aws.amazon.com/sagemaker-unified-studio/latest/userguide/byoi-how-to.html)
- [View Project Details — SageMaker Unified Studio](https://docs.aws.amazon.com/sagemaker-unified-studio/latest/userguide/view-project-details.html)

---

## Repository Structure

Notebook repos are organized by sovereignty region. Even if output stripping fails at all three layers, the blast radius is contained to a single region because each region's data lives in a separate repo.

```
GitHub Organization: plume-data
│
├── {customer}-notebooks-us          ← us-west-2 notebooks
│   ├── .pre-commit-config.yaml
│   ├── .gitattributes
│   ├── .github/workflows/reject-outputs.yaml
│   ├── scripts/strip_notebook_outputs.py
│   ├── setup.sh
│   ├── network/
│   ├── security/
│   ├── harvest/
│   └── ...
│
├── {customer}-notebooks-eu          ← eu-central-1 notebooks
│   ├── (same files as above)
│   └── ...
│
├── {customer}-notebooks-ca          ← ca-central-1 notebooks
├── {customer}-notebooks-apne        ← ap-northeast-1 notebooks
├── {customer}-notebooks-apse        ← ap-southeast-1 notebooks
│
└── plume-notebook-templates          ← Shared templates (no data)
    ├── migration-template.ipynb
    └── validation-template.ipynb
```

SageMaker projects are hardcoded to connect to the repo matching their sovereignty region. A US project connects to `{customer}-notebooks-us` only.

---

## GitHub Access Control

| GitHub Team | Repos | Permission |
|-------------|-------|------------|
| `{customer}-us-team` | `{customer}-notebooks-us` | Write |
| `{customer}-eu-team` | `{customer}-notebooks-eu` | Write |
| `{customer}-ca-team` | `{customer}-notebooks-ca` | Write |
| `{customer}-apne-team` | `{customer}-notebooks-apne` | Write |
| `{customer}-apse-team` | `{customer}-notebooks-apse` | Write |
| `plume-governance` | All repos | Read |
| `plume-templates` | `plume-notebook-templates` | Write |

Regional teams only have access to their region's repo. Cross-region access is denied at the GitHub team level.

---

## Branch Protection Rules

Configure these in GitHub → Repository → Settings → Branches → Branch protection rules for `main`:

| Rule | Setting | Why |
|------|---------|-----|
| Require pull request reviews | 1 approval minimum | Peer review before merge |
| Require status checks to pass | `check-outputs` must pass | The GitHub Actions workflow from Step 4 |
| Require branches to be up to date | Yes | Prevents merge conflicts from bypassing checks |
| Restrict who can push to main | Team leads only | Prevents direct pushes that skip CI |
| Require signed commits | Recommended | Verifies commit author identity |

The `check-outputs` status check is the name of the job in the GitHub Actions workflow. It must be marked as a required status check in branch protection settings for the CI gate to be enforced.

---

## Adding a New Regional Repository

When onboarding a new customer or sovereignty region:

1. Create the repo in the GitHub org following the naming convention (`{customer}-notebooks-{region}`)
2. Copy these five files from an existing regional repo:
   - `scripts/strip_notebook_outputs.py`
   - `.pre-commit-config.yaml`
   - `.gitattributes`
   - `.github/workflows/reject-outputs.yaml`
   - `setup.sh`
3. Create the GitHub team (`{customer}-{region}-team`) and grant Write access
4. Add `plume-governance` team with Read access
5. Enable branch protection with `check-outputs` as a required status check
6. Configure the SageMaker project profile to reference this repo URL

---

## Verification

After completing all five steps, verify each layer works. Run these commands from the root of your notebook repo:

```bash
# 1. Create a test notebook that has outputs (simulates a notebook with PII)
python -c "
import json
nb = {'nbformat': 4, 'nbformat_minor': 5, 'metadata': {}, 'cells': [
  {'cell_type': 'code', 'source': 'print(1)', 'metadata': {},
   'outputs': [{'output_type': 'stream', 'name': 'stdout', 'text': ['1\n']}],
   'execution_count': 1}
]}
with open('test_output.ipynb', 'w') as f: json.dump(nb, f)
"

# 2. Verify --check mode detects the outputs
python scripts/strip_notebook_outputs.py --check test_output.ipynb
# Expected: exits with code 1, prints "FAIL: test_output.ipynb contains outputs"

# 3. Verify the strip script removes outputs
python scripts/strip_notebook_outputs.py test_output.ipynb
python scripts/strip_notebook_outputs.py --check test_output.ipynb
# Expected: exits with code 0 (no outputs found — they were stripped)

# 4. Verify the pre-commit hook catches outputs
#    (recreate the test file with outputs, then try to commit it)
python -c "
import json
nb = {'nbformat': 4, 'nbformat_minor': 5, 'metadata': {}, 'cells': [
  {'cell_type': 'code', 'source': 'print(1)', 'metadata': {},
   'outputs': [{'output_type': 'stream', 'name': 'stdout', 'text': ['1\n']}],
   'execution_count': 1}
]}
with open('test_output.ipynb', 'w') as f: json.dump(nb, f)
"
git add test_output.ipynb
git commit -m "test commit"
# Expected: pre-commit hook runs, strips outputs, commit succeeds with clean notebook

# 5. Clean up
git reset HEAD~1
rm test_output.ipynb
```

---

## Troubleshooting

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| Pre-commit hook doesn't run on commit | Hook not installed in this clone | Run `./setup.sh` or `pre-commit install` from the repo root |
| `git add` doesn't strip outputs | Git clean filter not configured in this clone | Run `./setup.sh` or the three `git config` commands from [Step 3](#step-3-configure-the-git-clean-filter-layer-2) |
| `git add` fails with "required filter 'strip-notebooks' not available" | `.gitattributes` has `required=true` but the filter isn't configured | Run `./setup.sh` — this is the intended behavior forcing developers to set up the filter |
| GitHub Actions check fails on PR | Notebook outputs were committed despite local hooks | Someone pushed without running `./setup.sh`. The CI caught it. Strip outputs locally and push again: `python scripts/strip_notebook_outputs.py *.ipynb && git add -A && git commit --amend` |
| `--check` mode passes but outputs visible in GitHub | Outputs exist in older git history from before hooks were added | Use `git filter-repo` to rewrite history (coordinate with team — this is a destructive operation) |
| `python scripts/strip_notebook_outputs.py` gives "No such file" | Wrong directory, or the script wasn't committed to this repo | Verify you are in the repo root (`ls scripts/strip_notebook_outputs.py` should succeed). If the file is missing, follow [Step 1](#step-1-create-the-strip-script) |
