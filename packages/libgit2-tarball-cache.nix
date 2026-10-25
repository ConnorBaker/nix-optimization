{
  libgit2,
  fetchFromGitHub,
  stdenv,
}:
# The libgit2 Nix PR #16427 builds against (packaging/hydra.nix at its head
# 6ef4a32b49): its tarball-cache change is compiled only for libgit2 >= 2.0,
# and 2.0.0-rc.1 contains the PR's two libgit2 changes (libgit2 #7366, #7367).
# Keep this in Nix's component scope: replacing global libgit2 would change
# unrelated consumers.
(libgit2.override { inherit stdenv; }).overrideAttrs (old: rec {
  version = "2.0.0-rc.1";
  src = fetchFromGitHub {
    owner = "libgit2";
    repo = "libgit2";
    tag = "v${version}";
    hash = "sha256-J3e9BGk0L3Fd1wLW0B969T5IzK0km6rnVLLNqAGFuTE=";
  };
  doCheck = true;
  meta = old.meta // {
    changelog = "https://github.com/libgit2/libgit2/releases/tag/v${version}";
  };
})
