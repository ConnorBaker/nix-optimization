# nix-optimization

Messing around with Clang's PGO/CSPGO/BOLT to optimize Nix for system closure evaluation.

> [!NOTE]
> PGO/CSPGO/BOLT profiles are generated (at least, here) through instruction-level instrumentation. As such, they're invariant with respect to the host architecture/machine load at time of profile generation, so we can build these in parallel.

The top-level variants are trained on evaluation of `nixos/release.nix closures.gnome`. Variants trained on a read-only serial evaluation of every derivation path in Nixpkgs (with CUDA enabled) are under `nixpkgs-eval`, e.g. `.#nixpkgs-eval.cs-pgo-bolt.nix-cli` (see `profileWorkloads` in `helper.nix`). Upstream Nix does not provide Determinate's `--eval-cores` or `--lazy-trees` options.

All optimized and profiling component sets apply `patches/default-eval-store.patch`, adding an `eval-store` configuration setting. Its empty default preserves the normal build store; an explicit `--eval-store` takes precedence. The patch applies without offsets or fuzz to the pinned upstream Nix source (`a9f38ea0ee89f550616f342386f45e896f4abd18`). A separate `patches/upstream-clang-vtables.patch` gives two abstract classes out-of-line destructors to satisfy upstream's strict Clang vtable checks.

The `tarmac-baseline`, `tarmac-pgo`, and `tarmac-cs-pgo-bolt` packages build unmodified nix-tarmac against the corresponding Nix libraries and wrap the commands to load the plugin and select `eval-store = tarmac://` automatically. The upstream versioned library SONAMEs work with Tarmac's normal plugin dispatcher. Neither the Determinate compatibility patch nor a plugin-selection environment override is needed. `patches/append-plugin-files.patch` restores append support for filesystem-path lists, and the wrapper uses `extra-plugin-files` so separately configured plugins, such as gRPC, survive. The third optional argument to `tests/tarmac.sh` checks preservation of another plugin loader.

```console
nix build .#tarmac-baseline -o result-tarmac-baseline
nix build .#tarmac-pgo -o result-tarmac-pgo
./result-tarmac-pgo/bin/nix eval --expr '1 + 2'
bash tests/tarmac.sh ./result-tarmac-pgo/bin/nix /path/to/nixpkgs
```

Evaluation artifacts use the per-user Tarmac cache; build outputs use the ordinary build store. To bypass the configured default for a command, pass `--eval-store auto`. Profiling commands explicitly choose their evaluation store and enable the `nix-command` experimental feature.

On x86_64-linux, baseline and PGO builds pass Tarmac's six core tests and `tests/tarmac.sh`, including automatic store selection, persistence, concurrent writers, explicit overrides, legacy evaluation, and modern and legacy builds. Desktop evaluations produce the same derivation as evaluation through the normal store. CS-PGO/BOLT and aarch64 builds have not been validated on this branch. No running system daemon was replaced.

The cold substitution timeout also reproduces with Tarmac unloaded, using Nix's built-in `dummy://?read-only=false` evaluation store. Late-attached backtraces show the substitution thread waiting for download data while curl has an active transfer, an empty buffer, and no recorded pause. HTTP/1.1 also reproduces it. `tests/cold-eval.sh` runs repeated fresh-store evaluations, retaining failed stores and logs; its `dummy` control should be run with an unwrapped Nix binary. The pause/resume code introduced by [Nix PR #14614](https://github.com/NixOS/nix/pull/14614) is under investigation. The later lifetime and wakeup fixes, [#15604](https://github.com/NixOS/nix/pull/15604) and [#16090](https://github.com/NixOS/nix/pull/16090), are already included in the pin.

The unchanged gRPC store at `8d0368860b4c3865bd15b22f86605b2e2472f7b5` also builds against this branch's exact PGO libraries and passes all 13 tests. A local mTLS test preserved both plugin loaders, evaluated a fresh derivation through default Tarmac, built it over gRPC, and rejected anonymous clients and unlisted certificate identities. A genuine two-host remote-hook test remains outstanding. For all-to-all builders, use independent peer endpoints in `nix.buildMachines`, retaining the local daemon as the ordinary store; load the plugin in the daemon/build-hook configuration as well as the CLI. This topology requires no central scheduler or S3 service. A single offline CA, unique dual-purpose host certificates, and per-device SOPS private keys provide a small initial certificate setup. Remote GC is unsupported; active upstream issues [#200](https://github.com/Mic92/nix-grpc-store/issues/200) and [#203](https://github.com/Mic92/nix-grpc-store/issues/203) concern stale input caches and draining during uploads. No gRPC services are installed by this optimization flake.

The benchmarks below are historical results from the Determinate-based implementation; they do not measure the upstream builds on this branch.

Having built and created aliases for the various configurations (ensuring only a single job and using the current machine) with

```console
nix build -L .#{gcc,clang,baseline,bolt,pgo{,-bolt},cs-pgo{,-bolt}}.nix-cli --no-link && \
nix build -L .#gcc.nix-cli -o gcc && \
nix build -L .#clang.nix-cli -o clang && \
nix build -L .#baseline.nix-cli -o baseline && \
nix build -L .#bolt.nix-cli -o bolt && \
nix build -L .#pgo.nix-cli -o pgo && \
nix build -L .#pgo-bolt.nix-cli -o pgo-bolt && \
nix build -L .#cs-pgo.nix-cli -o cs-pgo && \
nix build -L .#cs-pgo-bolt.nix-cli -o cs-pgo-bolt
```

I then benchmarked the results by evaluating the same system closure as the profile:

```console
$ hyperfine --parameter-list variant gcc,clang,baseline,bolt,pgo,pgo-bolt,cs-pgo,cs-pgo-bolt '{variant}/bin/nix eval -f ../nixpkgs/nixos/release.nix closures.gnome --no-eval-cache --store dummy:// --eval-store dummy://?read-only=false' --min-runs 5 --warmup 2
Benchmark 1: gcc/bin/nix eval -f ../nixpkgs/nixos/release.nix closures.gnome --no-eval-cache --store dummy:// --eval-store dummy://?read-only=false
  Time (mean ± σ):      4.548 s ±  0.024 s    [User: 4.120 s, System: 0.501 s]
  Range (min … max):    4.526 s …  4.589 s    5 runs
 
Benchmark 2: clang/bin/nix eval -f ../nixpkgs/nixos/release.nix closures.gnome --no-eval-cache --store dummy:// --eval-store dummy://?read-only=false
  Time (mean ± σ):      4.475 s ±  0.007 s    [User: 4.088 s, System: 0.486 s]
  Range (min … max):    4.463 s …  4.482 s    5 runs
 
Benchmark 3: baseline/bin/nix eval -f ../nixpkgs/nixos/release.nix closures.gnome --no-eval-cache --store dummy:// --eval-store dummy://?read-only=false
  Time (mean ± σ):      4.514 s ±  0.010 s    [User: 4.122 s, System: 0.492 s]
  Range (min … max):    4.497 s …  4.523 s    5 runs
 
Benchmark 4: bolt/bin/nix eval -f ../nixpkgs/nixos/release.nix closures.gnome --no-eval-cache --store dummy:// --eval-store dummy://?read-only=false
  Time (mean ± σ):      4.365 s ±  0.009 s    [User: 3.968 s, System: 0.495 s]
  Range (min … max):    4.356 s …  4.379 s    5 runs
 
Benchmark 5: pgo/bin/nix eval -f ../nixpkgs/nixos/release.nix closures.gnome --no-eval-cache --store dummy:// --eval-store dummy://?read-only=false
  Time (mean ± σ):      4.059 s ±  0.019 s    [User: 3.695 s, System: 0.463 s]
  Range (min … max):    4.030 s …  4.083 s    5 runs
 
Benchmark 6: pgo-bolt/bin/nix eval -f ../nixpkgs/nixos/release.nix closures.gnome --no-eval-cache --store dummy:// --eval-store dummy://?read-only=false
  Time (mean ± σ):      4.020 s ±  0.016 s    [User: 3.637 s, System: 0.481 s]
  Range (min … max):    3.996 s …  4.037 s    5 runs
 
Benchmark 7: cs-pgo/bin/nix eval -f ../nixpkgs/nixos/release.nix closures.gnome --no-eval-cache --store dummy:// --eval-store dummy://?read-only=false
  Time (mean ± σ):      3.980 s ±  0.012 s    [User: 3.590 s, System: 0.488 s]
  Range (min … max):    3.961 s …  3.995 s    5 runs
 
Benchmark 8: cs-pgo-bolt/bin/nix eval -f ../nixpkgs/nixos/release.nix closures.gnome --no-eval-cache --store dummy:// --eval-store dummy://?read-only=false
  Time (mean ± σ):      3.950 s ±  0.011 s    [User: 3.568 s, System: 0.483 s]
  Range (min … max):    3.937 s …  3.965 s    5 runs
 
Summary
  cs-pgo-bolt/bin/nix eval -f ../nixpkgs/nixos/release.nix closures.gnome --no-eval-cache --store dummy:// --eval-store dummy://?read-only=false ran
    1.01 ± 0.00 times faster than cs-pgo/bin/nix eval -f ../nixpkgs/nixos/release.nix closures.gnome --no-eval-cache --store dummy:// --eval-store dummy://?read-only=false
    1.02 ± 0.01 times faster than pgo-bolt/bin/nix eval -f ../nixpkgs/nixos/release.nix closures.gnome --no-eval-cache --store dummy:// --eval-store dummy://?read-only=false
    1.03 ± 0.01 times faster than pgo/bin/nix eval -f ../nixpkgs/nixos/release.nix closures.gnome --no-eval-cache --store dummy:// --eval-store dummy://?read-only=false
    1.10 ± 0.00 times faster than bolt/bin/nix eval -f ../nixpkgs/nixos/release.nix closures.gnome --no-eval-cache --store dummy:// --eval-store dummy://?read-only=false
    1.13 ± 0.00 times faster than clang/bin/nix eval -f ../nixpkgs/nixos/release.nix closures.gnome --no-eval-cache --store dummy:// --eval-store dummy://?read-only=false
    1.14 ± 0.00 times faster than baseline/bin/nix eval -f ../nixpkgs/nixos/release.nix closures.gnome --no-eval-cache --store dummy:// --eval-store dummy://?read-only=false
    1.15 ± 0.01 times faster than gcc/bin/nix eval -f ../nixpkgs/nixos/release.nix closures.gnome --no-eval-cache --store dummy:// --eval-store dummy://?read-only=false
```
