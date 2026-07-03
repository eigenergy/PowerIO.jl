# Distribution networks

Multiconductor distribution cases are a separate model on their own
[`MulticonductorNetwork`](@ref) handle. Distribution data is unbalanced and
per-phase, so it does not flatten into the balanced positive sequence tables
of a [`BalancedNetwork`](@ref); the two models share verbs instead of types.

The surface is experimental while the BMOPF schema is v0.0.1, and needs the
library built with `--features dist` (on by default in the released
binaries). [`dist_available`](@ref) reports whether the resolved library has
it and speaks the distribution ABI this binding targets.

## Formats

| Format | Token | Extension |
|---|---|---|
| OpenDSS | `"dss"` | `.dss` |
| PowerModelsDistribution ENGINEERING JSON | `"pmd"` | `.json` |
| IEEE BMOPF Taskforce JSON | `"bmopf"` | `.json` |

A `.json` with the ENGINEERING `data_model` key infers as PMD, otherwise
BMOPF; `from` overrides.

## The same verbs, selected by type

Pass `MulticonductorNetwork` as the first argument to select the distribution
model — the `parse(T, x)` idiom, since Julia dispatches on argument types,
not the return type. `BalancedNetwork` is the default:

```julia
dn = parse_file(MulticonductorNetwork, "feeder.dss")
dn = parse_str(MulticonductorNetwork, text, "dss")

text, warnings = to_format(dn, "pmd")     # dispatches on the handle type
bmopf, _ = convert_file(MulticonductorNetwork, "feeder.dss", "bmopf")
pmd, _   = convert_str(MulticonductorNetwork, text, "pmd", "dss")

PowerIO.warnings(dn)   # fidelity warnings retained on the handle
```

Parsing a distribution file without the type marker fails: `parse_file("feeder.dss")`
throws, because the default `BalancedNetwork` readers do not speak OpenDSS.

Writing back to the format the handle was parsed from echoes the source byte
for byte; a cross-format write reports every fidelity loss in `warnings`.

## What the distribution surface does not have

There is no accessor or dense-array surface for `MulticonductorNetwork`: no
`buses(dn)`, no `to_dense(dn)`, no `to_json(dn)`. The surface is parse /
convert / serialize; structured access rides the format payloads. To work
with the data, serialize to the format whose schema fits and parse the JSON:

```julia
using JSON3
dn = parse_file(MulticonductorNetwork, "feeder.dss")
doc = JSON3.read(first(to_format(dn, "bmopf")))   # or "pmd"
```

[BMOPFTools.jl](https://github.com/eigenergy/BMOPFTools.jl) is the reference
consumer of this workflow: it parses OpenDSS through PowerIO, exports BMOPF
JSON, and post-processes the dictionary on the Julia side.

## Packages and lowering

A `MulticonductorNetwork` wraps into a `.pio.json` package like a balanced
network does, and supported multiconductor packages lower explicitly to
balanced ones:

```julia
mpkg = to_package(parse_file(MulticonductorNetwork, "feeder.dss"))
report = multiconductor_to_balanced_preflight(mpkg)   # what would lowering lose?
bpkg = lower_multiconductor_to_balanced(mpkg)         # a balanced package
net = from_package(bpkg)                              # ::BalancedNetwork
```

See [Ecosystem interop](interop.md) for the package surface.
