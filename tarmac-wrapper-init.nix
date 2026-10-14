{ pluginFile }:
''
  # A nix shell can pass the preceding generation's plugin configuration to
  # this wrapper. Select this generation before either loader registers Tarmac.
  task_tarmac_prepare_config() {
    local task_line task_body task_key task_comment task_path task_entry
    local task_result="" task_plugin="${pluginFile}"
    local -a task_paths task_selected
    while IFS= read -r task_line || [ -n "$task_line" ]; do
      task_body="''${task_line%%#*}"
      if [[ "$task_body" =~ ^[[:space:]]*(extra-)?plugin-files[[:space:]]+=[[:space:]]+(.*)$ ]]; then
        task_key="''${BASH_REMATCH[1]}plugin-files"
        read -r -a task_paths <<< "''${BASH_REMATCH[2]}"
        task_selected=()
        for task_path in "''${task_paths[@]}"; do
          case "$task_path" in
            */nix-tarmac-loader.so|*/nix-tarmac-loader.dylib|*/nix-tarmac.so|*/nix-tarmac.dylib)
              continue ;;
            *)
              if [ -d "$task_path" ] && {
                [ -e "$task_path/nix-tarmac-loader.so" ] ||
                [ -e "$task_path/nix-tarmac-loader.dylib" ] ||
                [ -e "$task_path/nix-tarmac.so" ] ||
                [ -e "$task_path/nix-tarmac.dylib" ];
              }; then
                # Expand only mixed directories containing Tarmac. Retain
                # every other plugin, including hidden files and symlinks.
                for task_entry in "$task_path"/* "$task_path"/.[!.]* "$task_path"/..?*; do
                  [ -e "$task_entry" ] || [ -L "$task_entry" ] || continue
                  case "$task_entry" in
                    */nix-tarmac-loader.so|*/nix-tarmac-loader.dylib|*/nix-tarmac.so|*/nix-tarmac.dylib)
                      continue ;;
                    *) task_selected+=("$task_entry") ;;
                  esac
                done
              else
                case "$task_path" in
                  /nix/store/*-nix-tarmac-*/lib/nix/plugins|/nix/store/*-nix-tarmac-*/lib/nix/plugins/)
                    # A prior generation may already have been collected.
                    ;;
                  *) task_selected+=("$task_path") ;;
                esac
              fi ;;
          esac
        done
        task_comment="''${task_line#"$task_body"}"
        task_line="$task_key = ''${task_selected[*]}"
        if [ -n "$task_comment" ]; then
          task_line+=" $task_comment"
        fi
      fi
      task_result+="$task_line"$'\n'
    done <<< "''${NIX_CONFIG-}"
    # All inherited Tarmac entries are gone. Append exactly one matching
    # loader after the caller's assignments, preserving other plugin families.
    NIX_CONFIG="''${task_result}extra-plugin-files = $task_plugin"
    export NIX_CONFIG
  }
  task_tarmac_prepare_config
  unset -f task_tarmac_prepare_config

  if [ -n "''${NIX_BUILD_TOP-}" ] && [ -z "''${XDG_CACHE_HOME+x}" ]; then
    # Preserve explicit cache configuration and custom build/test homes.
    case "''${HOME-}" in
      /homeless-shelter|"") export XDG_CACHE_HOME="$NIX_BUILD_TOP/.cache" ;;
    esac
  fi
''
