# Ecosystem interop

| Target | Direction | Mechanism |
|---|---|---|
| PowerModels.jl | both | [`to_powermodels`](@ref) / [`from_powermodels`](@ref) |
| BMOPFTools.jl | both | PowerIO backed OpenDSS / BMOPF conversion |
| ExaModelsPower.jl / ExaPowerIO.jl | out | [`to_powerdata`](@ref) / [`parse_ac_power_data`](@ref) |
| PowerGridPlanning.jl | out | [`to_powermodels`](@ref), [`build_powermodels_ref`](@ref), and [`repair_powermodels_angle_bounds!`](@ref) |
| stored `.pio.json` module | both | [`parse_file`](@ref) / [`to_json`](@ref) / `m.value` |
| GridFM (gridfm-datakit Parquet) | in | [`read_gridfm`](@ref) / [`read_gridfm_scenarios`](@ref) |
| [PowerDiff.jl](https://github.com/grid-opt-alg-lab/PowerDiff.jl) | out | PowerDiff depends on PowerIO as its parser and data layer |
| OpenDSS / PMD / IEEE BMOPF | both | [`parse_file`](@ref) / [`emit`](@ref); see [Distribution networks](distribution.md) |

## PowerModels.jl

[`to_powermodels`](@ref) converts a parsed network to a PowerModels network
data dictionary — the post-parse `Dict{String,Any}` layout PowerModels.jl
consumes. [`from_powermodels`](@ref) reads one back.

```julia
using PowerIO

case = parse_file("case14.m")
data = to_powermodels(case)     # Dict{String,Any} with "bus", "branch", "gen", ...
net2 = from_powermodels(data)
```

PowerIO also exposes the reference dictionary helpers used by PowerModels style
packages:

```julia
data = to_powermodels(parse_file("case14.m"))
repair_powermodels_angle_bounds!(data)
ref = build_powermodels_ref(data)
```

## BMOPFTools.jl

BMOPFTools uses the distribution model for OpenDSS and BMOPF exchange.

```julia
using BMOPFTools

net = BMOPFTools.from_dss("Master.dss")
BMOPFTools.to_dss(net, "out/")
```

## ExaModelsPower.jl

[`to_powerdata`](@ref) returns a NamedTuple in ExaPowerIO's `PowerData`
layout; [`parse_ac_power_data`](@ref) returns the NamedTuple-of-arrays layout
consumed by ExaModelsPower's `build_polar_opf`, `build_rect_opf`, and
`build_dcopf` — GPU-ready struct-of-arrays with per unit conversion applied.

```julia
case = parse_file("case14.m")
pd = to_powerdata(case)
ac = parse_ac_power_data(case)
ac.bus, ac.gen, ac.branch, ac.arc, ac.ref_buses
```

ExaModelsPower can use that parser path directly and keep ExaPowerIO for test
data artifacts:

```julia
using ExaModelsPower

model, vars, cons = ExaModelsPower.ac_opf_model("case14.m")
model, vars, cons = ExaModelsPower.dcopf_model("case.raw")
```

## PowerGridPlanning.jl

PowerGridPlanning can preserve its `load_network` API while delegating parser
semantics, PowerModels reference construction, and branch angle repair to
PowerIO.

```julia
using PowerIO: parse_file, to_powermodels, build_powermodels_ref
import PowerGridPlanning

network = PowerGridPlanning.load_network("case14.m")
data = to_powermodels(parse_file("case14.m"))
ref = build_powermodels_ref(data)
```

## `.pio.json` stored modules

Stored `.pio.json` modules carry one typed value beside the module's records
(sources, source maps, diagnostics, history), over the native `pio_module_*`
C ABI surface.

```julia
m = parse_file("case14.m")               # ::PioModule{BalancedNetwork}
doc = to_json(m)                         # the stored version 1 document
back = from_json(PioModule, doc)

kind(m)                                  # "balanced_network"
m.diagnostics                            # structured diagnostic records
history(m)                               # descriptive history entries
module_sources(m)                        # source descriptors
```

Multiconductor modules check their lowering readiness and lower explicitly;
see [Distribution networks](distribution.md). The migration guide documents
the one way reader for earlier `.pio.json` documents.

## GridFM

[`read_gridfm`](@ref) reads a gridfm-datakit Parquet dataset into a
`BalancedNetwork`. It needs `--features gridfm`; [`gridfm_available`](@ref)
reports whether the loaded library includes it. Fields that GridFM cannot
represent appear in `diagnostics`.

```julia
r = read_gridfm("out/case14/raw")                # (; network, scenario, diagnostics)
to_matpower(r.network)                           # gridfm -> any classical format
reads = read_gridfm_scenarios("out/case14/raw")  # one result per scenario id
```
