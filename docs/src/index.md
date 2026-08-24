# PowerIO.jl

Julia entry point for [PowerIO](https://github.com/eigenergy/powerio): parser,
compiler package, and IR infrastructure for power system software. The Rust
core reads case files, writes them back, converts between formats, and exposes
the same model through Julia, Python, C/C++, and Rust.

```julia
using PowerIO

net = parse_file("case14.m")            # BalancedNetwork
length(PowerIO.buses(net))              # 14
text, warnings = convert_file("case14.m", "psse")
```

## Install

```julia
pkg> add PowerIO
```

Released versions fetch the prebuilt `powerio-capi` binary as a lazy artifact
on first use; you never build Rust. Working on the binding itself needs a
local build; see [Binary distribution](binary.md).

## Two network models

- [`BalancedNetwork`](@ref) — transmission: balanced positive sequence cases
  (MATPOWER, PSS/E, PowerWorld, PSLF EPC, PowerModels JSON, egret JSON,
  pandapower JSON, PyPSA CSV folders, Surge JSON). See
  [Transmission networks](transmission.md).
- [`MulticonductorNetwork`](@ref) — distribution: multiconductor unbalanced
  cases (OpenDSS, PowerModelsDistribution JSON, IEEE BMOPF JSON). See
  [Distribution networks](distribution.md).

The two share the same verbs, and the bare verbs route on the format:
`parse_file("case14.m")` returns a `BalancedNetwork`, `parse_file("feeder.dss")`
a `MulticonductorNetwork`, and `parse_file("case.pio.json")` whichever model
the package holds. `to_format`, `convert_file`, and `warnings` dispatch on the
network type; the type marker forms (`parse_file(BalancedNetwork, path)`,
`parse_file(MulticonductorNetwork, path)`) select a model explicitly.

## Where to go

- [Transmission networks](transmission.md) — parse, inspect, normalize,
  serialize, and extract dense arrays from a `BalancedNetwork`.
- [Matrices](matrices.md) — Rust computed sparse matrices as Julia native
  arrays and PowerModels compatible wrappers.
- [Distribution networks](distribution.md) — the `MulticonductorNetwork`
  API: parse and convert OpenDSS, PMD, and BMOPF cases.
- [Ecosystem interop](interop.md) — the bridges: PowerModels.jl,
  ExaModelsPower.jl, `.pio.json` packages, GridFM, GO Challenge 3.
- [Memory safety](memory-safety.md) — FFI ownership, lifetime guarantees,
  and remaining conditions.
- [API reference](api.md) — every docstring, grouped by area.

## Version compatibility

At first use the binding checks the library's ABI version
(`pio_abi_version`) against the version it targets and refuses a stale or
mismatched library with an error stating both versions. Distribution calls
also check `pio_dist_abi_version`. [`PowerIO.library_available`](@ref) probes
without throwing, and [`PowerIO.features`](@ref) reports the optional Arrow,
matrix, GridFM, distribution, package, and problem instance (`prob`) features. [`PowerIO.dist_capabilities`](@ref)
reports finer distribution fidelity flags for downstream packages.
