#!/usr/bin/env bash
set -euo pipefail

# Bootstrap the Ansible bastion for this repo on Ubuntu 24.04.x LTS.
# Usage:
#   ./scripts/bootstrap-ubuntu-24.04.sh
#   OPENSHIFT_VERSION=x.y.z ./scripts/bootstrap-ubuntu-24.04.sh
# The exact OpenShift release defaults to ocp_release_version in main.yml.
# Override only with an exact x.y.z version when intentionally testing another release.

OPENSHIFT_VERSION="${OPENSHIFT_VERSION:-}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! grep -q '^ID=ubuntu' /etc/os-release; then
  echo "This bootstrap script is intended for Ubuntu 24.04.x LTS." >&2
  exit 1
fi

source /etc/os-release
if [[ "${VERSION_ID}" != 24.04* ]]; then
  echo "Warning: detected Ubuntu ${VERSION_ID}; this repo is tested for Ubuntu 24.04.x LTS." >&2
fi

sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  apache2-utils \
  ca-certificates \
  curl \
  dnsutils \
  genisoimage \
  git \
  gzip \
  iproute2 \
  iputils-ping \
  jq \
  netcat-openbsd \
  openssh-client \
  openssl \
  pipx \
  python3 \
  python3-full \
  python3-pip \
  python3-venv \
  software-properties-common \
  sshpass \
  tar \
  unzip \
  wget \
  xz-utils

cd "${REPO_ROOT}"
python3 -m venv .venv
# shellcheck source=/dev/null
source .venv/bin/activate
python -m pip install --upgrade pip wheel setuptools
python -m pip install -r requirements-python.txt
ansible-galaxy collection install -r requirements.yml

if [[ -z "$OPENSHIFT_VERSION" ]]; then
  OPENSHIFT_VERSION="$(./scripts/lib/inventory-value.py --file inventories/env/group_vars/all/main.yml ocp_release_version)"
fi

# The OpenShift Agent-based Installer calls nmstatectl locally when static
# networking is present in agent-config.yaml. Ubuntu 24.04 images do not always
# have a native apt nmstate package, so use the helper with a pip fallback.
./scripts/install-nmstatectl-ubuntu.sh

# Install the exact tools pinned by main.yml into .venv/bin. This avoids
# depending on or overwriting system-wide OpenShift binaries.
OPENSHIFT_VERSION="${OPENSHIFT_VERSION}" \
INSTALL_BIN_DIR="${REPO_ROOT}/.venv/bin" \
FORCE_SYNC_OPENSHIFT_TOOLS=true \
  ./scripts/sync-openshift-tools.sh

cat <<DONE

Ubuntu bastion bootstrap complete.

Next commands:
  cd ${REPO_ROOT}
  source .venv/bin/activate
  oc version --client
  openshift-install version
  ansible --version
  ansible-playbook -i inventories/env/hosts.yml playbooks/00_preflight.yml --ask-vault-pass

OpenShift client/installer version:
  ${OPENSHIFT_VERSION}

Repo-local binary directory:
  ${REPO_ROOT}/.venv/bin

DONE
