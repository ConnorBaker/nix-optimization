#!/usr/bin/env bash
set -euo pipefail

task_nix=${1:?usage: external-builders.sh /path/to/nix /path/to/python3}
task_python=${2:?usage: external-builders.sh /path/to/nix /path/to/python3}
# Root is required for uid-range allocation; Nix rejects a multi-user
# local store beneath a world-writable directory such as /tmp.
task_tmp=$(mktemp -d /run/nix-external-builders.XXXXXX)
trap 'rm -rf "$task_tmp"' EXIT
chmod 755 "$task_tmp"
task_store="$task_tmp/store"
task_handler="$task_tmp/external-builder"
task_log="$task_tmp/dispatch.log"
touch "$task_log"
chmod 666 "$task_log"

printf '#!%s\n' "$task_python" > "$task_handler"
cat >> "$task_handler" <<'PY'
import json, pathlib, sys
request = json.loads(pathlib.Path(sys.argv[1]).read_text())
# External helpers own this handshake; Tribuchet attach emits it after
# connecting to its hub. Match that protocol before reporting a result.
sys.stderr.write('\x02\n')
sys.stderr.flush()
mode = request['env']['EXTERNAL_MODE']
with open(request['env']['EXTERNAL_LOG'], 'a') as log:
    log.write(mode + '\n')
if mode == 'decline':
    sys.exit(222)
real_store = pathlib.Path(request['realStoreDir'])
output = real_store / pathlib.Path(request['outputs']['out']).name
if mode == 'recursive':
    added = request['env']['ADDED_PATH']
    output.write_text(added + '\n')
    (pathlib.Path(request['topTmpDir']) / 'result.json').write_text(
        json.dumps({'addedPaths': [added]}))
else:
    output.write_text('external ' + mode + '\n')
PY
chmod 755 "$task_handler"
task_external=$("$task_python" -c \
  'import json, sys; print(json.dumps([{"systems":["x86_64-linux"],"program":sys.argv[1],"args":[]}]))' \
  "$task_handler")

task_options=(
  --store "$task_store" --eval-store auto
  --extra-experimental-features 'nix-command external-builders auto-allocate-uids'
  --option builders '' --option sandbox false --option max-jobs 1
  --option auto-allocate-uids true --option system-features 'uid-range recursive-nix'
  --option external-builders "$task_external"
)

task_build() {
  "$task_nix" build "${task_options[@]}" --no-link --print-out-paths --expr "$1"
}

task_expr() {
  local task_mode=$1 task_extra=${2:-}
  # $out belongs to the derivation's builder, not this test shell.
  # shellcheck disable=SC2016
  printf 'builtins.derivation { name = "external-%s"; system = "x86_64-linux"; builder = "/bin/sh"; args = [ "-c" "printf local > $out" ]; EXTERNAL_MODE = "%s"; EXTERNAL_LOG = "%s"; %s }' \
    "$task_mode" "$task_mode" "$task_log" "$task_extra"
}

task_output=$(task_build "$(task_expr basic)")
test "$(cat "$task_store/nix/store/$(basename "$task_output")")" = 'external basic'

task_output=$(task_build "$(task_expr uid-range 'requiredSystemFeatures = [ "uid-range" ];')")
test "$(cat "$task_store/nix/store/$(basename "$task_output")")" = 'external uid-range'

task_output=$(task_build "$(task_expr decline)")
test "$(cat "$task_store/nix/store/$(basename "$task_output")")" = local
test "$(grep -c '^decline$' "$task_log")" = 1

printf 'inner payload\n' > "$task_tmp/payload"
task_added=$("$task_nix" --store "$task_store" \
  --extra-experimental-features nix-command store add-path "$task_tmp/payload")
task_added="/nix/store/$(basename "$task_added")"
task_output=$(task_build "$(task_expr recursive \
  "requiredSystemFeatures = [ \"recursive-nix\" ]; ADDED_PATH = \"$task_added\";")")
test "$(cat "$task_store/nix/store/$(basename "$task_output")")" = "$task_added"
"$task_nix" --store "$task_store" --extra-experimental-features nix-command \
  path-info --recursive "/nix/store/$(basename "$task_output")" | grep -Fx "$task_added"

printf 'External dispatch, uid-range, decline fallback, and recursive output references passed.\n'
