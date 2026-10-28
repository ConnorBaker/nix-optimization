# nix-optimization

Messing around with Clang's PGO/CSPGO/BOLT to optimize Nix for system closure evaluation.

> [!WARNING]
> Profiles from parallel evaluation are not reproducible, so build each variant's pipeline on a single machine.
>
> PGO/CSPGO/BOLT profiles are generated (at least, here) through instruction-level instrumentation, so they don't depend on the host architecture or on sampling. A single-threaded workload (like `closures.gnome`, with `--eval-cores 1`) should therefore give the same counts on every run, though that hasn't been checked.
>
> A multi-threaded workload (like `nixpkgs.parallel`, with `--eval-cores 16`) doesn't. Thread scheduling decides how often threads collide and retry in concurrent data structures, spin on locks, steal work, and hit or miss caches. It also decides the order in which attributes are constructed, and so how many comparisons sorting them takes. Two runs of the `nixpkgs.parallel` PGO training on Determinate Nix 3.23.1 profiled the same 25,134 functions with the same CFG hashes. 490 of those functions had different counts (e.g., `SymbolTable::create`, `CanonPath::operator<=>`, boost's `rw_spinlock::yield`), the edge profile overlap was 99.918%, and the total counts were 39,898,936,511 and 39,876,764,964.
>
> The differences are probably too small to change optimization decisions, but they're enough to break the build. The profile derivations are input-addressed, so two machines that each built one hold different contents at the same store path, and Nix assumes they're interchangeable. When a distributed build compiles some components against one copy and some against the other, linking them together with LTO fails:
>
> ```
> ld.lld: error: linking module flags 'ProfileSummary': IDs have conflicting values
> ```
>
> BOLT's `.fdata` from a parallel workload presumably varies the same way (unverified). There, a mismatch between the binary that was profiled and the binary being optimized doesn't fail the build: BOLT drops the functions whose profile doesn't match, so the result is just less optimized.
>
> To avoid this, build all of a variant's profiling stages and the final build on one machine (e.g., `--builders ''`), or make sure no other builder already has an earlier build of the profile derivations.

The top-level variants are trained on single-core evaluation of `nixos/release.nix closures.gnome`. The same variants trained instead on a read-only parallel (`--eval-cores 16`) evaluation of every derivation path in Nixpkgs (with CUDA enabled) are under `nixpkgs-parallel-eval`, e.g. `.#nixpkgs-parallel-eval.cs-pgo-bolt.nix-cli` (see `profileWorkloads` in `helper.nix`).

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
