#!/usr/bin/env bash
set -euo pipefail

REPO_NAME="${1:-ocp-sno-vsphere-ansible}"

if ! command -v gh >/dev/null 2>&1; then
  echo "GitHub CLI 'gh' is not installed. Install it or create the repo manually."
  exit 1
fi

git init
git add .
git commit -m "Initial SNO vSphere Ansible automation scaffold"
gh repo create "$REPO_NAME" --private --source=. --remote=origin --push
