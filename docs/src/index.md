# PowerIO.jl

PowerIO 0.10 is the public beta of the 1.0 API. API corrections may land before 1.0.0 as downstream integrations exercise the new design.

Julia binding of [PowerIO](https://github.com/eigenergy/powerio), the power
system data compiler. One call parses any supported source into a typed
module, and the type parameter drives ordinary dispatch in everything that
follows.

```julia
using PowerIO

case = parse_file("case14.m")           # PioModule{BalancedNetwork}
n_buses(case.value)                     # 14
feeder = parse_file("feeder.dss")       # PioModule{MulticonductorNetwork}
diagnostics(feeder)                     # native Diagnostic records
text, findings = convert_file("case14.m", "psse")
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

The two share the same verbs, and [`parse_file`](@ref) routes on the format:
a `.m` path parses to a `PioModule{BalancedNetwork}`, a `.dss` path to a
`PioModule{MulticonductorNetwork}`, and a `.pio.json` to whichever value the
document stores. `m.value` is the typed network handle, and `to_format`,
`convert_file`, and `warnings` dispatch on its type.

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
mismatched library with an error stating both versions.
[`PowerIO.library_available`](@ref) probes without throwing, and
[`features`](@ref) reports the optional Arrow, matrix, GridFM, distribution,
and problem instance (`prob`) features; [`schema_versions`](@ref) names the
document schema vintages this build speaks.
