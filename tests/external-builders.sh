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

printf '#!%s\n' "$task_python" >"$task_handler"
cat >>"$task_handler" <<'PY'
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
if mode in ('recursive', 'remote-recursive'):
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

printf 'inner payload\n' >"$task_tmp/payload"
task_added=$("$task_nix" --store "$task_store" \
  --extra-experimental-features nix-command store add-path "$task_tmp/payload")
task_added="/nix/store/$(basename "$task_added")"
task_output=$(task_build "$(task_expr recursive \
  "requiredSystemFeatures = [ \"recursive-nix\" ]; ADDED_PATH = \"$task_added\";")")
test "$(cat "$task_store/nix/store/$(basename "$task_output")")" = "$task_added"
"$task_nix" --store "$task_store" --extra-experimental-features nix-command \
  path-info --recursive "/nix/store/$(basename "$task_output")" | grep -Fx "$task_added"

# A recursive build through the ordinary SSH hook must copy new references
# back too. localhost invokes the stdio daemon directly, without an SSH server.
task_remote_store="$task_tmp/remote-store"
printf 'remote-only payload\n' >"$task_tmp/remote-payload"
task_remote_added=$("$task_nix" --store "$task_remote_store" \
  --extra-experimental-features nix-command store add-path "$task_tmp/remote-payload")
task_remote_added="/nix/store/$(basename "$task_remote_added")"
task_remote_daemon="$task_tmp/remote-daemon"
printf '#!%s\n' "$(command -v bash)" >"$task_remote_daemon"
printf 'export NIX_CONFIG=%q\n' \
  $'experimental-features = nix-command external-builders recursive-nix\nsandbox = false\nmax-jobs = 1\nexternal-builders = '"$task_external" >>"$task_remote_daemon"
printf 'exec %q "$@"\n' "$(dirname "$task_nix")/nix-daemon" >>"$task_remote_daemon"
chmod 755 "$task_remote_daemon"
task_remote_uri="ssh-ng://localhost?remote-store=$task_remote_store&remote-program=$task_remote_daemon"
task_output=$("$task_nix" build --store "$task_store" --eval-store "$task_tmp/eval-store" \
  --extra-experimental-features 'nix-command recursive-nix' \
  --option sandbox false --max-jobs 0 \
  --option build-hook "$task_nix __build-remote" \
  --builders "$task_remote_uri x86_64-linux - 1 1 recursive-nix" \
  --no-link --print-out-paths --expr "$(task_expr remote-recursive \
    "requiredSystemFeatures = [ \"recursive-nix\" ]; ADDED_PATH = \"$task_remote_added\";")")
test "$(cat "$task_store/nix/store/$(basename "$task_remote_added")")" = 'remote-only payload'
"$task_nix" --store "$task_store" --extra-experimental-features nix-command \
  path-info --recursive "$task_output" | grep -Fx "$task_remote_added"

printf 'External dispatch, uid-range, decline fallback, recursive references, and remote closure transfer passed.\n'
