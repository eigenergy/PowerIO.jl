# PowerIO.jl

[![CI](https://github.com/eigenergy/PowerIO.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/eigenergy/PowerIO.jl/actions/workflows/CI.yml)
[![Stable docs](https://img.shields.io/badge/docs-stable-blue.svg)](https://eigenergy.github.io/PowerIO.jl/stable/)
[![Dev docs](https://img.shields.io/badge/docs-dev-blue.svg)](https://eigenergy.github.io/PowerIO.jl/dev/)
[![Version](https://juliahub.com/docs/General/PowerIO/stable/version.svg)](https://juliahub.com/ui/Packages/General/PowerIO)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

<p align="center">
  <img
    src="https://raw.githubusercontent.com/eigenergy/powerio/main/docs/src/assets/powerio-logo.svg"
    alt="PowerIO logo"
    width="120"
  >
</p>

PowerIO.jl is the Julia binding of [PowerIO](https://github.com/eigenergy/powerio),
a compiler for power system data. It reads grid exchange formats into typed
Julia values, writes them back out, and computes the matrices power flow and
optimization code needs.

```julia
using PowerIO

case = parse("case14.m")             # PioModule{BalancedNetwork}
net = case.value
length(net.buses)                    # 14
net.branches[1].reactance_pu
case.diagnostics                     # Vector{Diagnostic}
emit(case, "matpower", "copy.m")     # same format: the original file, unchanged
emit(case, "psse").text              # another format
Y = calc_admittance_matrix(net)      # BusMappedMatrix{ComplexF64}
```

[Read the documentation](https://eigenergy.github.io/PowerIO.jl).

## Install

```julia
pkg> add PowerIO
```

The C library ships as a lazy artifact for Linux, macOS, and Windows on
`x86_64` and `aarch64`, so nothing compiles when you install.

## Formats

Balanced (transmission) sources parse into a `BalancedNetwork`: MATPOWER,
PSS/E RAW revisions 33 to 35 and RAWX 35, XIIDM 1.12 to 1.17, CGMES 2.4.15 and
3.0, PowerWorld AUX and PWB, PSLF EPC, and the PowerModels, Egret, and
pandapower JSON dialects. Multiconductor (distribution) sources parse into a
`MulticonductorNetwork`: OpenDSS, PMD JSON, and BMOPF. PyPSA folders with
several snapshots give a `TimeSeries`, GridFM datasets a `ScenarioSet`, and GO
Challenge 3 and OPFData files give calculation instances and solutions.

`emit` writes MATPOWER, PSS/E RAW and RAWX, XIIDM, CGMES, PowerWorld AUX,
PowerModels JSON, PyPSA CSV, GridFM, OpenDSS, PMD JSON, and BMOPF. If you write
a module back in the format it came from and nothing changed, you get the
original file.

## Operations

| Operation | What it does |
|---|---|
| `parse(source; format)` | read one source into a `PioModule{T}` |
| `emit(m, format, destination)` | write a grid exchange format |
| `serialize(m, destination)`, `deserialize(source)` | move PowerIO IR between PowerIO consumers |
| `calc_*(net)` | matrices and vectors |
| `to_*(m)` | construct another value in memory |
| `apply_updates!(m, updates)` | change a module in place |

Element tables such as `net.buses`, `net.branches`, and `net.lines` are
properties that behave as Julia vectors of immutable structs, with 1-based
indices.

## Development

PowerIO.jl calls the powerio C library (C ABI 7). To work against a local
build, clone `powerio` next to this checkout and build it:

```sh
git clone https://github.com/eigenergy/powerio ../powerio
(cd ../powerio && cargo build -p powerio-capi --release --features arrow,matrix,gridfm,dist,prob)
julia --project=. -e 'using Pkg; Pkg.instantiate(); Pkg.test()'
```

The package finds `../powerio/target/release` on its own. To use another
build, set `POWERIO_CAPI=/path/to/libpowerio_capi.so` or call
`PowerIO.set_library!(path)`. See CONTRIBUTING.md for the release flow.

## License

MIT. See LICENSE.
