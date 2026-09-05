# PowerIO.jl

PowerIO.jl is the Julia binding of [PowerIO](https://github.com/eigenergy/powerio),
a compiler for power system data. It reads grid exchange formats (MATPOWER,
PSS/E RAW and RAWX, XIIDM, CGMES, PowerWorld, PSLF, PyPSA, GridFM, OpenDSS,
PMD JSON, BMOPF, and the PowerModels, Egret, and pandapower JSON dialects) into
typed Julia values, writes them back out, and computes the matrices power flow
and optimization code needs.

```julia
using Pkg; Pkg.add("PowerIO")
```

```julia
using PowerIO

case = parse("case9.m")              # PioModule{BalancedNetwork}
net = case.value
length(net.buses)                    # 9
net.branches[1].reactance_pu         # 0.0576
[g.active_power_mw for g in net.generators]
case.diagnostics                     # what the reader kept, defaulted, or dropped

emit(case, "matpower", "copy.m")     # same format: the original file, unchanged
result = emit(case, "psse")          # another format, in memory
result.text
result.diagnostics                   # what PSS/E cannot carry

serialize(case, "case9.pio.json")    # PowerIO IR, for other PowerIO consumers
```

## Operations

The operations share their names with the Rust, Python, and C APIs:

| Operation | What it does |
|---|---|
| `parse(source; format)` | reads one grid exchange source into a `PioModule{T}` |
| `emit(module, format, destination)` | writes a grid exchange format |
| `serialize(module, destination)` and `deserialize(source)` | move PowerIO IR between PowerIO consumers |
| `calc_*(net)` | computes a matrix or vector |
| `to_*(module)` | constructs another value type in memory |
| `apply_updates!(module, updates)` | changes a module in place |

Element tables are properties of a network (`net.buses`, `net.branches`,
`net.lines`) and behave as Julia vectors of immutable structs. Indices are
1-based, in the tables and in the sparse matrices alike. `parse` extends
`Base.parse`, so the bare name works after `using PowerIO`.

## Pages

- [Modules](modules.md): `PioModule`, sources, diagnostics, `emit`, PowerIO IR.
- [Networks](networks.md): `BalancedNetwork` and its element structs.
- [Distribution](distribution.md): `MulticonductorNetwork`.
- [Collections and instances](collections.md): time series, scenario sets,
  calculation instances and solutions.
- [Matrices](matrices.md): the DC calculations and the admittance matrices.
- [Updates](updates.md): typed updates and `apply_updates!`.
- [Interop](interop.md): PowerModels.jl, ExaModelsPower, GridFM.
- Developer guides: [migrating to 0.11](migration-0.11.md), the
  [binary distribution](binary.md), [memory safety](memory-safety.md), the
  [language map](languages.md), and the [API reference](api.md).

## The C library

PowerIO.jl calls the powerio C library (`libpowerio_capi`, C ABI 7). You do
not normally have to find it yourself: on a supported platform the bundled
artifact is used, and during development a sibling `powerio` checkout's build
is picked up. To point at another build, call [`set_library!`](@ref) or set
the `POWERIO_CAPI` environment variable. [`library_available`](@ref) tells you
whether a compatible library was found, and [`abi_version`](@ref) which ABI
number it was built with.
