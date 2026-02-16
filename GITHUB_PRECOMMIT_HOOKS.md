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

## Table of Contents

1. [Threat Model](#threat-model)
2. [Defense Layers](#defense-layers)
3. [Implementation](#implementation)
   - [The Strip Script](#the-strip-script)
   - [Pre-Commit Hook (Layer 1)](#pre-commit-hook-layer-1)
   - [Git Clean Filter (Layer 2)](#git-clean-filter-layer-2)
   - [GitHub Actions (Layer 3)](#github-actions-layer-3)
   - [The Setup Script](#the-setup-script)
   - [Pre-Built Artifacts](#pre-built-artifacts)
4. [Enforceability](#enforceability)
   - [Branch Protection Settings](#branch-protection-settings)
   - [Feature Branch Gap](#feature-branch-gap)
5. [SageMaker Unified Studio V2](#sagemaker-unified-studio-v2)
   - [When to Rerun Setup](#when-to-rerun-setup)
6. [Troubleshooting](#troubleshooting)
7. [Disclaimer](#disclaimer)
8. [License](#license)

---

## Threat Model

Jupyter notebooks store cell outputs (query results, DataFrames, plots) inline in the `.ipynb` JSON. If a user queries a Red (PII) table and commits the notebook, the PII ends up in Git history — visible to anyone with repo access.

```
User queries Red table → Output in notebook JSON → git commit → PII in GitHub
```

The goal: strip ALL outputs from ALL notebooks unconditionally before they reach GitHub. No opt-out, no exceptions.

---

## Defense Layers

| Layer | Where | Mechanism | Enforced? |
|-------|-------|-----------|:---------:|
| 1 | Developer's machine | Pre-commit hook strips outputs before `git commit` | No — `git commit --no-verify` bypasses |
| 2 | Developer's machine | Git clean filter strips outputs on `git add` | No — developer can unset the filter |
| 3 | GitHub server | GitHub Actions blocks PRs with outputs | Yes — with branch protection |

Layers 1 and 2 prevent accidents. Layer 3 prevents policy violations. All three together provide defense-in-depth.

---

## Implementation

### The Strip Script

`scripts/strip_notebook_outputs.py` — zero-dependency Python script that strips all cell outputs, execution counts, and transient metadata. Uses only `json` and `sys` from stdlib. No `nbformat`, no pip packages, no opt-out mechanism.

```python
#!/usr/bin/env python3
"""Strip all outputs and execution counts from Jupyter notebooks."""
import json, sys

STRIP_CELL_METADATA_KEYS = [
    "collapsed", "scrolled", "ExecuteTime", "execution",
    "heading_collapsed", "hidden"
]

def strip_notebook(nb):
    for cell in nb.get("cells", []):
        if "outputs" in cell: cell["outputs"] = []
        if "execution_count" in cell: cell["execution_count"] = None
        if "metadata" in cell:
            for key in STRIP_CELL_METADATA_KEYS: cell["metadata"].pop(key, None)
    nb.get("metadata", {}).pop("signature", None)
    nb.get("metadata", {}).pop("widgets", None)
    return nb

def has_outputs(nb):
    for cell in nb.get("cells", []):
        if cell.get("outputs"): return True
        if cell.get("execution_count") is not None: return True
    return False

def main():
    check_mode = "--check" in sys.argv or "--verify" in sys.argv
    files = [f for f in sys.argv[1:] if not f.startswith("--")]
    if not files and not sys.stdin.isatty():
        nb = json.load(sys.stdin)
        if check_mode: sys.exit(1 if has_outputs(nb) else 0)
        json.dump(strip_notebook(nb), sys.stdout, indent=1, ensure_ascii=False)
        sys.stdout.write("\n")
        return
    failed = False
    for filepath in files:
        if not filepath.endswith(".ipynb"): continue
        with open(filepath, "r", encoding="utf-8") as f: nb = json.load(f)
        if check_mode:
            if has_outputs(nb):
                print(f"FAIL: {filepath} contains outputs", file=sys.stderr)
                failed = True
        else:
            with open(filepath, "w", encoding="utf-8") as f:
                json.dump(strip_notebook(nb), f, indent=1, ensure_ascii=False)
                f.write("\n")
    if check_mode and failed: sys.exit(1)

if __name__ == "__main__": main()
```

### Pre-Commit Hook (Layer 1)

`.pre-commit-config.yaml` in the repo root:

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

Local hook — references the script in the repo. No network fetch at commit time.

### Git Clean Filter (Layer 2)

`.gitattributes` in the repo root (committed to the repo):

```
*.ipynb filter=strip-notebooks
```

Local git config (each developer runs once via `setup.sh`):

```bash
git config filter.strip-notebooks.clean "python scripts/strip_notebook_outputs.py"
git config filter.strip-notebooks.smudge cat
git config filter.strip-notebooks.required true
```

The `required=true` setting makes `git add` fail if the filter isn't configured — forcing developers to run `setup.sh`.

### GitHub Actions (Layer 3)

`.github/workflows/reject-outputs.yaml`:

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
          if [ -z "$NOTEBOOKS" ]; then exit 0; fi
          python scripts/strip_notebook_outputs.py --check $NOTEBOOKS
        continue-on-error: ${{ github.event_name == 'push' }}
      - name: Alert on push with outputs
        if: ${{ github.event_name == 'push' && steps.check.outcome == 'failure' }}
        run: echo "::warning::Notebook outputs detected on branch ${{ github.ref_name }}"
      - name: Fail PR with outputs
        if: ${{ github.event_name == 'pull_request' && steps.check.outcome == 'failure' }}
        run: exit 1
```

On PRs: fails hard, blocks merge. On pushes to feature branches: warns but doesn't fail (push already happened).

### The Setup Script

`setup.sh` in the repo root — installs the pre-commit hook and configures the git clean filter in one command:

```bash
#!/bin/bash
set -e
echo "Configuring git clean filter..."
git config filter.strip-notebooks.clean "python scripts/strip_notebook_outputs.py"
git config filter.strip-notebooks.smudge cat
git config filter.strip-notebooks.required true
echo "Installing pre-commit hooks..."
pip install pre-commit
pre-commit install
echo "Done. Notebook output stripping is configured."
```

### Pre-Built Artifacts

All five files are in the repo root:

```
your-notebook-repo/
├── scripts/strip_notebook_outputs.py
├── .pre-commit-config.yaml
├── .gitattributes
├── .github/workflows/reject-outputs.yaml
└── setup.sh
```

---

## Enforceability

### Branch Protection Settings

Configure on `main` (GitHub → Repo → Settings → Branches):

| Setting | Value |
|---------|-------|
| Require status checks to pass | `check-outputs` selected |
| Require branches to be up to date | Yes |
| Restrict who can push to main | Team leads only |
| Do not allow bypassing | Enabled |
| Allow force pushes | Disabled |

With these settings, unstripped notebooks cannot reach `main`.

### Feature Branch Gap

Branch protection only gates merges to `main`. Outputs can exist on feature branches if a developer bypasses local hooks. Mitigations:

- The GitHub Actions workflow detects outputs on push to any branch (warning only)
- GitHub push rulesets (GitHub Team plan) can block large `.ipynb` files by file size
- Regional repo separation limits who can see branch data
- Auto-delete feature branches after merge to reduce exposure window

---

## SageMaker Unified Studio V2

When creating a project, select "Git repository" under Tooling and choose "Existing repository and new branch". Unified Studio auto-creates a project-specific branch and clones the repo into `~/src/`.

Open a terminal in JupyterLab (click "+" → Terminal) and run:

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

The code artifacts in this document and in `notebook-repo-artifacts/` are licensed under the Apache License, Version 2.0. You may obtain a copy of the license at https://www.apache.org/licenses/LICENSE-2.0.

Unless required by applicable law or agreed to in writing, software distributed under this license is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and limitations under the License.
