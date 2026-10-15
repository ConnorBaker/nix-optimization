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
    # BOLT's frame optimizer and register reassignment are x86-only (on AArch64, BOLT exits with "BOLT-ERROR: ... is
    # specific to X86"); its other x86-only passes (e.g. shorten-instructions) skip themselves on AArch64.
    boltConfig ? {
      frame-opt-rm-stores = pkgs.stdenv.hostPlatform.isx86_64;
      frame-opt = if pkgs.stdenv.hostPlatform.isx86_64 then "all" else "none";

      #   --assume-abi                                          - assume the ABI is never violated
      #   --eliminate-unreachable                               - eliminate unreachable code

      # hugify = true;

      icf = "all";

      # With LLVM 23.1.0's BOLT, indirect call promotion miscompiles on AArch64: in libnixutil.so, a promoted call to
      # nix::base16::decode was passed a pointer into .text as its return slot, so every test executable segfaulted in a
      # static initializer. (Found by optimizing libnixutil.so with each option left out in turn: only leaving out
      # this one fixed it.)
      icp-eliminate-loads = pkgs.stdenv.hostPlatform.isx86_64;

      indirect-call-promotion = if pkgs.stdenv.hostPlatform.isx86_64 then "all" else "none";

      jump-tables = "aggressive";

      peepholes = "all";

      plt = "all";

      reg-reassign = pkgs.stdenv.hostPlatform.isx86_64;
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
      # On AArch64, BOLT's LongJmp pass (which adds stubs for branches whose target is out of range) doesn't support
      # CDSplit ("BOLT-ERROR: CDSplit is not supported with LongJmp"); the compact code model assumes, as is the case for
      # Nix's and Boost's libraries, that all code is within branch range (128 MiB), so LongJmp isn't needed.
      compact-code-model = pkgs.stdenv.hostPlatform.isAarch64;

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

    # Extra arguments for the `nix eval` of the `nixpkgs.serial` workload (e.g., to enable settings added by
    # `patches`, so that their code is profiled too).
    extraProfileEvalArgs ? [ ],

    # Whether the evaluator uses Boehm GC. Without it, the evaluator allocates with (mimalloc's) malloc and never frees,
    # which is fine for short-lived evaluations (e.g., ones that would run with GC_DONT_GC=1 anyway), and the whole heap
    # is then in mimalloc's arenas (which can be backed by huge pages).
    enableGC ? true,

    # Whether the profile derivations are content-addressed (see `contentAddressed` below). Needs the `ca-derivations`
    # experimental feature wherever the variants are evaluated and built, and builders that can build floating
    # content-addressed derivations.
    contentAddressedProfiles ? false,
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

    # LLVM 22's BOLT instrumentation clobbers x16 on AArch64 in its indirect call handler, which a TLS descriptor call
    # may keep a value in (https://github.com/llvm/llvm-project/issues/165664), so an instrumented Nix segfaults. It is
    # fixed in LLVM 23 (https://github.com/llvm/llvm-project/pull/180229). x86_64 keeps LLVM 22's, so its builds
    # don't change.
    bolt =
      if pkgs.stdenv.hostPlatform.isAarch64 then pkgs.llvmPackages_23.bolt else pkgs.llvmPackages_22.bolt;

    # With contentAddressedProfiles, profiles are content-addressed: their output path depends on what they contain, not
    # on how they were made. They aren't reproducible (e.g. a parallel evaluation's counts differ from run to run; see
    # the README), so an input-addressed profile can have different contents on different machines under the same path,
    # each from its own build. Components built against it on different machines (e.g. by a remote builder that spreads
    # builds across machines) then use different profiles: CSPGO fails to link ("linking module flags 'ProfileSummary':
    # IDs have conflicting values"), and BOLT is silently less effective. Content-addressed, a profile's consumers'
    # paths depend on which profile they used, so they can't be mixed.
    contentAddressed = lib.optionalAttrs contentAddressedProfiles {
      __contentAddressed = true;
      outputHashMode = "recursive";
      outputHashAlgo = "sha256";
    };

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

      # Upstream unit-test runners derive the installed executable's name
      # from pname. Meson still installs e.g. nix-store-tests, without a PGO
      # suffix, so vary the derivation name instead for these components.
      pname = prevAttrs.pname + lib.optionalString (!lib.hasSuffix "-tests" prevAttrs.pname) suffix;
      ${if lib.hasSuffix "-tests" prevAttrs.pname then "name" else null} =
        "${prevAttrs.pname}${suffix}-${prevAttrs.version}";

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
        # Preserve dependencies' tuning knobs when appending optimization flags.
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
          (lib.hiPrio bolt)
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
        # postInstall fills it only with remarks it finds; a component that
        # compiles nothing, or installs without hooks (the functional tests),
        # still has to produce the output.
        + ''
          mkdir -p "$remarks"
        ''
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
        ''
        # -fsave-optimization-record makes Clang emit line tables (the driver adds -debug-info-kind=line-tables-only),
        # and dontStrip keeps them. They name every header used, so each library referenced the -dev outputs, GCC's
        # C++ headers and Boost's, about 1.9 GiB of a system closure. Remove the debug sections last, after BOLT, which
        # needs the relocations the usual strip would drop. The symbol table stays and the remarks keep their source
        # locations. Profiling builds are left as they are, so their profiles stay valid.
        + lib.optionalString (!enableProfiling) ''
          stripDebugSections() {
            local output file
            for output in $(getAllOutputNames); do
              while IFS= read -r -d "" file; do
                isELF "$file" || continue
                $STRIP --strip-debug "$file"
              done < <(find "''${!output}" -type f -print0)
            done
          }

          postFixupHooks+=(stripDebugSections)
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
    # Patch every optimized and profiling component from the same source tree.
    components.appendPatches (
      [
        ./patches/default-eval-store.patch
        ./patches/append-plugin-files.patch
        ./patches/query-missing-eval-store.patch
        ./patches/develop-output-build-store.patch
        ./patches/upstream-clang-vtables.patch
        ./patches/tribuchet-external-builders.patch
        ./patches/sergei-tarball-performance.patch
      ]
      ++ patches
    )
  ).overrideScope
    (
      final: prev:
      lib.optionalAttrs (!enableGC) {
        nix-expr = prev.nix-expr.override { enableGC = false; };
      }
      // {
        # Shared by profiling/final Nix and every component/plugin consumer.
        # PR #16427 requires the native zlib-ng and pack-config changes as
        # well as its Nix source patch; changing only git-utils is insufficient.
        libgit2 = pkgs.callPackage ./packages/libgit2-tarball-cache.nix {
          stdenv = pkgs.llvmPackages_22.stdenv;
        };

        # Preserve upstream Nix's GC tuning and add our Clang flags/instrumentation.
        # Must use clangStdenv else we get segfaults when program is exiting if we've BOLTed the binary.
        boehmgc =
          (
            (import (inputs.nix + "/packaging/dependencies.nix") {
              inherit pkgs;
              stdenv = pkgs.llvmPackages_22.stdenv;
            } final).boehmgc.override
              {
                stdenv = pkgs.llvmPackages_22.stdenv;
              }
          ).overrideAttrs
            commonExtension;

        # TODO Hack until https://github.com/NixOS/nixpkgs/issues/45462 is fixed.
        # Boost 1.89, as upstream Nix uses: Boost 1.91's Boost.URL stores an IPv6 literal's encoded size as its decoded
        # size, so a host with a pct-encoded zone ID (e.g. `[fe80::1%25eth0]`) decodes with trailing NULs, failing Nix's
        # URL unit tests. Fixed in https://github.com/boostorg/url/commit/4dca58d (boostorg/url#1004); use `pkgs.boost`
        # again once a Boost release has it.
        boost =
          (pkgs.boost189.override {
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
                _: prevAttrs: {
                  # Need to remove `--with-*` to use `--with-libraries=...`
                  buildPhase = lib.replaceStrings [ "--without-python" ] [ "" ] prevAttrs.buildPhase;
                  installPhase = lib.replaceStrings [ "--without-python" ] [ "" ] prevAttrs.installPhase;
                }
              )
            );

        mesonComponentOverrides = lib.composeExtensions commonExtension (
          _: _: {
            # Meson 1.12 resolves unity-build sources in a source subdirectory named
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
                  (
                    contentAddressed
                    // {
                      nativeBuildInputs = [
                        final.nix-cli
                        pkgs.writableTmpDirAsHomeHook
                      ];
                      meta.broken = !enableProfiling;
                    }
                  )
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
                      nix eval --extra-experimental-features nix-command \
                        --store /tmp/nix/store \
                        --eval-store /tmp/nix/store \
                        --json \
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
              # Read-only serial evaluation of every derivation path in Nixpkgs (with CUDA enabled), mirroring
              # nixpkgs-review/Hydra-style evaluation rather than evaluation of a single system closure.
              # NOTE: GC_DONT_GC=1 matches our workload, but means the collector's marking code is not trained.
              serial =
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
                pkgs.runCommandLocal "profiles-eval-nixpkgs-serial-nix${suffix}"
                  (
                    contentAddressed
                    // {
                      nativeBuildInputs = [
                        final.nix-cli
                        pkgs.writableTmpDirAsHomeHook
                      ];
                      meta.broken = !enableProfiling;
                    }
                  )
                  (
                    ''
                      nixLog "generating profile data by evaluating Nixpkgs serially with nix${suffix}"
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
                        --extra-experimental-features 'nix-command ca-derivations' \
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
              (
                contentAddressed
                // {
                  __structuredAttrs = true;

                  nativeBuildInputs =
                    lib.optionals (enablePGOProfiling || enableCSPGOProfiling) [ pkgs.llvmPackages_22.libllvm ]
                    ++ lib.optionals enableBOLTProfiling [ bolt ];

                  profiles =
                    lib.optionals enableProfiling final.profiles.selected
                    # cs-pgo requires the original pgo profile as well.
                    ++ lib.optionals enableCSPGOProfiling withPGOProfiling.profiles.selected;

                  meta.broken = !enableProfiling;
                }
              )
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
