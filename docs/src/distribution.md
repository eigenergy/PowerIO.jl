# Distribution networks

Multiconductor distribution cases parse into a [`MulticonductorNetwork`](@ref):
a live handle into the Rust core plus lazy element tables (`net.data`), matching
the balanced side's handle plus cached payload pattern. Distribution data is
unbalanced and per phase, so the two models never merge: string bus ids,
ordered terminal names, explicit grounding, SI units, and radians stay on the
multiconductor side, while the verbs are shared and route on the format.

The distribution API is experimental while the BMOPF schema is v0.0.1, and needs the
library built with `--features dist` (the element tables also need `pkg`; both
are on by default in the released binaries). [`dist_available`](@ref) reports
whether the resolved library has it. The v0.6.1 release added the distribution
foundation: OpenDSS generator and IBR/control data, transformer
neutral impedance, core shunt and leakage data, and n-winding transformer
structure where the target format can express it. v0.6.2 adds the BMOPF
transformer, source, and diagnostic fidelity flags exposed through
[`dist_capabilities`](@ref). v0.8 adds typed capacitor banks, line and
generator ratings, per-sequence bus bounds, and the transformer extras
relocation; the same capability document (schema 1.1.0) reports them, plus
the writer's BMOPF schema vintage (`bmopf_schema_id` /
`bmopf_schema_version`).

[`dist_capabilities`](@ref) reports finer BMOPF export capabilities.
Downstream packages should use it instead of checking PowerIO version
strings when they need version-specific distribution fidelity behavior. An
empty optional table has two possible causes: the case has none, or the
library predates the table. The capability flags tell the two apart — gate
on `dist_capabilities().typed_capacitors` before you read
`PowerIO.capacitors(net)`.

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

net.warnings            # parse warnings, retained on the handle
```

Writing back to the format the case was parsed from echoes the source byte for
byte; a cross-format write reports every fidelity loss in `warnings`.

The type marker forms remain the explicit spelling when you want to pin the
model: `parse_file(MulticonductorNetwork, path)` routes nowhere, and
`parse_file(BalancedNetwork, path)` reaches the balanced parser no matter the
extension. Cross-model requests (`convert_file("feeder.dss", "matpower")`) are
a directed error: lowering is explicit, through the package pass below.

## Inspecting a case

The element tables mirror the core's multiconductor model (the
`pio-payload-multiconductor/1` payload) and work without the library once
materialized. `PowerIO.n_buses`, `PowerIO.base_frequency`, `PowerIO.network_name`,
`PowerIO.source_format`, `net.warnings`, and REPL display read from the live
handle without forcing `net.data` when the C library exports
`pio_dist_summary_json`. Metadata properties do the same; element table
properties materialize `net.data`. The multiline REPL display prints counts,
base frequency, warnings, and whether `net.data` has been materialized.

```julia
net.source_format
net.base_frequency
net.warnings
net.buses                 # same as PowerIO.buses(net)

PowerIO.buses(net)          # string ids, ordered terminals, explicit grounding
PowerIO.lines(net)          # terminal_map_from / terminal_map_to, linecode, length
PowerIO.linecodes(net)      # per-unit-length impedance and shunt matrices (SI)
PowerIO.transformers(net)   # windings with terminal maps and connection kinds
PowerIO.loads(net)          # terminal_map plus a voltage model
PowerIO.generators(net)
PowerIO.shunts(net)
PowerIO.switches(net)
PowerIO.sources(net)        # per-terminal magnitude / angle
PowerIO.ibrs(net)           # inverter-based resources
PowerIO.control_profiles(net)
PowerIO.capacitors(net)     # rated banks: q_rated (var), v_nom (V); powerio v0.8
PowerIO.untyped(net)        # elements kept verbatim, no typed slot

PowerIO.n_buses(net)
PowerIO.base_frequency(net)     # Hz
PowerIO.network_name(net)       # Union{String,Nothing}
PowerIO.source_format(net)      # "dss", "pmd-json", "bmopf-json", or nothing
PowerIO.to_graph(net)           # collapsed bus / terminal graph projection
PowerIO.dist_capabilities()     # fidelity flags and BMOPF schema vintage
```

The writer omits `ibrs`, `control_profiles`, and `capacitors` when they are
empty, so those accessors read a missing payload key as an empty table. The
other tables are always present in a library payload; a missing one raises a
`KeyError` and marks a wrong-shaped document.

## Carrying and exchanging cases

Two JSON forms exist on purpose, and they carry the same model:

- **`.pio.json` packages** carry a case between PowerIO consumers with
  provenance, diagnostics, validation, operating points, and lowering history.
  Julia stores packages as JSON backed envelopes today.
- **BMOPF JSON** is the exchange format for tools outside PowerIO.

`parse_file("case.pio.json")` returns whichever model the envelope declares.
Package JSON is not used by solver, matrix, dense, or Arrow fast paths; those
read live network handles directly. `from_package(pkg)` rebuilds a live network
handle and leaves `net.data` unset until a caller asks for the rich payload.

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
