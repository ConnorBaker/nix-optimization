#!/usr/bin/env bash
set -euo pipefail

task_nix=${1:?usage: cold-eval.sh /path/to/nix flake#attribute [runs] [timeout-seconds] [tarmac|dummy]}
task_target=${2:?usage: cold-eval.sh /path/to/nix flake#attribute [runs] [timeout-seconds] [tarmac|dummy]}
task_runs=${3:-20}
task_timeout=${4:-20}
task_mode=${5:-tarmac}
task_tmp=$(mktemp -d)
printf 'Logs: %s\n' "$task_tmp"

case "$task_mode" in
  tarmac) task_options=() ;;
  # DummyStore cannot validate signatures. Trust only this public cache for
  # this disposable, in-memory control; no build-store settings are changed.
  dummy) task_options=(--option substituters 'https://cache.nixos.org?trusted=true') ;;
  *) printf 'Unknown store mode: %s\n' "$task_mode" >&2; exit 2 ;;
esac

for ((task_run = 1; task_run <= task_runs; task_run++)); do
  task_store="tarmac://$task_tmp/store-$task_run"
  if [[ "$task_mode" == dummy ]]; then
    task_store='dummy://?read-only=false'
  fi
  task_start=$SECONDS
  if timeout "$task_timeout" "$task_nix" "${task_options[@]}" \
    --option eval-store "$task_store" eval --raw --no-eval-cache "$task_target" \
    > "$task_tmp/run-$task_run.log" 2>&1; then
    task_exit=0
  else
    task_exit=$?
  fi
  printf 'run=%s exit=%s seconds=%s\n' "$task_run" "$task_exit" "$((SECONDS-task_start))"
  if ((task_exit != 0)); then
    printf 'Failed run log: %s/run-%s.log\n' "$task_tmp" "$task_run" >&2
    exit "$task_exit"
  fi
  # Keep the logs, but only retain a store if a run fails.
  rm -rf "$task_tmp/store-$task_run"
done
