# PowerIO.jl

Julia bindings for [PowerIO](https://github.com/eigenergy/powerio), a Rust
core that reads power system case files, writes them back, and converts
between formats. The Rust core does the parsing and the byte exact write, so a
case reads identically in Julia, Python, C/C++, and Rust.

```julia
using PowerIO

net = parse_file("case14.m")            # BalancedNetwork
PowerIO.n_buses(net)                    # 14
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
  (MATPOWER, PSS/E, PowerWorld, PowerModels JSON, egret JSON). See
  [Transmission networks](transmission.md).
- [`MulticonductorNetwork`](@ref) — distribution: multiconductor unbalanced
  cases (OpenDSS, PowerModelsDistribution JSON, IEEE BMOPF JSON). See
  [Distribution networks](distribution.md).

The two share the same verbs, and the bare verbs route on the format:
`parse_file("case14.m")` returns a `BalancedNetwork`, `parse_file("feeder.dss")`
a `MulticonductorNetwork`, and `parse_file("case.pio.json")` whichever model
the package holds. `to_format`, `convert_file`, and `warnings` dispatch on the
network type; the type-marker forms (`parse_file(BalancedNetwork, path)`,
`parse_file(MulticonductorNetwork, path)`) pin a model explicitly.

## Where to go

- [Transmission networks](transmission.md) — parse, inspect, normalize,
  serialize, and extract dense arrays from a `BalancedNetwork`.
- [Distribution networks](distribution.md) — the `MulticonductorNetwork`
  surface: parse and convert OpenDSS, PMD, and BMOPF cases.
- [Ecosystem interop](interop.md) — the bridges: PowerModels.jl,
  ExaModelsPower.jl, `.pio.json` packages, GridFM, GO Challenge 3.
- [API reference](api.md) — every docstring, grouped by area.

## Version compatibility

At first use the binding checks the library's ABI version
(`pio_abi_version`) against the version it targets and refuses a stale or
mismatched library with an error stating both versions. Distribution calls
also check `pio_dist_abi_version`. [`PowerIO.library_available`](@ref) probes
without throwing.
