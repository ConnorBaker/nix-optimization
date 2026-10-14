#!/usr/bin/env bash
set -euo pipefail

task_nix=${1:?usage: tarmac.sh /path/to/nix /path/to/nixpkgs}
task_nixpkgs=${2:?usage: tarmac.sh /path/to/nix /path/to/nixpkgs}
task_extra_plugin=${3:-}
task_tmp=$(mktemp -d)
trap 'rm -rf "$task_tmp"' EXIT
export XDG_CACHE_HOME="$task_tmp/cache"
export NIX_CONFIG=$'experimental-features = nix-command flakes\nwarn-dirty = false'

# A separately configured plugin (e.g. gRPC) must survive the wrapper's default.
if [[ -n "$task_extra_plugin" ]]; then
  task_config="${NIX_CONFIG}"$'\nplugin-files = '"$task_extra_plugin"
  task_plugins=$(NIX_CONFIG="$task_config" "$task_nix" config show plugin-files)
  [[ " $task_plugins " == *" $task_extra_plugin "* ]]
  test "$(NIX_CONFIG="$task_config" "$task_nix" eval --raw --expr \
    'builtins.readFile (builtins.toFile "tarmac-other-plugin-test" "both plugins work")')" = 'both plugins work'
fi

# Evaluation writes to Tarmac, while the ordinary store remains usable.
task_path=$("$task_nix" eval --raw --expr 'builtins.toFile "tarmac-default-eval-test" "default eval store works"')
test ! -e "$task_path"
test -d "$XDG_CACHE_HOME/nix/tarmac"
"$task_nix" eval --raw --expr 'builtins.readFile (builtins.toFile "tarmac-default-eval-test" "default eval store works")' > "$task_tmp/read"
test "$(cat "$task_tmp/read")" = 'default eval store works'

# A separate process reopens the persistent cache.
test "$("$task_nix" eval --raw --expr 'builtins.toFile "tarmac-default-eval-test" "default eval store works"')" = "$task_path"

# Independent evaluators share the packfile without losing writes or hanging.
task_pids=()
for task_index in 1 2 3 4; do
  "$task_nix" eval --raw --expr \
    "builtins.readFile (builtins.toFile \"tarmac-concurrent-$task_index\" \"writer $task_index\")" \
    > "$task_tmp/writer-$task_index" &
  task_pids+=("$!")
done
for task_pid in "${task_pids[@]}"; do
  wait "$task_pid"
done
for task_index in 1 2 3 4; do
  test "$(cat "$task_tmp/writer-$task_index")" = "writer $task_index"
done

# Explicit selection takes precedence over the configured default.
task_override=$("$task_nix" eval --eval-store auto --raw --expr 'builtins.toFile "tarmac-explicit-eval-test" "explicit override works"')
test "$(cat "$task_override")" = 'explicit override works'

# Legacy evaluator uses the same configuration setting.
task_legacy="$(dirname "$task_nix")/nix-instantiate"
test "$("$task_legacy" --eval --read-write-mode --strict --expr 'builtins.readFile (builtins.toFile "tarmac-legacy-eval-test" "legacy works")')" = '"legacy works"'

# Derivations and writeText inputs are copied from the eval store on demand.
cat > "$task_tmp/build.nix" <<'NIX'
{ nixpkgs, nonce }:
let
  pkgs = import (builtins.toPath nixpkgs) { };
in
pkgs.runCommand "tarmac-build-test" {
  input = builtins.toFile "tarmac-build-input" "build works ${nonce}";
} ''
  cat "$input" > "$out"
''
NIX
task_output=$("$task_nix" build --no-link --print-out-paths --builders '' \
  -f "$task_tmp/build.nix" --argstr nixpkgs "$task_nixpkgs" --argstr nonce "$task_tmp")
test "$(cat "$task_output")" = "build works $task_tmp"

# Legacy nix-build also transfers its evaluation inputs to the build store.
task_nix_build="$(dirname "$task_nix")/nix-build"
task_legacy_output=$("$task_nix_build" --no-out-link --builders '' \
  "$task_tmp/build.nix" --argstr nixpkgs "$task_nixpkgs" --argstr nonce "$task_tmp-legacy")
test "$(cat "$task_legacy_output")" = "build works $task_tmp-legacy"
printf 'Tarmac default evaluation, persistence, concurrent writers, explicit override, legacy evaluation, and modern and legacy builds passed.\n'
