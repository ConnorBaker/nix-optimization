{
  pkgs,
  nix-tarmac,
  components,
}:
let
  nix = components.nix-cli;
  plugin =
    (pkgs.callPackage (nix-tarmac + "/package.nix") {
      inherit (components) nix-fetchers nix-store nix-util;
      # Use the components' compiler: Clang and GCC mangle constrained
      # templates such as nix::string2Int<std::integral N> differently, so a
      # GCC-built plugin fails to load against Clang-built libraries.
      stdenv = pkgs.llvmPackages_22.stdenv;
      doCheck = true;
    }).overrideAttrs
      {
        # Upstream builds with -g and keeps the debug info (dontStrip), whose
        # paths kept the Nix components' -dev outputs, GCC's C++ headers and
        # Boost's in the closure. Strip it as Nixpkgs does; symbols stay.
        dontStrip = false;
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
        --run ${
          pkgs.lib.escapeShellArg (
            import ./tarmac-wrapper-init.nix {
              pluginFile = "${plugin}/lib/nix/plugins/nix-tarmac-loader.so";
            }
          )
        } \
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
