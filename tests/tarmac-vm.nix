# Runs tests/tarmac.sh in a VM, as an ordinary user of a nix-daemon using the
# wrapped Nix, so the builders can run it on any system they have, not just the
# machine at hand. The VM is offline: its store already holds the Nixpkgs
# source and what the script's runCommand derivations build with.
{
  pkgs,
  nix,
  nixpkgs,
}:
pkgs.testers.runNixOSTest {
  name = "tarmac-${nix.name}";

  nodes.machine = {
    nix = {
      package = nix;
      settings = {
        experimental-features = [
          "nix-command"
          "flakes"
        ];
        substituters = pkgs.lib.mkForce [ ];
      };
      # The flake check and bundle tests resolve `nixpkgs` through the registry.
      registry.nixpkgs.to = {
        type = "path";
        path = nixpkgs;
      };
    };
    environment.systemPackages = [ pkgs.jq ];
    system.extraDependencies = [
      nixpkgs
      pkgs.stdenvNoCC
      pkgs.stdenv
      pkgs.bashInteractive
    ];
    users.users.tester.isNormalUser = true;
    virtualisation = {
      cores = 4;
      diskSize = 8192;
      memorySize = 4096;
      writableStore = true;
    };
  };

  testScript = ''
    machine.wait_for_unit("multi-user.target")
    machine.succeed(
      "su - tester -c 'bash ${./tarmac.sh} ${nix}/bin/nix ${nixpkgs}' >&2"
    )
  '';
}
