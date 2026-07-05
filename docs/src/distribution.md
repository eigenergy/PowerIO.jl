# Distribution networks

Multiconductor distribution cases parse into a [`MulticonductorNetwork`](@ref):
element tables (`net.data`) next to a live handle into the Rust core, the same
shape as a [`BalancedNetwork`](@ref). Distribution data is unbalanced and per
phase, so the two models never merge — string bus ids, ordered terminal names,
explicit grounding, SI units, radians — but the verbs are shared and route on
the format.

The surface is experimental while the BMOPF schema is v0.0.1, and needs the
library built with `--features dist` (the element tables also need `pkg`; both
are on by default in the released binaries). [`dist_available`](@ref) reports
whether the resolved library has it. The v0.6.1 release added the distribution
foundation: OpenDSS generator and IBR/control data, transformer
neutral impedance, core shunt and leakage data, and n-winding transformer
structure where the target format can express it. v0.6.2 adds the BMOPF
transformer, source, and diagnostic fidelity flags exposed through
[`dist_capabilities`](@ref).

[`dist_capabilities`](@ref) reports finer BMOPF export capabilities. Downstream
packages should use it instead of checking PowerIO version strings when they
need a v0.6.2 distribution fidelity fix.

## Formats

| Format | Token | Extension |
|---|---|---|
| OpenDSS | `"dss"` | `.dss` |
| PowerModelsDistribution ENGINEERING JSON | `"pmd"` | `.json` |
| IEEE BMOPF Taskforce JSON | `"bmopf"` | `.json` |
| PowerIO package JSON | `"powerio-json"` | `.pio.json` |

A `.dss` path routes by extension. A bare `.json` routes by the same top level
markers the core parsers use (the ENGINEERING `data_model` key means PMD, BMOPF
otherwise); `from` overrides.

## The same verbs, routed by format

```julia
net = parse_file("feeder.dss")            # ::MulticonductorNetwork
net = parse_str(text, "dss")
text, warnings = to_format(net, "pmd")    # dispatches on the network type
bmopf, _ = convert_file("feeder.dss", "bmopf")
pmd, _   = convert_str(text, "pmd"; from="dss")

PowerIO.warnings(net)   # parse warnings, retained on the handle
```

Writing back to the format the case was parsed from echoes the source byte for
byte; a cross-format write reports every fidelity loss in `warnings`.

The type-marker forms remain the explicit spelling when you want to pin the
model: `parse_file(MulticonductorNetwork, path)` routes nowhere, and
`parse_file(BalancedNetwork, path)` reaches the balanced parser no matter the
extension. Cross-model requests (`convert_file("feeder.dss", "matpower")`) are
a directed error: lowering is explicit, through the package pass below.

## Inspecting a case

The element tables mirror the core's multiconductor model (the
`pio-payload-multiconductor/1` payload) and work without the library once
materialized:

```julia
PowerIO.buses(net)          # string ids, ordered terminals, explicit grounding
PowerIO.lines(net)          # terminal_map_from / terminal_map_to, linecode, length
PowerIO.linecodes(net)      # per-unit-length impedance and shunt matrices (SI)
PowerIO.transformers(net)   # windings with terminal maps and connection kinds
PowerIO.loads(net)          # terminal_map plus a voltage model
PowerIO.generators(net)
PowerIO.shunts(net)
PowerIO.switches(net)
PowerIO.sources(net)        # per-terminal magnitude / angle

PowerIO.n_buses(net)
PowerIO.base_frequency(net)     # Hz
PowerIO.network_name(net)       # Union{String,Nothing}
PowerIO.source_format(net)      # "dss", "pmd-json", "bmopf-json", or nothing
PowerIO.dist_graph(net)         # collapsed bus / terminal graph projection
PowerIO.dist_capabilities()     # BMOPF export fidelity flags
```

## Carrying and exchanging cases

Two JSON forms exist on purpose, and they carry the same model:

- **`.pio.json` packages** carry a case between PowerIO consumers with
  provenance, diagnostics, and validation intact. `parse_file("case.pio.json")`
  returns whichever model the envelope declares.
- **BMOPF JSON** is the exchange format for tools outside PowerIO.

```julia
pkg = to_package(net)                   # ::NetworkPackage, model_kind = :multiconductor
write_package("feeder.pio.json", net)
back = from_package(pkg)                # ::MulticonductorNetwork again
exchange, _ = to_format(net, "bmopf")   # for everything else
```

A handle rebuilt from a package retains no source text, so a same-format write
is a fresh serialization rather than a byte-exact echo; the payload's parse
warnings ride along.

Supported multiconductor packages lower explicitly to balanced ones:

```julia
report = multiconductor_to_balanced_preflight(pkg)   # what would lowering lose?
bpkg = lower_multiconductor_to_balanced(pkg)         # picks a base_mva
net = from_package(bpkg)                             # ::BalancedNetwork
```
