{
  pkgs,
  nix-tarmac,
  components,
}:
let
  nix = components.nix-cli;
  plugin = pkgs.callPackage (nix-tarmac + "/package.nix") {
    inherit (components) nix-fetchers nix-store nix-util;
    doCheck = true;
  };
in
pkgs.symlinkJoin {
  name = "${nix.name}-with-tarmac";
  paths = [ nix ];
  nativeBuildInputs = [ pkgs.makeWrapper ];
  postBuild = ''
    for executable in "$out"/bin/*; do
      commandName=$(basename "$executable")
      rm "$executable"
      makeWrapper ${nix}/bin/nix "$executable" \
        --argv0 "$commandName" \
        --suffix NIX_CONFIG $'\n' \
        "extra-plugin-files = ${plugin}/lib/nix/plugins/nix-tarmac-loader.so" \
        --suffix NIX_CONFIG $'\n' "eval-store = tarmac://" \
        --run 'task_existing_drv=false
          task_all_drvs_valid=true
          task_evaluate_expression=false
          for task_argument in "$@"; do
            case "$task_argument" in
              /nix/store/*.drv|/nix/store/*.drv^*)
                task_existing_drv=true
                if ! ${nix}/bin/nix-store --check-validity "''${task_argument%%^*}" >/dev/null 2>&1; then
                  task_all_drvs_valid=false
                fi
                ;;
              --file|-f|--expr|-E) task_evaluate_expression=true ;;
            esac
          done
          if "$task_existing_drv" && "$task_all_drvs_valid" && ! "$task_evaluate_expression"; then
            # These paths were already evaluated in the build
            # store, possibly by another machine or user.
            set -- --option eval-store auto "$@"
          fi'
    done
  '';
  passthru = {
    inherit (nix) pname;
    inherit components plugin;
    inherit (components.nix-everything) libs version;
    unwrapped = nix;
  };
  meta.mainProgram = "nix";
}
