#!/usr/bin/env bash
set -euo pipefail

# Bootstrap the Ansible bastion for this repo on Ubuntu 24.04.x LTS.
# Usage:
#   ./scripts/bootstrap-ubuntu-24.04.sh
#   OPENSHIFT_VERSION=4.21.0 ./scripts/bootstrap-ubuntu-24.04.sh
#   OPENSHIFT_VERSION=stable-4.21 ./scripts/bootstrap-ubuntu-24.04.sh

OPENSHIFT_VERSION="${OPENSHIFT_VERSION:-stable-4.21}"
INSTALL_BIN_DIR="${INSTALL_BIN_DIR:-/usr/local/bin}"
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

# The OpenShift Agent-based Installer calls nmstatectl locally when static
# networking is present in agent-config.yaml. Ubuntu 24.04 images do not always
# have a native apt nmstate package, so use the helper with a pip fallback.
./scripts/install-nmstatectl-ubuntu.sh

tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

client_url="https://mirror.openshift.com/pub/openshift-v4/clients/ocp/${OPENSHIFT_VERSION}/openshift-client-linux.tar.gz"
installer_url="https://mirror.openshift.com/pub/openshift-v4/clients/ocp/${OPENSHIFT_VERSION}/openshift-install-linux.tar.gz"

curl -fsSL "${client_url}" -o "${tmpdir}/openshift-client-linux.tar.gz"
tar -xzf "${tmpdir}/openshift-client-linux.tar.gz" -C "${tmpdir}" oc kubectl
sudo install -m 0755 "${tmpdir}/oc" "${INSTALL_BIN_DIR}/oc"
sudo install -m 0755 "${tmpdir}/kubectl" "${INSTALL_BIN_DIR}/kubectl"

curl -fsSL "${installer_url}" -o "${tmpdir}/openshift-install-linux.tar.gz"
tar -xzf "${tmpdir}/openshift-install-linux.tar.gz" -C "${tmpdir}" openshift-install
sudo install -m 0755 "${tmpdir}/openshift-install" "${INSTALL_BIN_DIR}/openshift-install"

cat <<DONE

Ubuntu bastion bootstrap complete.

Next commands:
  cd ${REPO_ROOT}
  source .venv/bin/activate
  oc version --client
  openshift-install version
  ansible --version
  ansible-playbook -i inventories/pod22/hosts.yml playbooks/00_preflight.yml --ask-vault-pass

OpenShift client/installer source:
  ${OPENSHIFT_VERSION}

DONE
