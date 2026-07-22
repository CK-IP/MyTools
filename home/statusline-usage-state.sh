#!/bin/bash
set -euo pipefail

resolve_repo_root() {
  local source_path="${BASH_SOURCE[0]}"
  local script_dir link_target

  while [ -h "$source_path" ]; do
    script_dir="$(cd -P "$(dirname -- "$source_path")" && pwd)" || return 1
    link_target="$(readlink -- "$source_path")" || return 1
    case "$link_target" in
      /*) source_path="$link_target" ;;
      *) source_path="$script_dir/$link_target" ;;
    esac
  done

  script_dir="$(cd -P "$(dirname -- "$source_path")" && pwd)" || return 1
  cd "$script_dir/.." && pwd
}

repo_root=""
if repo_root="$(resolve_repo_root)"; then
  :
fi

state_dir="${HOME:-$PWD}/.claude"
state_file="$state_dir/usage-state.json"
dispatcher="$state_dir/statusline.sh"
now="$(date -u +%s)"
payload_file="$(mktemp "${TMPDIR:-/tmp}/statusline-usage-XXXXXX")"
trap 'rm -f "$payload_file"' EXIT

cat >"$payload_file"

if [ -n "$repo_root" ] && PYTHONPATH="$repo_root${PYTHONPATH:+:$PYTHONPATH}" \
  python3 -m sail usage-state write --out "$state_file" --now "$now" <"$payload_file" >/dev/null 2>&1; then
  :
fi

if [ -x "$dispatcher" ]; then
  cat "$payload_file" | "$dispatcher"
fi
