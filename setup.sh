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
