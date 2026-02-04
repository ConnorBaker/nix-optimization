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

      hugify = true;

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

      split-all-cold = true;
      split-eh = true;
      split-functions = true;
      split-strategy = "cdsplit";
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

    profileArgs =
      lib.optionals enablePGOProfiling [ "-fprofile-generate" ]
      ++ lib.optionals enableCSPGOProfiling [ "-fcs-profile-generate" ]
      ++ lib.optionals (enablePGOProfiling || enableCSPGOProfiling) [ "-fprofile-update=atomic" ]
      # CSPGO uses the profile generated from PGO when it is add it's own profile-generation instrumentation
      ++ lib.optionals (enablePGO || enableCSPGOProfiling) [
        "-fprofile-use=${withPGOProfiling.nix-eval-profdata}"
      ]
      ++ lib.optionals enableCSPGO [ "-fprofile-use=${withCSPGOProfiling.nix-eval-profdata}" ];

    commonExtension = _: prevAttrs: {
      __structuredAttrs = true;

      dontStrip = true;
      separateDebugInfo = false;

      pname = prevAttrs.pname + suffix;

      preferLocalBuild = true;
      allowSubstitutes = false;

      env = prevAttrs.env or { } // {
        CC_LD = "lld";
        CXX_LD = "lld";
      };

      nativeBuildInputs =
        prevAttrs.nativeBuildInputs or [ ]
        # LLD bintools wrapper is needed for BOLT-compatible builds (mold's PLT format is incompatible with BOLT)
        # Using llvmPackages.bintools instead of lld directly to get proper rpath handling via ld-wrapper.sh
        # TODO: If llvmPackages is spliced, do we need to go through buildPackages?
        ++ [ (lib.hiPrio pkgs.buildPackages.llvmPackages.bintools) ]
        ++ lib.optionals (enableBOLTProfiling || enableBOLT) [
          pkgs.autoFixElfFiles
          (lib.hiPrio pkgs.buildPackages.llvmPackages.bolt)
        ];

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
            local -r fdataPath="${withBOLTProfiling.nix-eval-system-closures-fdatum}/$(basename "$elfPath").fdata"
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
  (inputs.nix.lib.makeComponents {
    inherit pkgs;
    getStdenv = builtins.getAttr "clangStdenv";
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
            stdenv = pkgs.clangStdenv;
          }).overrideAttrs
            (
              lib.composeExtensions commonExtension (
                finalAttrs: prevAttrs: {
                  env =
                    let
                      profileArgsString = lib.concatStringsSep " " profileArgs;
                    in
                    prevAttrs.env or { }
                    // {
                      # BoehmGC builds with O2 and without LTO.
                      # TODO:
                      # - https://clang.llvm.org/docs/UsersManual.html#cmdoption-fstrict-vtable-pointers
                      # - https://clang.llvm.org/docs/UsersManual.html#cmdoption-fwhole-program-vtables
                      NIX_CFLAGS_COMPILE = " -O3 -flto=thin ${profileArgsString}";
                      NIX_CFLAGS_LINK = " -Wl,--emit-relocs -Wl,-znow -flto=thin ${profileArgsString}";
                    };
                }
              )
            );

        nix-eval-system-closures-fdatum =
          pkgs.runCommandLocal "nix${suffix}-eval-system-closures-fdatum"
            {
              nativeBuildInputs = [ final.nix-cli ];
              meta.broken = !enableBOLTProfiling;
            }
            ''
              nixLog "generating profile data by evaluating NixOS system closures with nix${suffix}"
              nix eval \
                --store dummy:// \
                --eval-store dummy:// \
                --read-only \
                --no-eval-cache \
                --json \
                --eval-cores 1 \
                -f "${pkgs.path}/nixos/release.nix" \
                closures.gnome.x86_64-linux
              mkdir -p "$out"
              mv -v /tmp/*.fdata "$out"
              nixLog "generated $out"
            '';

        # TODO: There's no derivation associated with nixpkgs since it's an eval-time fetcher, so we have to run the command locally
        # since only the local store will be guaranteed to have it. Alternatively use fetchFromGitHub.
        # The local machine is fine since that's the one we're doing profiling on anyway.
        # TODO: Could create a dummy store for the evaluation to test copying/store operations (still wouldn't test daemon).
        nix-eval-system-closures-profraw =
          pkgs.runCommandLocal "nix${suffix}-eval-system-closures.profraw"
            {
              nativeBuildInputs = [ final.nix-cli ];
              meta.broken = !(enablePGOProfiling || enableCSPGOProfiling);
            }
            ''
              nixLog "generating profile data by evaluating NixOS system closures with nix${suffix}"
              LLVM_PROFILE_FILE="$out" nix eval \
                --store dummy:// \
                --eval-store dummy:// \
                --read-only \
                --no-eval-cache \
                --json \
                --eval-cores 1 \
                -f "${pkgs.path}/nixos/release.nix" \
                closures.gnome.x86_64-linux
              nixLog "generated $out"
            '';

        nix-eval-profdata =
          pkgs.runCommandLocal "nix${suffix}-eval.profdata"
            {
              __structuredAttrs = true;
              nativeBuildInputs = [ pkgs.llvmPackages.libllvm ];
              profraws =
                lib.optionals (enablePGOProfiling || enableCSPGOProfiling) [
                  final.nix-eval-system-closures-profraw
                ]
                # cs-pgo requires the original pgo profile as well.
                ++ lib.optionals enableCSPGOProfiling [
                  withPGOProfiling.nix-eval-system-closures-profraw
                ];
              meta.broken = !(enablePGOProfiling || enableCSPGOProfiling);
            }
            ''
              nixLog "merging raw profiles"
              echoCmd llvm-profdata merge -output="$out" "''${profraws[@]}"
              llvm-profdata merge -output="$out" "''${profraws[@]}"
              nixLog "created $out"
            '';

        mesonComponentOverrides = lib.composeExtensions commonExtension (
          finalAttrs: prevAttrs: {
            nativeBuildInputs =
              prevAttrs.nativeBuildInputs or [ ]
              # LLD bintools wrapper is needed for BOLT-compatible builds (mold's PLT format is incompatible with BOLT)
              # Using llvmPackages.bintools instead of lld directly to get proper rpath handling via ld-wrapper.sh
              # TODO: If llvmPackages is spliced, do we need to go through buildPackages?
              ++ [
                (lib.hiPrio pkgs.buildPackages.clang-tools)
                (lib.hiPrio pkgs.buildPackages.llvmPackages.llvm)
              ];

            mesonFlags =
              prevAttrs.mesonFlags or [ ]
              ++ [
                (lib.mesonBool "b_lto" true)
                (lib.mesonOption "b_lto_mode" "thin")
              ]
              ++ lib.optionals (profileArgs != [ ]) [
                (lib.mesonOption "cpp_args" (lib.concatStringsSep " " profileArgs))
              ]
              ++ [
                (lib.mesonOption "cpp_link_args" (
                  lib.concatStringsSep " " (
                    [
                      "-Wl,--emit-relocs"
                      "-Wl,-znow"
                    ]
                    ++ profileArgs
                  )
                ))
              ];
          }
        );
      }
    )
)
