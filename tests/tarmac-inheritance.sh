#!/usr/bin/env bash
set -euo pipefail

task_nix=${1:?usage: tarmac-inheritance.sh NIX EVAL_JOBS TARMAC_PACKAGE GRPC_PLUGIN_DIR}
task_jobs=${2:?}
task_plugin=${3:?}
task_grpc=${4:?}
task_tmp=$(mktemp -d)
trap 'rm -rf "$task_tmp"' EXIT

# Hermetic store/config/cache; the host daemon and real HOME are untouched.
export NIX_REMOTE=local
export NIX_STORE_DIR="$task_tmp/store"
export NIX_STATE_DIR="$task_tmp/state"
export NIX_LOG_DIR="$task_tmp/log"
export NIX_CONF_DIR="$task_tmp/conf"
export XDG_CACHE_HOME="$task_tmp/cache"
mkdir -p "$NIX_CONF_DIR" "$task_tmp/previous/lib" "$task_tmp/mixed"
cp -R "$task_plugin/lib/nix" "$task_tmp/previous/lib/nix"
chmod -R u+w "$task_tmp/previous"
task_loader="$task_plugin/lib/nix/plugins/nix-tarmac-loader.so"
task_old_loader="$task_tmp/previous/lib/nix/plugins/nix-tarmac-loader.so"
task_old_native=("$task_tmp"/previous/lib/nix/nix-tarmac-versions/*/nix-tarmac.so)
# Distinct copies really would register the store twice without the fix.
ln -s "$task_old_loader" "$task_tmp/mixed/nix-tarmac-loader.so"
ln -s "$task_grpc/nix-grpc-store-loader.so" "$task_tmp/mixed/nix-grpc-store-loader.so"
task_base=$'experimental-features = nix-command flakes\nconnect-timeout = 17\ncores = 2\nextra-plugin-files = '"$task_grpc"

check_inherited() {
	local task_config=$1 task_paths task_path task_count=0
	task_paths=$(NIX_CONFIG="$task_base"$'\n'"$task_config" "$task_nix" config show plugin-files)
	for task_path in $task_paths; do
		[[ "$task_path" != "$task_tmp"/previous/* ]]
		if [[ "$task_path" == "$task_loader" ]]; then
			task_count=$((task_count + 1))
		fi
	done
	test "$task_count" -eq 1
	[[ " $task_paths " == *" $task_grpc "* || " $task_paths " == *" $task_tmp/mixed/nix-grpc-store-loader.so "* ]]
	test "$(NIX_CONFIG="$task_base"$'\n'"$task_config" "$task_nix" config show connect-timeout)" = 17
	test "$(NIX_CONFIG="$task_base"$'\n'"$task_config" "$task_nix" config show cores)" = 2
	test "$(NIX_CONFIG="$task_base"$'\n'"$task_config" "$task_nix" eval --raw --expr \
		'builtins.readFile (builtins.toFile "plugin-inheritance" "selected-tarmac-ok")')" = selected-tarmac-ok
	NIX_CONFIG="$task_base"$'\n'"$task_config" "$task_jobs" --workers 1 --expr \
		'{ sample = derivation { name = "plugin-inheritance"; system = "x86_64-linux"; builder = "/bin/sh"; }; }' >"$task_tmp/jobs.jsonl"
	jq -e '.attr == "sample" and .error == null and (.drvPath | endswith(".drv"))' "$task_tmp/jobs.jsonl" >/dev/null
}

check_inherited "extra-plugin-files = $task_old_loader"
check_inherited "plugin-files = $task_grpc $task_old_loader"
check_inherited "extra-plugin-files = ${task_old_native[0]}"
check_inherited "extra-plugin-files = $(dirname "${task_old_native[0]}")"
check_inherited "extra-plugin-files = $task_tmp/previous/lib/nix/plugins"
check_inherited "plugin-files = $task_grpc $task_tmp/previous/lib/nix/plugins"
check_inherited "extra-plugin-files = $task_tmp/mixed"
check_inherited $'  extra-plugin-files\t =\t '"$task_old_loader"' # prior generation'
check_inherited "extra-plugin-files = $task_old_loader $task_loader $task_old_loader"
check_inherited "extra-plugin-files = $task_old_loader"$'\nplugin-files = '"$task_grpc"$'\nextra-plugin-files = '"$task_loader"
check_inherited 'extra-plugin-files = /nix/store/00000000000000000000000000000000-nix-tarmac-garbage-collected/lib/nix/plugins'

# nix shell passes its NIX_CONFIG to the launched command. Re-entering the
# selected wrapper must remain idempotent, as in nixos-rebuild bootstrapping.
NIX_CONFIG="$task_base"$'\nextra-plugin-files = '"$task_old_loader" \
	"$task_nix" shell --expr '[]' --command "$task_nix" config show plugin-files >"$task_tmp/nested-plugins"
test "$(tr ' ' '\n' <"$task_tmp/nested-plugins" | grep -Fc "$task_loader")" -eq 1
printf '11 inherited-plugin configurations plus nested invocation passed for CLI and nix-eval-jobs.\n'
