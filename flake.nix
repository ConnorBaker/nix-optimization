{
  inputs = {
    nix = {
      url = "github:DeterminateSystems/nix-src";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    flake-parts.follows = "nix/flake-parts";

    nixpkgs.url = "github:nixos/nixpkgs";

    git-hooks-nix.url = "github:cachix/git-hooks.nix";

    treefmt-nix.url = "github:numtide/treefmt-nix";
  };

  outputs =
    inputs:
    inputs.flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "aarch64-linux"
        "x86_64-linux"
      ];

      imports = [
        inputs.treefmt-nix.flakeModule
        inputs.git-hooks-nix.flakeModule
      ];

      perSystem =
        {
          config,
          lib,
          pkgs,
          system,
          ...
        }:
        {
          legacyPackages =
            let
              helper = import ./helper.nix {
                inherit inputs lib pkgs;
              };
            in
            {
              gcc =
                (inputs.nix.lib.makeComponents {
                  inherit pkgs;
                  getStdenv = builtins.getAttr "stdenv";
                }).overrideScope
                  (
                    final: prev: {
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
                      boehmgc = pkgs.boehmgc.override {
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
                      };
                    }
                  );

              clang =
                (inputs.nix.lib.makeComponents {
                  inherit pkgs;
                  getStdenv = builtins.getAttr "clangStdenv";
                }).overrideScope
                  (
                    final: prev: {
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
                      boehmgc = pkgs.boehmgc.override {
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
                      };
                    }
                  );

              baseline = helper { };

              bolt-profiling = helper {
                enableBOLTProfiling = true;
              };

              bolt = helper {
                withBOLTProfiling = config.legacyPackages.bolt-profiling;
                enableBOLT = true;
              };

              pgo-profiling = helper {
                enablePGOProfiling = true;
              };

              pgo = helper {
                withPGOProfiling = config.legacyPackages.pgo-profiling;
                enablePGO = true;
              };

              pgo-bolt-profiling = helper {
                withPGOProfiling = config.legacyPackages.pgo-profiling;
                enablePGO = true;
                enableBOLTProfiling = true;
              };

              pgo-bolt = helper {
                withPGOProfiling = config.legacyPackages.pgo-profiling;
                enablePGO = true;
                withBOLTProfiling = config.legacyPackages.pgo-bolt-profiling;
                enableBOLT = true;
              };

              cs-pgo-profiling = helper {
                # CSPGO Profiling requires the PGO profile as well
                withPGOProfiling = config.legacyPackages.pgo-profiling;
                enableCSPGOProfiling = true;
              };

              cs-pgo = helper {
                withCSPGOProfiling = config.legacyPackages.cs-pgo-profiling;
                enableCSPGO = true;
              };

              cs-pgo-bolt-profiling = helper {
                withCSPGOProfiling = config.legacyPackages.cs-pgo-profiling;
                enableCSPGO = true;
                enableBOLTProfiling = true;
              };

              cs-pgo-bolt = helper {
                withCSPGOProfiling = config.legacyPackages.cs-pgo-profiling;
                enableCSPGO = true;
                withBOLTProfiling = config.legacyPackages.cs-pgo-bolt-profiling;
                enableBOLT = true;
              };
            };

          pre-commit.settings.hooks = {
            # Formatter checks
            treefmt = {
              enable = true;
              package = config.treefmt.build.wrapper;
            };

            # Nix checks
            deadnix.enable = true;
            nil.enable = true;
            statix.enable = true;
          };

          treefmt = {
            projectRootFile = "flake.nix";
            programs = {
              # Nix
              nixfmt.enable = true;

              # Shell
              shellcheck.enable = true;
              shfmt.enable = true;
            };
          };
        };
    };
}
