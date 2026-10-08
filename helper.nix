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
      # With LLVM 22.1.8 BOLT, aggressive register reassignment miscompiles libnixfetchers.so (segfault in a static
      # initializer constructing a boost::regex, at startup).
      # use-aggr-reg-reassign = true;

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

    # Attribute paths (into `profiles.eval`) of the workloads to generate PGO/CSPGO/BOLT profiles from.
    profileWorkloads ? [
      [
        "closures"
        "gnome"
      ]
    ],

    # Patches to apply to the whole Nix source (e.g., vendored by a consumer of this flake), for every component and
    # every profiling build alike.
    patches ? [ ],

    # Extra arguments for the `nix eval` of the `nixpkgs.parallel` workload (e.g., to enable settings added by
    # `patches`, so that their code is profiled too).
    extraProfileEvalArgs ? [ ],
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

    cflagsString = lib.concatStringsSep " " cflags;

    commonExtension = _: prevAttrs: {
      __structuredAttrs = true;

      outputs = prevAttrs.outputs or [ "out" ] ++ [ "remarks" ];

      dontStrip = true;
      separateDebugInfo = false;

      pname = prevAttrs.pname + suffix;

      preferLocalBuild = true;
      allowSubstitutes = false;

      env =
        prevAttrs.env or { }
        // {
          CC_LD = "lld";
          CXX_LD = "lld";
          NIX_CFLAGS_LINK =
            prevAttrs.env.NIX_CFLAGS_LINK or ""
            + " -Wl,-Bsymbolic-functions,--emit-relocs,-znow ${cflagsString}";
        }
        # Append rather than replace: e.g. DetSys's boehmgc sets its tuning knobs through NIX_CFLAGS_COMPILE.
        // lib.optionalAttrs (!(prevAttrs ? NIX_CFLAGS_COMPILE)) {
          NIX_CFLAGS_COMPILE = prevAttrs.env.NIX_CFLAGS_COMPILE or "" + " ${cflagsString}";
        };

      # Some components (e.g. nix-expr) set NIX_CFLAGS_COMPILE as a derivation argument instead, which mkDerivation
      # forbids from also being in `env` and which isn't exported with __structuredAttrs, so append to and export it.
      ${if prevAttrs ? NIX_CFLAGS_COMPILE then "NIX_CFLAGS_COMPILE" else null} =
        prevAttrs.NIX_CFLAGS_COMPILE + " ${cflagsString}";
      preConfigure =
        prevAttrs.preConfigure or ""
        + lib.optionalString (prevAttrs ? NIX_CFLAGS_COMPILE) ''
          export NIX_CFLAGS_COMPILE
        '';

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
  (
    let
      components = inputs.nix.lib.makeComponents {
        inherit pkgs;
        getStdenv = pkgs: pkgs.llvmPackages_22.stdenv;
      };
    in
    # Applying patches switches the components to the whole (patched) source, so only do so when there are any.
    if patches == [ ] then components else components.appendPatches patches
  ).overrideScope
    (
      final: _: {
        # DetSys Nix's packaging/dependencies.nix builds boehmgc from its own fork (the `bdwgc` flake input) with its
        # own CFLAGS; keep that, but add our flags/instrumentation.
        # Must use clangStdenv else we get segfaults when program is exiting if we've BOLTed the binary.
        boehmgc =
          (import (inputs.nix + "/packaging/dependencies.nix") {
            inherit (inputs.nix) inputs;
            inherit pkgs;
            stdenv = pkgs.llvmPackages_22.stdenv;
          } final).boehmgc.overrideAttrs
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

        mesonComponentOverrides = lib.composeExtensions commonExtension (
          _: _: {
            # Meson 1.12 (unlike 1.10, which DetSys pins) resolves unity-build sources in a source subdirectory named
            # like the build directory (e.g. src/libstore/build/) relative to the build directory, so use another name.
            mesonBuildDir = "_build";
          }
        );

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

            nixpkgs = {
              # Read-only parallel evaluation of every derivation path in Nixpkgs (with CUDA enabled), mirroring
              # nixpkgs-review/Hydra-style evaluation rather than single-core evaluation of a system closure.
              # NOTE: With PGO/CSPGO, `-fprofile-update=atomic` (see cflags) keeps the counters correct across eval
              # threads, at the cost of contention (the instrumented evaluation is much slower than a normal one).
              # NOTE: GC_DONT_GC=1 matches our workload, but means the collector's marking code is not trained.
              parallel =
                let
                  walker = pkgs.writeText "walk-nixpkgs.nix" ''
                    let
                      inherit (builtins) deepSeq isAttrs isString mapAttrs tryEval;
                      tryEval' = expr: (tryEval (deepSeq expr expr)).value;
                      # The derivation path for a derivation, whether to recurse into an attribute set otherwise.
                      unsafeMkValueReport =
                        value:
                        if isAttrs value then
                          if value.type or null == "derivation" then value.drvPath else value.recurseForDerivations or false
                        else
                          false;
                      mkNestedReport = mapAttrs (
                        _: value:
                        let
                          maybeReport = tryEval' (unsafeMkValueReport value);
                        in
                        if isString maybeReport then
                          maybeReport
                        else if maybeReport then
                          mkNestedReport value
                        else
                          null
                      );
                    in
                    mkNestedReport
                  '';
                in
                pkgs.runCommandLocal "profiles-eval-nixpkgs-parallel-nix${suffix}"
                  {
                    nativeBuildInputs = [
                      final.nix-cli
                      pkgs.writableTmpDirAsHomeHook
                    ];
                    meta.broken = !enableProfiling;
                  }
                  (
                    ''
                      nixLog "generating profile data by evaluating Nixpkgs in parallel with nix${suffix}"
                    ''
                    + lib.optionalString (enablePGOProfiling || enableCSPGOProfiling) ''
                      export LLVM_PROFILE_FILE="$out"
                    ''
                    + ''
                      GC_DONT_GC=1 nix eval \
                        --offline \
                        --store dummy:// \
                        --read-only \
                        --json \
                        --impure \
                        --no-eval-cache \
                        --no-allow-import-from-derivation \
                        --no-fsync-metadata \
                        --lazy-trees \
                        --extra-experimental-features 'ca-derivations parallel-eval' \
                        --eval-cores 16 \
                        ${
                          lib.optionalString (
                            extraProfileEvalArgs != [ ]
                          ) "${lib.escapeShellArgs extraProfileEvalArgs} \\\n  "
                        }--expr 'import ${walker} (import ${pkgs.path} {
                          system = "${pkgs.stdenv.hostPlatform.system}";
                          config = { allowUnfree = true; cudaSupport = true; inHydra = true; allowAliases = false; };
                          __allowFileset = false;
                        })' \
                        > /dev/null
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

          # The profiles generated by the workloads in `eval` selected by `profileWorkloads`.
          selected = map (path: lib.getAttrFromPath path final.profiles.eval) profileWorkloads;

          merged =
            pkgs.runCommandLocal "profiles-merged-nix${suffix}"
              {
                __structuredAttrs = true;

                nativeBuildInputs =
                  lib.optionals (enablePGOProfiling || enableCSPGOProfiling) [ pkgs.llvmPackages_22.libllvm ]
                  ++ lib.optionals enableBOLTProfiling [ pkgs.llvmPackages_22.bolt ];

                profiles =
                  lib.optionals enableProfiling final.profiles.selected
                  # cs-pgo requires the original pgo profile as well.
                  ++ lib.optionals enableCSPGOProfiling withPGOProfiling.profiles.selected;

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
