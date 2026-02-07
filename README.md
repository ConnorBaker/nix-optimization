# nix-optimization

Messing around with Clang's PGO/CSPGO/BOLT to optimize Nix for system closure evaluation.

> [!NOTE]
> PGO/CSPGO/BOLT profiles are generated (at least, here) through instruction-level instrumentation. As such, they're invariant with respect to the host architecture/machine load at time of profile generation, so we can build these in parallel.

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
$ hyperfine --parameter-list variant gcc,clang,baseline,bolt,pgo,pgo-bolt,cs-pgo,cs-pgo-bolt '{variant}/bin/nix eval -f ../nixpkgs/nixos/release.nix closures.gnome --no-eval-cache --eval-cores 1 --store dummy:// --eval-store dummy://?read-only=false' --min-runs 5 --warmup 2
Benchmark 1: gcc/bin/nix eval -f ../nixpkgs/nixos/release.nix closures.gnome --no-eval-cache --eval-cores 1 --store dummy:// --eval-store dummy://?read-only=false
  Time (mean ± σ):      4.548 s ±  0.024 s    [User: 4.120 s, System: 0.501 s]
  Range (min … max):    4.526 s …  4.589 s    5 runs
 
Benchmark 2: clang/bin/nix eval -f ../nixpkgs/nixos/release.nix closures.gnome --no-eval-cache --eval-cores 1 --store dummy:// --eval-store dummy://?read-only=false
  Time (mean ± σ):      4.475 s ±  0.007 s    [User: 4.088 s, System: 0.486 s]
  Range (min … max):    4.463 s …  4.482 s    5 runs
 
Benchmark 3: baseline/bin/nix eval -f ../nixpkgs/nixos/release.nix closures.gnome --no-eval-cache --eval-cores 1 --store dummy:// --eval-store dummy://?read-only=false
  Time (mean ± σ):      4.514 s ±  0.010 s    [User: 4.122 s, System: 0.492 s]
  Range (min … max):    4.497 s …  4.523 s    5 runs
 
Benchmark 4: bolt/bin/nix eval -f ../nixpkgs/nixos/release.nix closures.gnome --no-eval-cache --eval-cores 1 --store dummy:// --eval-store dummy://?read-only=false
  Time (mean ± σ):      4.365 s ±  0.009 s    [User: 3.968 s, System: 0.495 s]
  Range (min … max):    4.356 s …  4.379 s    5 runs
 
Benchmark 5: pgo/bin/nix eval -f ../nixpkgs/nixos/release.nix closures.gnome --no-eval-cache --eval-cores 1 --store dummy:// --eval-store dummy://?read-only=false
  Time (mean ± σ):      4.059 s ±  0.019 s    [User: 3.695 s, System: 0.463 s]
  Range (min … max):    4.030 s …  4.083 s    5 runs
 
Benchmark 6: pgo-bolt/bin/nix eval -f ../nixpkgs/nixos/release.nix closures.gnome --no-eval-cache --eval-cores 1 --store dummy:// --eval-store dummy://?read-only=false
  Time (mean ± σ):      4.020 s ±  0.016 s    [User: 3.637 s, System: 0.481 s]
  Range (min … max):    3.996 s …  4.037 s    5 runs
 
Benchmark 7: cs-pgo/bin/nix eval -f ../nixpkgs/nixos/release.nix closures.gnome --no-eval-cache --eval-cores 1 --store dummy:// --eval-store dummy://?read-only=false
  Time (mean ± σ):      3.980 s ±  0.012 s    [User: 3.590 s, System: 0.488 s]
  Range (min … max):    3.961 s …  3.995 s    5 runs
 
Benchmark 8: cs-pgo-bolt/bin/nix eval -f ../nixpkgs/nixos/release.nix closures.gnome --no-eval-cache --eval-cores 1 --store dummy:// --eval-store dummy://?read-only=false
  Time (mean ± σ):      3.950 s ±  0.011 s    [User: 3.568 s, System: 0.483 s]
  Range (min … max):    3.937 s …  3.965 s    5 runs
 
Summary
  cs-pgo-bolt/bin/nix eval -f ../nixpkgs/nixos/release.nix closures.gnome --no-eval-cache --eval-cores 1 --store dummy:// --eval-store dummy://?read-only=false ran
    1.01 ± 0.00 times faster than cs-pgo/bin/nix eval -f ../nixpkgs/nixos/release.nix closures.gnome --no-eval-cache --eval-cores 1 --store dummy:// --eval-store dummy://?read-only=false
    1.02 ± 0.01 times faster than pgo-bolt/bin/nix eval -f ../nixpkgs/nixos/release.nix closures.gnome --no-eval-cache --eval-cores 1 --store dummy:// --eval-store dummy://?read-only=false
    1.03 ± 0.01 times faster than pgo/bin/nix eval -f ../nixpkgs/nixos/release.nix closures.gnome --no-eval-cache --eval-cores 1 --store dummy:// --eval-store dummy://?read-only=false
    1.10 ± 0.00 times faster than bolt/bin/nix eval -f ../nixpkgs/nixos/release.nix closures.gnome --no-eval-cache --eval-cores 1 --store dummy:// --eval-store dummy://?read-only=false
    1.13 ± 0.00 times faster than clang/bin/nix eval -f ../nixpkgs/nixos/release.nix closures.gnome --no-eval-cache --eval-cores 1 --store dummy:// --eval-store dummy://?read-only=false
    1.14 ± 0.00 times faster than baseline/bin/nix eval -f ../nixpkgs/nixos/release.nix closures.gnome --no-eval-cache --eval-cores 1 --store dummy:// --eval-store dummy://?read-only=false
    1.15 ± 0.01 times faster than gcc/bin/nix eval -f ../nixpkgs/nixos/release.nix closures.gnome --no-eval-cache --eval-cores 1 --store dummy:// --eval-store dummy://?read-only=false
```
