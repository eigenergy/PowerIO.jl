# PowerIO.jl

PowerIO.jl 1.0 binds PowerIO 1.0 over C ABI 6. PowerIO 0.10 established the
public beta; 1.0 applies the final corrections found while building solver and
language consumers.

Julia binding of [PowerIO](https://github.com/eigenergy/powerio), the power
system data compiler. One call parses any supported source into a typed
module; `m.value` is the typed value.

```julia
using PowerIO

case = parse_file("case14.m")           # PioModule{BalancedNetwork}
n_buses(case)                           # 14
feeder = parse_file("switch.dss")       # PioModule{MulticonductorNetwork}
feeder.diagnostics                      # native Diagnostic records
result = emit(case, "psse")
result.text
result.diagnostics
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

The two network types share the same verbs. [`parse_file`](@ref) routes
filesystem input by format, while [`parse_text`](@ref) handles text in memory:
a `.m` path parses to a `PioModule{BalancedNetwork}`, a `.dss` path to a
`PioModule{MulticonductorNetwork}`, and a `.pio.json` to whichever value the
document stores. Calculation sources can instead produce an instance or
solution; supported datasets can produce a time series or scenario set.

## Where to go

- [Transmission networks](transmission.md) — parse, inspect, normalize,
  serialize, and extract dense arrays from a `BalancedNetwork`.
- [Matrices](matrices.md) — Rust computed sparse matrices as Julia native
  arrays and PowerModels compatible wrappers.
- [Distribution networks](distribution.md) — the `MulticonductorNetwork`
  API: parse and convert OpenDSS, PMD, and BMOPF cases.
- [Ecosystem interop](interop.md) — the bridges: PowerModels.jl,
  ExaModelsPower.jl, `.pio.json` modules, GridFM, and DOE GO Challenge 3.
- [Memory safety](memory-safety.md) — FFI ownership, lifetime guarantees,
  and remaining conditions.
- [API reference](api.md) — every docstring, grouped by area.

## Version compatibility

At first use the binding checks the library's ABI version
(`pio_abi_version`) against the version it targets and refuses a stale or
mismatched library with an error stating both versions.
[`library_available`](@ref) probes without throwing, and
[`features`](@ref) reports the optional Arrow, matrix, GridFM, distribution,
and problem instance (`prob`) features; [`schema_versions`](@ref) names the
document schema vintages this build speaks.
