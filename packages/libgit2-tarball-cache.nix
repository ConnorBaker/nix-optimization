{
  libgit2,
  fetchFromGitHub,
  stdenv,
  zlib-ng,
}:
# Companion dependency changes from Sergei Zimmerman's Nix PR #16427,
# head 36bdf2ab83431794a8740e4bb61d1d8c45b91843. Keep this in Nix's
# component scope: replacing global libgit2 would change unrelated consumers.
(libgit2.override { inherit stdenv; }).overrideAttrs (old: {
  version = "2.0.0-rc.1";
  src = fetchFromGitHub {
    owner = "libgit2";
    repo = "libgit2";
    rev = "ae45d0d168f7e8dbfdb8c623589cb51caac96ab3";
    hash = "sha256-3sbqHm37SOwBeFgtjI2DLN6kx1F7G2N1m6rRIkqDXNI=";
  };
  patches = (old.patches or [ ]) ++ [
    ../patches/libgit2/0001-zlib-ng-support.patch
    ../patches/libgit2/0002-memory-config.patch
    ../patches/libgit2/0003-packbuilder-correct-config.patch
  ];
  cmakeFlags = old.cmakeFlags ++ [ "-DUSE_COMPRESSION=zlib-ng" ];
  buildInputs = old.buildInputs ++ [ zlib-ng ];
  doCheck = true;
  meta = old.meta // {
    changelog = "https://github.com/libgit2/libgit2/commit/ae45d0d168f7e8dbfdb8c623589cb51caac96ab3";
  };
})
