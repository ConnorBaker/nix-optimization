{
  inputs,
  lib,
  pkgs,
}:
lib.makeOverridable (
  {
    enableBOLTProfiling ? false,
    withBOLTProfiling ? null,
    enableBOLT ? false,
    # TODO: Tweak, tune these; collect stats from profiling/optimization passes and do hyperparameter sweeps.
    boltConfig ? {
      frame-opt-rm-stores = true;
      frame-opt = "all";

      #   --assume-abi                                          - assume the ABI is never violated
      #   --eliminate-unreachable                               - eliminate unreachable code

      # hugify = true;

      icf = "all";

      icp-eliminate-loads = true;

      indirect-call-promotion = "all";

      jump-tables = "aggressive";

      peepholes = "all";

      plt = "all";

      reg-reassign = true;
      use-aggr-reg-reassign = true;

      reorder-blocks = "ext-tsp";
      reorder-functions = "cdsort";

      shorten-instructions = true;

      simplify-conditional-tail-calls = true;
      simplify-rodata-loads = true;

      # split-all-cold = true;
      # split-eh = true;
      split-functions = true;
      split-strategy = "cdsplit";

      x86-strip-redundant-address-size = pkgs.stdenv.hostPlatform.isx86_64;
    },

    enablePGOProfiling ? false,
    withPGOProfiling ? null,
    enablePGO ? false,

    enableCSPGOProfiling ? false,
    withCSPGOProfiling ? null,
    enableCSPGO ? false,
  }:
  let
    suffix =
      let
        suffix' = lib.concatStringsSep "-" (
          lib.optionals (enableCSPGO || enableCSPGOProfiling) [ "cs" ]
          ++ lib.optionals (enableCSPGO || enableCSPGOProfiling || enablePGO || enablePGOProfiling) [ "pgo" ]
          ++ lib.optionals (enableBOLT || enableBOLTProfiling) [ "bolt" ]
          ++ lib.optionals (enableCSPGOProfiling || enablePGOProfiling || enableBOLTProfiling) [ "profiling" ]
        );
      in
      lib.optionalString (suffix' != "") "-${suffix'}";

    enableProfiling = enablePGOProfiling || enableCSPGOProfiling || enableBOLTProfiling;

    cflags = [
      # "-march=raptorlake"
      "-O3"
      "-flto"
      "-fsplit-lto-unit"
      "-fforce-emit-vtables"
      "-fstrict-vtable-pointers"
      "-fwhole-program-vtables"
      "-fvirtual-function-elimination"
      "-fdevirtualize-speculatively" # requires Clang 22
      # "-fexperimental-loop-fusion" # requires Clang 22
      "-fno-semantic-interposition"
      # The Hotness field in the Remark struct is defined as std::optional<uint64_t>, but the YAML parser uses
      # parseUnsigned() which returns an unsigned (typically 32-bit), so large values for Hotness overflow.
      "-fsave-optimization-record=bitstream"
    ]
    ++ lib.optionals enablePGOProfiling [
      "-fprofile-generate"
      "-ftemporal-profile" # temporal profiling can only be enabled for pgo; it segfaults cs-pgo
    ]
    ++ lib.optionals enableCSPGOProfiling [
      "-fcs-profile-generate"
    ]
    # https://clang.llvm.org/docs/UsersManual.html#cmdoption-ftemporal-profile
    ++ lib.optionals (enablePGOProfiling || enableCSPGOProfiling) [
      "-fprofile-update=atomic"
    ]
    # CSPGO uses the profile generated from PGO when it is add it's own profile-generation instrumentation
    ++ lib.optionals (enablePGO || enableCSPGOProfiling) [
      "-fprofile-use=${withPGOProfiling.profiles.merged}"
    ]
    ++ lib.optionals enableCSPGO [ "-fprofile-use=${withCSPGOProfiling.profiles.merged}" ];

    commonExtension = _: prevAttrs: {
      __structuredAttrs = true;

      outputs = prevAttrs.outputs or [ "out" ] ++ [ "remarks" ];

      dontStrip = true;
      separateDebugInfo = false;

      pname = prevAttrs.pname + suffix;

      preferLocalBuild = true;
      allowSubstitutes = false;

      env =
        let
          cflagsString = lib.concatStringsSep " " cflags;
        in
        prevAttrs.env or { }
        // {
          CC_LD = "lld";
          CXX_LD = "lld";
          NIX_CFLAGS_COMPILE = " ${cflagsString}";
          NIX_CFLAGS_LINK = " -Wl,-Bsymbolic-functions,--emit-relocs,-znow ${cflagsString}";
        };

      nativeBuildInputs =
        prevAttrs.nativeBuildInputs or [ ]
        # LLD bintools wrapper is needed for BOLT-compatible builds (mold's PLT format is incompatible with BOLT)
        # Using llvmPackages.bintools instead of lld directly to get proper rpath handling via ld-wrapper.sh
        ++ [ (lib.hiPrio pkgs.llvmPackages_22.bintools) ]
        ++ lib.optionals (enableBOLTProfiling || enableBOLT) [
          pkgs.autoFixElfFiles
          (lib.hiPrio pkgs.llvmPackages_22.bolt)
        ];

      postInstall = prevAttrs.postInstall or "" + ''
        for file in $(find . -type f -name "*.bitstream"); do
          newPrefix=$(dirname "$remarks/$file")
          mkdir -p "$newPrefix"
          mv -v "$file" "$newPrefix"/
        done
        unset -v newPrefix
        unset -v file
      '';

      preFixup =
        prevAttrs.preFixup or ""
        + lib.optionalString enableBOLTProfiling ''
          instrumentWithBolt() {
            local -r elfPath="$1"
            mv -v "$elfPath" "$elfPath.orig"
            llvm-bolt "$elfPath.orig" \
              --instrument \
              --instrumentation-wait-forks \
              --instrumentation-file="/tmp/$(basename "$elfPath").fdata" \
              -o "$elfPath"
          }

          postFixupHooks+=("autoFixElfFiles instrumentWithBolt")
        ''
        + lib.optionalString enableBOLT ''
          optimizeWithBolt() {
            local -r elfPath="$1"
            local -r fdataPath="${withBOLTProfiling.profiles.merged}/$(basename "$elfPath").fdata"
            if [[ ! -e $fdataPath ]]; then
              nixErrorLog "could not find fdata for $(basename "$elfPath"): $fdataPath"
              return
            fi
            mv -v "$elfPath" "$elfPath.orig"
            llvm-bolt "$elfPath.orig" \
              --data="$fdataPath" \
              --dyno-stats \
              --print-cache-metrics \
              --print-profile-stats \
              -o "$elfPath" \
              ${lib.cli.toCommandLineShellGNU { } boltConfig}
          }

          postFixupHooks+=("autoFixElfFiles optimizeWithBolt")
        '';
    };
  in
  assert lib.assertMsg (enableBOLTProfiling -> (withBOLTProfiling == null && !enableBOLT)) ''
    BOLT profiling cannot be enabled if withBOLTProfiling is provided or enableBOLT is true.
  '';
  assert lib.assertMsg (enablePGOProfiling -> (withPGOProfiling == null && !enablePGO)) ''
    PGO profiling cannot be enabled if withPGOProfiling is provided or enablePGO is true.
  '';
  assert lib.assertMsg
    (
      enableCSPGOProfiling
      -> (withPGOProfiling != null && withCSPGOProfiling == null && !enablePGO && !enableCSPGO)
    )
    ''
      CSPGO profiling cannot be enabled if withPGOProfiling is not provided, withCSPGOProfiling is provided, enablePGO
      is true, or enableCSPGO is true.
    '';
  assert lib.assertMsg
    (
      !(enableBOLTProfiling && enablePGOProfiling)
      && !(enablePGOProfiling && enableCSPGOProfiling)
      && !(enableCSPGOProfiling && enableBOLTProfiling)
    )
    ''
      PGO/CSPGO/BOLT profiling cannot be enabled simultaneously.
    '';
  (inputs.nix.lib.makeComponents {
    inherit pkgs;
    getStdenv = pkgs: pkgs.llvmPackages_22.stdenv;
  }).overrideScope
    (
      final: _: {
        # Copied from DetSys Nix's packaging/dependencies.nix, using the version of Rust available upstream.
        wasmtime =
          let
            wastimePath = inputs.nix.outPath + "/packaging/wasmtime.nix";
          in
          lib.optionalAttrs (lib.pathExists wastimePath) (
            pkgs.callPackage (inputs.nix.outPath + "/packaging/wasmtime.nix") {
              rust_1_89 = pkgs.rust_1_92;
            }
          );

        # Copied from DetSys Nix's packaging/dependencies.nix
        boehmgc =
          (pkgs.boehmgc.override {
            enableLargeConfig = true;
            # Increase the initial mark stack size to avoid stack
            # overflows, since these inhibit parallel marking (see
            # GC_mark_some()). To check whether the mark stack is too
            # small, run Nix with GC_PRINT_STATS=1 and look for messages
            # such as `Mark stack overflow`, `No room to copy back mark
            # stack`, and `Grew mark stack to ... frames`.
            initialMarkStackSize = "1048576";
            # Must use clangStdenv else we get segfaults when program is exiting if we've BOLTed the binary.
            stdenv = pkgs.llvmPackages_22.stdenv;
          }).overrideAttrs
            commonExtension;

        # TODO Hack until https://github.com/NixOS/nixpkgs/issues/45462 is fixed.
        # Copied from DetSys Nix's packaging/dependencies.nix
        boost =
          (pkgs.boost.override {
            extraB2Args = [
              "--with-container"
              "--with-context"
              "--with-coroutine"
              "--with-iostreams"
              "--with-url"
              "--with-thread"
            ];
            enableIcu = false;
            stdenv = pkgs.llvmPackages_22.stdenv;
          }).overrideAttrs
            (
              lib.composeExtensions commonExtension (
                finalAttrs: prevAttrs: {
                  # Need to remove `--with-*` to use `--with-libraries=...`
                  buildPhase = lib.replaceStrings [ "--without-python" ] [ "" ] prevAttrs.buildPhase;
                  installPhase = lib.replaceStrings [ "--without-python" ] [ "" ] prevAttrs.installPhase;
                }
              )
            );

        mesonComponentOverrides = commonExtension;

        profiles = {
          eval = {
            closures = {
              # TODO: Find out whether (since we're using many profiled libraries) they clobber eachother or what:
              # https://clang.llvm.org/docs/UsersManual.html#profiling-with-instrumentation
              # TODO: Parallel evaluation, evaluate things other than system closurse, test with different memory/store setups.
              gnome =
                pkgs.runCommandLocal "profiles-eval-closures-nix${suffix}"
                  {
                    nativeBuildInputs = [
                      final.nix-cli
                      pkgs.writableTmpDirAsHomeHook
                    ];
                    meta.broken = !enableProfiling;
                  }
                  (
                    ''
                      nixLog "generating profile data by evaluating NixOS system closures with nix${suffix}"
                    ''
                    + lib.optionalString (enablePGOProfiling || enableCSPGOProfiling) ''
                      export LLVM_PROFILE_FILE="$out"
                    ''
                    # TODO: There's no derivation associated with nixpkgs since it's an eval-time fetcher, so we have to run the command locally
                    # since only the local store will be guaranteed to have it. Alternatively use fetchFromGitHub.
                    # The local machine is fine since that's the one we're doing profiling on anyway.
                    # TODO: Could create a dummy store for the evaluation to test copying/store operations (still wouldn't test daemon).
                    + ''
                      nix eval \
                        --store /tmp/nix/store \
                        --eval-store /tmp/nix/store \
                        --json \
                        --lazy-trees \
                        --eval-cores 1 \
                        -f "${pkgs.path}/nixos/release.nix" \
                        closures.gnome
                    ''
                    + lib.optionalString enableBOLTProfiling ''
                      mkdir -p "$out"
                      mv -v /tmp/*.fdata "$out"
                    ''
                    + ''
                      nixLog "generated $out"
                    ''
                  );
            };
          };

          merged =
            pkgs.runCommandLocal "profiles-merged-nix${suffix}"
              {
                __structuredAttrs = true;

                nativeBuildInputs =
                  lib.optionals (enablePGOProfiling || enableCSPGOProfiling) [ pkgs.llvmPackages_22.libllvm ]
                  ++ lib.optionals enableBOLTProfiling [ pkgs.llvmPackages_22.bolt ];

                profiles =
                  lib.optionals enableProfiling [
                    final.profiles.eval.closures.gnome
                  ]
                  # cs-pgo requires the original pgo profile as well.
                  ++ lib.optionals enableCSPGOProfiling [
                    withPGOProfiling.profiles.eval.closures.gnome
                  ];

                meta.broken = !enableProfiling;
              }
              (
                ''
                  nixLog "merging profiles"
                ''
                # TODO: Better handling of temporal data merging (instead of using the default values):
                # https://reviews.llvm.org/D147287
                + lib.optionalString (enablePGOProfiling || enableCSPGOProfiling) ''
                  llvm-profdata merge \
                    --temporal-profile-trace-reservoir-size 100 \
                    --temporal-profile-max-trace-length 1000 \
                    --output="$out" \
                    "''${profiles[@]}"
                ''
                # TODO: Merging of BOLT data: https://github.com/llvm/llvm-project/blob/main/bolt/README.md#multiple-profiles
                + lib.optionalString enableBOLTProfiling ''
                  nixErrorLog "TODO: merging of BOLT profiles"
                  mkdir -p "$out"
                  for profile in "''${profiles[@]}"; do
                    cp -r "$profile"/* "$out"/
                  done
                ''
                + ''
                  nixLog "created $out"
                ''
              );
        };
      }
    )
)
