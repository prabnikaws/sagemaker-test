# Notebook Output Stripping and Protection

Prevents PII leakage through Jupyter notebook outputs committed to GitHub. Three defense layers: pre-commit hooks (local), git clean filters (local), and GitHub Actions (server).

## TL;DR

### 1. GitHub Admin: Add artifacts to `main`

Add these five files to the notebook repo's `main` branch:

```
your-notebook-repo/  (main branch)
├── scripts/
│   └── strip_notebook_outputs.py    ← Strips outputs from .ipynb files
├── .pre-commit-config.yaml          ← Pre-commit hook config
├── .gitattributes                   ← Git clean filter config
├── .github/
│   └── workflows/
│       └── reject-outputs.yaml      ← GitHub Actions CI
└── setup.sh                         ← One-command setup for developers
```

Configure branch protection on `main` with `check-outputs` as a required status check.

### 2. Project Admin: Create a project with Git repository

In SageMaker Unified Studio, create a project. In Step 2 ("Customize blueprint parameters"):
- Under Tooling, select "Git repository"
- Choose your AWS CodeConnections connection
- Select "Existing repository and new branch"
- Select the notebook repo from the dropdown
- Enter the branch name — copy and paste the project name

### 3. User: Run setup once

- Go to your new project
- Create a notebook (New → Notebook)
- Launch a terminal (File → New → Terminal) and run:

```bash
cd ~/src
bash setup.sh
```

Every `git commit` now strips notebook outputs automatically. If your JupyterLab space is ever deleted and recreated (not just stopped/restarted), run `bash setup.sh` again.

---

## Table of Contents

1. [What This Does](#what-this-does)
2. [File Inventory](#file-inventory)
3. [For Admins: Initial Setup](#for-admins-initial-setup)
4. [For Users: Getting Started](#for-users-getting-started)
5. [How It Works](#how-it-works)
6. [Enforceability](#enforceability)
   - [Branch Protection Settings](#branch-protection-settings)
   - [Feature Branch Gap](#feature-branch-gap)
7. [SageMaker Unified Studio V2](#sagemaker-unified-studio-v2)
   - [When to Rerun Setup](#when-to-rerun-setup)
8. [Troubleshooting](#troubleshooting)
9. [Disclaimer](#disclaimer)
10. [License](#license)

---

## What This Does

Jupyter notebooks (`.ipynb` files) store cell outputs inline in the JSON file. If a user queries a Red (PII) table and commits the notebook, the PII ends up in Git history. These artifacts prevent that with three layers:

| Layer | Where | What It Does | Enforced? |
|-------|-------|-------------|:---------:|
| Pre-commit hook | Developer's machine | Strips outputs automatically before `git commit` completes | No — `git commit --no-verify` bypasses |
| Git clean filter | Developer's machine | Strips outputs on `git add`, even if the pre-commit hook isn't installed | No — developer can unset the filter |
| GitHub Actions | GitHub server | Blocks any PR to `main` that contains notebook outputs | Yes — with branch protection |

Layers 1 and 2 prevent accidents. Layer 3 prevents policy violations. All three together provide defense-in-depth.

---

## File Inventory

```
your-notebook-repo/
├── scripts/
│   └── strip_notebook_outputs.py          ← Zero-dependency Python script that strips outputs
├── .pre-commit-config.yaml                ← Pre-commit hook configuration (Layer 1)
├── .gitattributes                         ← Git clean filter configuration (Layer 2)
├── .github/
│   └── workflows/
│       └── reject-outputs.yaml            ← GitHub Actions workflow (Layer 3)
└── setup.sh                               ← One-command setup for developers
```

---

## For Admins: Initial Setup

1. Copy the five files to your notebook repo's `main` branch (see [File Inventory](#file-inventory) above).

2. Set executable permissions, commit, and push:

```bash
cd /path/to/your-notebook-repo
chmod +x setup.sh scripts/strip_notebook_outputs.py
git add -A
git commit -m "Add notebook output stripping (pre-commit + clean filter + CI)"
git push origin main
```

3. Configure GitHub branch protection on `main`:

| Setting | Value |
|---------|-------|
| Require status checks to pass | `check-outputs` selected |
| Require branches to be up to date | Yes |
| Restrict who can push to main | Team leads only |
| Do not allow bypassing | Enabled |
| Allow force pushes | Disabled |

4. Repeat for each regional notebook repo.

---

## For Users: Getting Started

1. Open SageMaker Unified Studio → your project → launch JupyterLab
2. Open a terminal (File → New → Terminal)
3. Navigate to your notebook repo:

```bash
cd ~/src
```

4. Run the setup script:

```bash
bash setup.sh
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
- If you forget to set up, the `.gitattributes` `required=true` setting causes `git add` to fail, reminding you to run `bash setup.sh`

You only need to run `bash setup.sh` once per JupyterLab space. If your space is deleted and recreated, run it again.

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

## Enforceability

### Branch Protection Settings

With the settings in [For Admins: Initial Setup](#for-admins-initial-setup), unstripped notebooks cannot reach `main`.

### Feature Branch Gap

Branch protection only gates merges to `main`. Outputs can exist on feature branches if a developer bypasses local hooks. Mitigations:

- The GitHub Actions workflow detects outputs on push to any branch (warning only)
- GitHub push rulesets (GitHub Team plan) can block large `.ipynb` files by file size
- Regional repo separation limits who can see branch data
- Auto-delete feature branches after merge to reduce exposure window

---

## SageMaker Unified Studio V2

When creating a project, select "Git repository" under Tooling and choose "Existing repository and new branch". Unified Studio auto-creates a project-specific branch and clones the repo into `~/src/`.

Open a terminal in JupyterLab (File → New → Terminal) and run:

```bash
cd ~/src
bash setup.sh
```

The setup survives JupyterLab stop/restart cycles because the repo and git config live on the persistent EBS volume.

### When to Rerun Setup

| Scenario | Rerun `setup.sh`? | Why |
|----------|:-----------------:|-----|
| JupyterLab stopped and restarted | No | EBS volume persists — hooks and config survive |
| JupyterLab idle timeout | No | Same as stop/restart |
| JupyterLab space deleted and recreated | Yes | New EBS volume — everything is gone. The repo is re-cloned automatically but hooks need to be reinstalled. |
| Project deleted and recreated | Yes | New space, new EBS volume |
| Different user on the same project | Yes | Each user has their own JupyterLab space and EBS volume |

The key distinction: stopping/restarting preserves the EBS volume. Deleting the space destroys it.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| Pre-commit hook doesn't run | Hook not installed | Run `bash setup.sh` from `~/src/` |
| `git add` fails with "required filter not available" | Git clean filter not configured | Run `bash setup.sh` — this error is intentional |
| GitHub Actions check fails on PR | Outputs committed without local hooks | Strip and re-push: `python scripts/strip_notebook_outputs.py *.ipynb && git add -A && git commit --amend` |
| `setup.sh` fails with "permission denied" | Script not executable | Run `bash setup.sh` instead of `./setup.sh` |
| Hooks were working but stopped after space recreation | JupyterLab space was deleted and recreated (new EBS volume) | Run `bash setup.sh` again from `~/src/` |
| Different user doesn't have hooks | Each user has their own JupyterLab space | Each user must run `bash setup.sh` once in their own space |
| JupyterLab git UI commits without stripping | The sidebar git extension may not trigger hooks | The git clean filter (Layer 2) should still catch it. Layer 3 (GitHub Actions) is the final safety net. |

---

## Disclaimer

This pattern is provided as-is, without warranty of any kind, express or implied. The authors and contributors make no guarantees regarding the completeness, reliability, or suitability of this approach for any particular purpose. Use at your own risk.

This solution reduces the likelihood of accidental PII exposure through notebook outputs but does not eliminate all risk. Local hooks (Layers 1 and 2) can be bypassed by users. The server-side check (Layer 3) depends on correct GitHub branch protection configuration. No combination of these controls constitutes a guarantee that PII will never appear in Git history.

You are responsible for validating that this approach meets your organization's security and compliance requirements before deploying to production environments.

## License

Licensed under the Apache License, Version 2.0. You may obtain a copy of the license at https://www.apache.org/licenses/LICENSE-2.0.

Unless required by applicable law or agreed to in writing, software distributed under this license is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and limitations under the License.
