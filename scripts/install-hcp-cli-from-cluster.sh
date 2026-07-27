#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
# shellcheck source=scripts/lib/inventory-env.sh
source "$ROOT_DIR/scripts/lib/inventory-env.sh"

if [ "$#" -lt 2 ]; then
  echo "Usage: $0 <primary-kubeconfig> <destination-hcp-path> [fallback-kubeconfig ...]" >&2
  exit 2
fi

DEST="${2}"
DEST_DIR="$(dirname "$DEST")"
mkdir -p "$DEST_DIR"

# Keep all kubeconfigs except empty/non-files, preserving order and de-duping.
declare -a KUBECONFIGS=()
seen=""
for kc in "$1" "${@:3}"; do
  [ -n "${kc:-}" ] || continue
  [ -f "$kc" ] || continue
  case " $seen " in
    *" $kc "*) ;;
    *) KUBECONFIGS+=("$kc"); seen="$seen $kc" ;;
  esac
done

if [ "${#KUBECONFIGS[@]}" -eq 0 ]; then
  echo "No readable kubeconfig was supplied." >&2
  exit 2
fi

if [ -x "$DEST" ]; then
  "$DEST" version || true
  exit 0
fi

if command -v hcp >/dev/null 2>&1; then
  cp "$(command -v hcp)" "$DEST"
  chmod +x "$DEST"
  "$DEST" version || true
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

resolve_url() {
  local href="$1"
  local console_base="$2"
  if [[ "$href" =~ ^https?:// ]]; then
    printf '%s\n' "$href"
  elif [[ "$href" == /* ]] && [ -n "$console_base" ]; then
    printf '%s%s\n' "$console_base" "$href"
  else
    printf '%s\n' "$href"
  fi
}

try_extract_hcp() {
  local archive="$1"
  local extract_dir="$2"

  rm -rf "$extract_dir"
  mkdir -p "$extract_dir"

  if tar -tzf "$archive" >/dev/null 2>&1; then
    tar -xzf "$archive" -C "$extract_dir"
  elif command -v unzip >/dev/null 2>&1 && unzip -tq "$archive" >/dev/null 2>&1; then
    unzip -q "$archive" -d "$extract_dir"
  else
    return 1
  fi

  local found
  found="$(find "$extract_dir" -type f -name hcp -perm /111 2>/dev/null | head -1 || true)"
  if [ -z "$found" ]; then
    found="$(find "$extract_dir" -type f -name hcp 2>/dev/null | head -1 || true)"
  fi
  if [ -z "$found" ]; then
    return 1
  fi

  cp "$found" "$DEST"
  chmod +x "$DEST"
  "$DEST" version || true
  return 0
}

candidate_urls_for_kubeconfig() {
  local kc="$1"
  local name json
  for name in hcp-cli-download hypershift-cli-download; do
    if ! json="$(oc --kubeconfig "$kc" get consoleclidownload "$name" -o json 2>/dev/null)"; then
      continue
    fi
    python3 -c '
import json, sys
obj=json.load(sys.stdin)
links=obj.get("spec",{}).get("links",[])

def score(link):
    blob=((link.get("text") or "")+" "+(link.get("href") or "")).lower()
    s=0
    if "linux" in blob: s += 10
    if any(x in blob for x in ("amd64", "x86_64", "x86-64", "x64")): s += 5
    if any(x in blob for x in ("arm", "ppc", "s390", "mac", "darwin", "windows")): s -= 10
    if "tar" in blob or "tgz" in blob or "gz" in blob: s += 2
    return s
seen=set()
for link in sorted(links, key=score, reverse=True):
    href=link.get("href") or ""
    blob=((link.get("text") or "")+" "+href).lower()
    if not href or href in seen:
        continue
    if "linux" in blob and not any(x in blob for x in ("arm", "ppc", "s390", "mac", "darwin", "windows")):
        seen.add(href); print(href)
for link in sorted(links, key=score, reverse=True):
    href=link.get("href") or ""
    if href and href not in seen:
        seen.add(href); print(href)
' <<<"$json"
  done
}

debug_download_objects() {
  local kc="$1"
  echo "Available ConsoleCLIDownload objects on $(oc --kubeconfig "$kc" whoami --show-server 2>/dev/null || echo "$kc"):" >&2
  oc --kubeconfig "$kc" get consoleclidownload 2>/dev/null >&2 || true
  echo "hcp CLI related routes/services, if present:" >&2
  oc --kubeconfig "$kc" get route,svc,endpointslice -A 2>/dev/null | grep -Ei 'hcp.*cli|hypershift.*cli|cli.*download|multicluster-engine' >&2 || true
}

attempt=0
for kc in "${KUBECONFIGS[@]}"; do
  server="$(oc --kubeconfig "$kc" whoami --show-server 2>/dev/null || true)"
  echo "Looking for hcp CLI download links using kubeconfig: $kc" >&2
  [ -n "$server" ] && echo "Cluster API: $server" >&2

  TOKEN="$(oc --kubeconfig "$kc" whoami -t 2>/dev/null || true)"
  CONSOLE_BASE="$(oc --kubeconfig "$kc" -n openshift-console get route console -o jsonpath='https://{.spec.host}' 2>/dev/null || true)"
  URLS="$(candidate_urls_for_kubeconfig "$kc" || true)"

  if [ -z "$URLS" ]; then
    echo "No hcp ConsoleCLIDownload links found from $kc" >&2
    debug_download_objects "$kc"
    continue
  fi

  while IFS= read -r href; do
    [ -n "$href" ] || continue
    url="$(resolve_url "$href" "$CONSOLE_BASE")"
    attempt=$((attempt + 1))
    archive="$TMP/hcp-${attempt}.download"
    extract_dir="$TMP/extract-${attempt}"

    echo "Trying hcp CLI download: $url" >&2
    if [ -n "$TOKEN" ]; then
      if ! curl -kfsSL -H "Authorization: Bearer ${TOKEN}" "$url" -o "$archive"; then
        echo "Download failed for $url" >&2
        continue
      fi
    else
      if ! curl -kfsSL "$url" -o "$archive"; then
        echo "Download failed for $url" >&2
        continue
      fi
    fi

    if try_extract_hcp "$archive" "$extract_dir"; then
      echo "Installed hcp CLI to $DEST" >&2
      exit 0
    fi

    echo "Downloaded file from $url was not a valid hcp archive." >&2
    echo "First lines of response were:" >&2
    head -40 "$archive" >&2 || true
    echo >&2
    echo "Trying next hcp CLI link if one exists..." >&2
  done <<<"$URLS"

done

echo "Failed to install hcp CLI from ConsoleCLIDownload." >&2
echo "In this lab that usually means the spoke route hcp-cli-download-multicluster-engine.apps.<site>.<base_domain from main.yml> is returning 503." >&2
echo "The repo now tries the hub kubeconfig first, then the site kubeconfig, but no valid hcp archive was found." >&2
echo "Manual workaround: download hcp from the hub OpenShift Console -> Help -> Command Line Tools, place it at: $DEST, then rerun the playbook." >&2
exit 2
