#!/usr/bin/env bash
set -euo pipefail

# Delete old Portworx Pure FlashArray volumes for a lab rebuild.
# Targets only volumes whose names match:
#   pxclouddrive-*
#   px_*pvc-*
#
# Defaults match the POD22 lab. Override with:
#   PURE_ARRAY=pureuser@10.23.22.50 ./scripts/cleanup-pure-portworx-volumes.sh
# or:
#   PURE_ARRAY_USER=pureuser PURE_ARRAY_HOST=10.23.22.50 ./scripts/cleanup-pure-portworx-volumes.sh
#
# The script opens one SSH ControlMaster connection so the Pure password is entered once.

PURE_ARRAY_HOST="${PURE_ARRAY_HOST:-10.23.22.50}"
PURE_ARRAY_USER="${PURE_ARRAY_USER:-pureuser}"
ARRAY="${PURE_ARRAY:-${PURE_ARRAY_USER}@${PURE_ARRAY_HOST}}"
WORKDIR="${WORKDIR:-/tmp/pure-portworx-volume-cleanup}"
CONFIRM_TOKEN="DELETE_PORTWORX_FLASHARRAY_VOLUMES"
CONTROL_PATH="${WORKDIR}/pure-ssh-control-%h-%p-%r"

MATCHES="${WORKDIR}/matching-volumes.txt"
HOSTS_FILE="${WORKDIR}/hosts.txt"
HGROUPS_FILE="${WORKDIR}/hgroups.txt"
CONNECTIONS="${WORKDIR}/matching-connections.txt"

mkdir -p "$WORKDIR"

run_pure() {
  ssh -S "$CONTROL_PATH" "$ARRAY" "$@"
}

close_control_socket() {
  ssh -S "$CONTROL_PATH" -O exit "$ARRAY" >/dev/null 2>&1 || true
}
trap close_control_socket EXIT

cat <<MSG
Pure FlashArray Portworx volume cleanup
=======================================
Array:   $ARRAY
Workdir: $WORKDIR
Targets: pxclouddrive-* and px_*pvc-*

This is destructive and intended only for lab rebuilds where Portworx/Pure data
can be discarded.
MSG

echo
echo "Opening one persistent SSH connection. Enter the Pure password once:"
ssh -M -S "$CONTROL_PATH" -fN -o ControlPersist=30m "$ARRAY"

echo
echo "### Finding matching Portworx volumes"
run_pure "purevol list --csv --notitle" | awk -F, '
{
  gsub(/"/,"",$1)
  if ($1 ~ /^pxclouddrive-/ || $1 ~ /^px_.*pvc-/) print $1
}' | sort -u > "$MATCHES"

if [[ ! -s "$MATCHES" ]]; then
  echo "No pxclouddrive-* or px_*pvc-* volumes found."
  exit 0
fi

cat "$MATCHES"
echo
echo "Matched volume count: $(wc -l < "$MATCHES")"

echo
echo "### Finding Pure hosts and host groups"
run_pure "purehost list --csv --notitle" | awk -F, '{gsub(/"/,"",$1); if ($1 != "") print $1}' | sort -u > "$HOSTS_FILE"
run_pure "purehgroup list --csv --notitle" | awk -F, '{gsub(/"/,"",$1); if ($1 != "") print $1}' | sort -u > "$HGROUPS_FILE"

echo "Hosts:"
cat "$HOSTS_FILE" || true
echo
echo "Host groups:"
cat "$HGROUPS_FILE" || true

echo
echo "### Current connections for matching volumes"
: > "$CONNECTIONS"
while read -r vol; do
  [[ -z "$vol" ]] && continue
  echo "----- $vol -----" | tee -a "$CONNECTIONS"
  run_pure "purevol list --connect '$vol'" 2>&1 | tee -a "$CONNECTIONS" || true
  echo | tee -a "$CONNECTIONS"
done < "$MATCHES"

echo
echo "Type ${CONFIRM_TOKEN} to disconnect from all hosts/hostgroups, destroy, and eradicate:"
read -r CONFIRM

if [[ "$CONFIRM" != "$CONFIRM_TOKEN" ]]; then
  echo "Aborted."
  exit 1
fi

echo
echo "### Disconnecting matched volumes from every Pure host"
while read -r vol; do
  [[ -z "$vol" ]] && continue
  while read -r host; do
    [[ -z "$host" ]] && continue
    echo "Disconnect volume=$vol host=$host"
    run_pure "purevol disconnect --host '$host' '$vol'" || true
  done < "$HOSTS_FILE"
done < "$MATCHES"

echo
echo "### Disconnecting matched volumes from every Pure host group"
while read -r vol; do
  [[ -z "$vol" ]] && continue
  while read -r hgroup; do
    [[ -z "$hgroup" ]] && continue
    echo "Disconnect volume=$vol hgroup=$hgroup"
    run_pure "purevol disconnect --hgroup '$hgroup' '$vol'" || true
  done < "$HGROUPS_FILE"
done < "$MATCHES"

echo
echo "### Remaining connections after disconnect attempts"
while read -r vol; do
  [[ -z "$vol" ]] && continue
  echo
  echo "Connections for $vol:"
  run_pure "purevol list --connect '$vol'" || true
done < "$MATCHES"

echo
echo "### Destroying matched volumes"
while read -r vol; do
  [[ -z "$vol" ]] && continue
  echo "Destroy $vol"
  run_pure "purevol destroy '$vol'" || true
done < "$MATCHES"

echo
echo "### Eradicating matched volumes"
while read -r vol; do
  [[ -z "$vol" ]] && continue
  echo "Eradicate $vol"
  run_pure "purevol eradicate '$vol'" || true
done < "$MATCHES"

echo
echo "### Final active-volume check"
run_pure "purevol list --csv --notitle" | awk -F, '
{
  gsub(/"/,"",$1)
  if ($1 ~ /^pxclouddrive-/ || $1 ~ /^px_.*pvc-/) print $1
}' | sort -u || true

echo
echo "### Final pending/destroyed-volume check"
run_pure "purevol list --pending --csv --notitle" 2>/dev/null | awk -F, '
{
  gsub(/"/,"",$1)
  if ($1 ~ /^pxclouddrive-/ || $1 ~ /^px_.*pvc-/) print $1
}' | sort -u || true

echo
echo "Done. If volumes remain only in the pending/destroyed list, Pure SafeMode may be delaying eradication."
