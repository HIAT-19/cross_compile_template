#!/usr/bin/env bash
#
# Bash completion for ./build.sh
# Usage (manual):
#   source /path/to/project/scripts/buildsh_completion.bash
#

_buildsh__list_targets() {
  local root="${HOST_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  local build_dir="${HOST_BUILD_DIR_NAME:-build-aarch64}"
  local bin_subdir="${HOST_BIN_SUBDIR:-bin}"

  local d
  for d in "${root}/${build_dir}/Debug/${bin_subdir}" "${root}/${build_dir}/Release/${bin_subdir}"; do
    if [[ -d "${d}" ]]; then
      # Print only executable files (best-effort)
      find "${d}" -maxdepth 1 -type f -executable -printf '%f\n' 2>/dev/null
    fi
  done | sort -u
}

_buildsh_completion() {
  local cur prev
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD-1]}"

  local commands="setup-env clean debug release debug-start debug-stop debug-logs help --help -h"
  local dests="docker device"

  # If completing the first arg after build.sh, offer commands
  if [[ ${COMP_CWORD} -eq 1 ]]; then
    COMPREPLY=( $(compgen -W "${commands}" -- "${cur}") )
    return 0
  fi

  # Detect command (first non-option token)
  local cmd="${COMP_WORDS[1]}"

  case "${cmd}" in
    debug-start)
      case "${prev}" in
        --dest)
          COMPREPLY=( $(compgen -W "${dests}" -- "${cur}") )
          return 0
          ;;
        --target)
          COMPREPLY=( $(compgen -W "$(_buildsh__list_targets)" -- "${cur}") )
          return 0
          ;;
      esac
      COMPREPLY=( $(compgen -W "--dest --target" -- "${cur}") )
      return 0
      ;;

    debug-stop|debug-logs)
      case "${prev}" in
        --dest)
          COMPREPLY=( $(compgen -W "${dests}" -- "${cur}") )
          return 0
          ;;
      esac
      COMPREPLY=( $(compgen -W "--dest" -- "${cur}") )
      return 0
      ;;
  esac

  COMPREPLY=()
  return 0
}

# Complete both "build.sh" and "./build.sh"
complete -F _buildsh_completion build.sh ./build.sh


