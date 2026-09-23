# Shared helpers for CybexOS upstream installer scripts.
# Source this file; do not execute it. Installed at /usr/local/libexec/cybexos-common.sh.
# shellcheck shell=bash

# gh_api_fetch <url> <cache_dir> <out_file>
# GitHub API GET with ETag caching. A 304 reuses the cached body and does not
# count against the anonymous rate limit. GH_TOKEN is honored when set.
gh_api_fetch() {
  local url=$1 cache_dir=$2 out=$3
  local headers=(-H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28')
  [[ -z ${GH_TOKEN:-} ]] || headers+=(-H "Authorization: Bearer $GH_TOKEN")
  mkdir -p "$cache_dir"
  local etag="$cache_dir/etag" body="$cache_dir/response.json" code
  local compare=()
  [[ -r $etag && -s $body ]] && compare=(--etag-compare "$etag")
  code=$(curl --silent --show-error --location "${headers[@]}" "${compare[@]}" \
    --etag-save "$etag.new" --write-out '%{http_code}' \
    --output "$body.new" "$url") || {
    rm -f "$etag.new" "$body.new"
    echo "GitHub API request failed for $url. Set GH_TOKEN if the anonymous limit was reached." >&2
    return 1
  }
  if [[ $code == 200 && -s $body.new ]] && jq -e . "$body.new" >/dev/null 2>&1; then
    mv -f "$body.new" "$body"
    if [[ -s $etag.new ]]; then mv -f "$etag.new" "$etag"; else rm -f "$etag.new" "$etag"; fi
  elif [[ $code == 304 ]]; then
    rm -f "$body.new" "$etag.new"
    if ! jq -e . "$body" >/dev/null 2>&1; then
      # A truncated cached response must not make every subsequent 304 fail.
      rm -f "$body" "$etag"
      gh_api_fetch "$url" "$cache_dir" "$out"
      return
    fi
  else
    rm -f "$body.new" "$etag.new"
    echo "GitHub API returned HTTP $code for $url. Set GH_TOKEN if the anonymous limit was reached." >&2
    return 1
  fi
  cat "$body" >"$out"
}

# atomic_current_swap <root> <relative_target>
# Repoint <root>/current at <relative_target> without a broken-link window.
atomic_current_swap() {
  local root=$1 target=$2
  ln -sfn "$target" "$root/current.new"
  mv -Tf "$root/current.new" "$root/current"
}

# prune_version_dirs <root> [keep]
# Keep the active deployment plus the newest inactive versions. The helper is
# deliberately constrained to an install root's versions/ child.
prune_version_dirs() {
  local root=$1 keep=${2:-3} current path inactive_limit retained_inactive=0
  [[ $keep =~ ^[1-9][0-9]*$ && -d $root/versions ]] || return 0
  current=$(readlink -f "$root/current" 2>/dev/null || true)
  inactive_limit=$keep
  if [[ -n $current && $current == "$root/versions/"* && -d $current ]]; then
    inactive_limit=$((keep - 1))
  fi
  while IFS= read -r path; do
    if [[ $(readlink -f "$path") == "$current" ]]; then
      continue
    fi
    if (( retained_inactive < inactive_limit )); then
      ((retained_inactive += 1))
      continue
    fi
    [[ $path == "$root/versions/"* && $path != "$root/versions" ]] || return 1
    rm -rf -- "$path"
  done < <(find "$root/versions" -mindepth 1 -maxdepth 1 -type d \
    -printf '%T@ %p\n' | sort -rn | cut -d' ' -f2-)
}

# verify_sha256 <file> <expected_hex>
verify_sha256() {
  local actual
  actual=$(sha256sum "$1" | awk '{print $1}')
  [[ $actual == "$2" ]]
}

emit_changed() { echo "CHANGED: $*"; }
emit_unchanged() { echo "UNCHANGED: $*"; }

cybexos_restorecon() { restorecon -RF "$@" 2>/dev/null || true; }
