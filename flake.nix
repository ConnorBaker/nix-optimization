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
