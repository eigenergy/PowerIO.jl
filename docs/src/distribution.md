# Distribution networks

Multiconductor distribution cases parse into a [`MulticonductorNetwork`](@ref):
a live handle into the Rust core plus lazy element tables (`net.data`), matching
the balanced side's handle plus cached payload pattern. Distribution data is
unbalanced and per phase, so the two models never merge: string bus ids,
ordered terminal names, explicit grounding, SI units, and radians stay on the
multiconductor side, while the verbs are shared and route on the format.

The IEEE BMOPF schema remains a draft. Distribution parsing needs a library
built with `--features dist`, which released binaries include.
[`dist_available`](@ref) reports whether the resolved library has it.

[`features`](@ref) reports whether the resolved library carries distribution
support, and [`schema_versions`](@ref) names the BMOPF schema vintage this
build writes. Downstream packages should gate on those instead of checking
PowerIO version strings.

## Formats

| Format | Token | Extension |
|---|---|---|
| OpenDSS | `"dss"` | `.dss` |
| PowerModelsDistribution ENGINEERING JSON | `"pmd"` | `.json` |
| IEEE BMOPF Taskforce JSON | `"bmopf"` | `.json` |

A `.pio.json` stored module is not a case format and has no token: read it
with [`parse_file`](@ref) and take `m.value`.

A `.dss` path routes by extension. A bare `.json` routes by the same top level
markers the core parsers use (the ENGINEERING `data_model` key means PMD, BMOPF
otherwise); `format` overrides.

## The same verbs, routed by format

```julia
net = parse_file("switch.dss").value            # ::MulticonductorNetwork
net = parse_bytes(IOBuffer(text); format="dss").value
text, warnings = to_format(net, "pmd")    # dispatches on the network type
bmopf, _ = convert_file("switch.dss", "bmopf")
pmd, _   = convert_str(text, "pmd"; from="dss")

net.warnings            # parse warnings, retained on the handle
```

Writing back to the format the case was parsed from echoes the source byte for
byte; a cross-format write reports every fidelity loss in `warnings`.

Pin the parser explicitly with `format` when you want to pin the model
instead of routing on the extension: `parse_file(path; format="pmd")` and
`parse_file(path; format="bmopf")` reach their multiconductor parsers no
matter the extension, and the balanced format tokens reach the balanced
parsers the same way. Cross-model requests
(`convert_file("switch.dss", "matpower")`) are a directed error: lowering is
explicit, through `lower_to_balanced` below.

## Inspecting a case

The element tables mirror the core's multiconductor model and work without the library once
materialized. `n_buses`, `base_frequency`, `network_name`, `source_format`,
`net.warnings`, and REPL display read from the live
handle without forcing `net.data` when the C library exports
`pio_multiconductor_network_summary_json`. Metadata properties do the same; element table
properties materialize `net.data`. The multiline REPL display prints counts,
base frequency, warnings, and whether `net.data` has been materialized.

```julia
net.source_format
net.base_frequency
net.warnings
net.buses                 # same as buses(net)

buses(net)                # string ids, ordered terminals, explicit grounding
lines(net)                # terminal maps, linecode, length
linecodes(net)            # per unit length impedance and shunt matrices (SI)
transformers(net)         # windings with terminal maps and connection kinds
loads(net)                # terminal map plus a voltage model
generators(net)
shunts(net)
switches(net)
sources(net)              # per terminal magnitude and angle
ibrs(net)                 # inverter based resources
control_profiles(net)
capacitors(net)           # rated banks: q_rated (var), v_nom (V)
untyped(net)              # elements retained without a typed slot

n_buses(net)
base_frequency(net)       # Hz
network_name(net)         # Union{String,Nothing}
source_format(net)        # "dss", "pmd-json", "bmopf-json", or nothing
to_graph(net)             # collapsed bus and terminal graph
build_info().features.dist          # true when this build carries distribution support
build_info().foreign_schemas.bmopf  # the BMOPF schema vintage this build writes
```

The writer omits `ibrs`, `control_profiles`, and `capacitors` when they are
empty, so those accessors read a missing payload key as an empty table. The
other tables are always present in a library payload; a missing one raises a
`KeyError` and marks a wrong-shaped document.

## Carrying and exchanging cases

Two JSON forms exist on purpose, and they carry the same model:

- **`.pio.json` stored modules** carry a case between PowerIO consumers with
  sources, source maps, diagnostics, and history.
- **BMOPF JSON** is the format for tools outside PowerIO.

`parse_file("case.pio.json")` returns the module it stores; `m.value` is the
typed handle it declares, with the module's retained source threaded on so a
same format write still echoes the source bytes. Document JSON is not used by
solver, matrix, dense, or Arrow fast paths; those read live network handles
directly.

```julia
m = parse_file("switch.dss")            # ::PioModule{MulticonductorNetwork}
write_file(m, "feeder.pio.json"; format="pio-json")
back = parse_file("feeder.pio.json").value
exchange, _ = to_format(back, "bmopf")  # for everything else
```

Supported multiconductor modules lower explicitly to balanced ones:

```julia
report = lowering_readiness(m)          # what would lowering lose?
lowered = lower_to_balanced(m)          # picks a base_mva
net = lowered.value                     # ::BalancedNetwork
```
