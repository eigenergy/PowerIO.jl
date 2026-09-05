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

case = parse("case9.m")              # PioModule{BalancedNetwork}
net = case.value
length(net.buses)                    # 9
net.branches[1].reactance_pu
case.diagnostics                     # Vector{Diagnostic}
emit(case, "matpower", "copy.m")     # same format: the original file, unchanged
emit(case, "psse").text              # another format
Y = calc_admittance_matrix(net)      # BusMappedMatrix{ComplexF64}
```

Save [case9.m](https://github.com/eigenergy/powerio/blob/main/tests/data/case9.m)
in your working directory to run the example, or use the path to your own case.

[Read the documentation](https://eigenergy.github.io/PowerIO.jl).

## Install

```julia
pkg> add PowerIO
```

Requires Julia 1.9 or newer. The native library downloads on first use, with
prebuilt binaries for Linux with glibc (`x86_64`, `aarch64`), macOS
(`x86_64`, Apple silicon), and Windows (`x86_64`).

For an existing 0.10 application, follow the
[migration guide](https://eigenergy.github.io/PowerIO.jl/dev/migration-0.11/).
PowerIO.jl 0.11 uses PowerIO 0.11, PowerIO IR generation 2, and C ABI 7.

## Formats

Balanced (transmission) sources parse into a `BalancedNetwork`: MATPOWER,
PSS/E RAW revisions 32 to 35 and RAWX 35, XIIDM and JIIDM 1.0 to 1.17,
CGMES 2.4.15 and 3.0, UCTE-DEF, IEEE Common Data Format, PowerWorld AUX and
PWB, PSLF EPC, and the PowerModels, Egret, pandapower, and Surge JSON
dialects. Multiconductor (distribution) sources parse into a
`MulticonductorNetwork`: OpenDSS, PMD JSON, and BMOPF. PyPSA folders with
several snapshots give a `TimeSeries`, GridFM datasets a `ScenarioSet`, and GO
Challenge 3 and OPFData files give calculation instances and solutions.

The [format guide](https://eigenergy.github.io/powerio/guide/format-fidelity.html)
lists the format tokens, read and write coverage, and conversion limits.
PWB, IEEE CDF, and OPFData are read only. A PowerWorld PWD display produces a
geographic layer. For a format with a writer, `emit` can return retained
source bytes when the module is unchanged; `result.fidelity` identifies
that case, and `result.diagnostics` reports any conversion losses.

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

## Save a module

```julia
serialize(case, "case9.pio.json")
restored = deserialize("case9.pio.json")   # PioModule{BalancedNetwork}
```

PowerIO IR keeps the typed value with its diagnostics and history. Original
source bytes stay in the running process, so `emit` produces fresh output
after deserialization. Use `emit` to export data to another grid tool.

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
