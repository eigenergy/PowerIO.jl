# Modules

Every source parses into a [`PioModule`](@ref), which pairs one typed value
with the diagnostics, producer, sources, and history that say how it was
produced.

```julia
case = parse("case118.m")
case isa PioModule{BalancedNetwork}    # true
case.value                              # the BalancedNetwork
case.diagnostics                        # Vector{Diagnostic}
case.producer                           # Producer("powerio", "0.11.0")
case.sources                            # the files it was read from
case.history                            # the operations applied so far
```

The type parameter follows the source, so you can dispatch on it:

```julia
summarize(m::PioModule{BalancedNetwork}) = length(m.value.buses)
summarize(m::PioModule{MulticonductorNetwork}) = length(m.value.lines)
summarize(m::PioModule{<:TimeSeries}) = length(m.value)
```

| Source | Value type |
|---|---|
| MATPOWER, PSS/E RAW and RAWX, XIIDM, CGMES, PowerWorld, PSLF EPC, PowerModels JSON, Egret JSON, pandapower JSON, PyPSA CSV (one snapshot) | `BalancedNetwork` |
| OpenDSS, PMD JSON, BMOPF | `MulticonductorNetwork` |
| PyPSA CSV with several snapshots | `TimeSeries{BalancedNetwork}` |
| GridFM Parquet | `ScenarioSet{BalancedNetwork}` |
| GO Challenge 3 problem, or problem and solution | `AcScucInstance`, `AcScucSolution` |
| OPFData | `AcOpfSolution` |

If the library hands back a value type this release does not bind, you get an
[`UnknownValue`](@ref) with its structural type name.

## Sources

`parse` takes a path, an `IO`, or bytes. The `format` keyword is a canonical
token such as `"matpower"`, `"psse"`, `"xiidm"`, `"cgmes"`, or `"dss"`; leave
it out and the source name and content decide. For a source held in memory,
`name` supplies the source name.

```julia
parse("case9.m")
parse("cgmes_case/")                                    # a directory or ZIP for a profile set
parse(IOBuffer(text); format="matpower", name="case9.m")
parse(bytes; format="pwb", name="case.pwb")
open("case9.m") do io
    parse(io)                                           # an open file keeps its path as the name
end
```

A failed parse throws [`PowerIOError`](@ref) with a stable `code`, the rendered
`message`, and the structured `diagnostics` that caused it. The code is the
stable part, so branch on it rather than on the message.

## Diagnostics

Diagnostics belong to the module rather than to the value. Each
[`Diagnostic`](@ref) has a `code` (`"READ.MATPOWER.FIELD_DEFAULTED"`,
`"EMIT.PSSE.FIELD_DROPPED"`), a `severity` (`:error`, `:warning`, `:remark`,
`:note`), and a `message`. When the reader recorded them, it also has an `id`,
a `target` naming the element concerned, a `suggested_action`, source `spans`,
`related` diagnostic ids, and structured `details`.

```julia
for d in case.diagnostics
    d.severity == :warning || continue
    println(d.code, ": ", d.message)
end
```

## Emit

[`emit`](@ref) writes a module as a grid exchange format and returns an
[`EmitResult`](@ref).

```julia
same = emit(case, "matpower")            # in memory
same.fidelity                            # "exact_same_format"
same.text                                # the original file content

other = emit(case, "psse")
other.fidelity                           # "canonical": freshly written
other.diagnostics                        # what PSS/E cannot carry

emit(case, "psse", "case.raw")           # one file on disk
emit(case, "pypsa-csv", "case_dir")      # a directory of files
emit(case, "matpower", stdout)           # a writable IO receives the single file
```

`result.artifacts` lists what was produced, one [`Artifact`](@ref) per file with
its `name` and either its `data` (in memory) or its `path` (on disk). `layout`
is `"file"` or `"directory"`. `fidelity` is `"exact_same_format"` when the
module was read from that format and its value is unchanged, in which case the
output is the original file content; otherwise it is `"canonical"`. `text` is
the content of the single UTF-8 file when it was produced in memory, or
`nothing`.

## PowerIO IR

PowerIO IR is PowerIO's own serialization of a module: one JSON document
(`"schema": "pio-ir"`, integer generation `"version": 2`) holding the typed
value with its diagnostics, producer, sources, source mappings, history, and
extensions. The producer record separately names the PowerIO release that
wrote the document. [`serialize`](@ref) writes it and [`deserialize`](@ref)
reads it.

PowerIO 0.11 reads generation 2. The generation advances only when the
serialized representation changes, and it is independent of the PowerIO
release and the C ABI; [`library_version`](@ref) reports the library release.
A refused document names the generation it found and what to do about it: a
later generation needs a newer PowerIO, and a document with any other
`schema` or an older generation has to be regenerated from its original power
system data.

```julia
serialize(case, "case9.pio.json")
back = deserialize("case9.pio.json")     # PioModule{BalancedNetwork}
```

PowerIO IR is not a grid exchange format. `parse` does not read it, `emit`
does not write it, and it does not appear in format discovery. Use it when
both sides are PowerIO consumers and the diagnostics and history matter; use
`emit` for every other tool. The document does not include the original file
content, so a deserialized module writes canonical output rather than the
original file.

## Constructions

`to_dc_pf_instance`, `to_ac_pf_instance`, `to_dc_opf_instance`,
`to_ac_opf_instance`, `to_mc_ac_pf_instance`, and `to_mc_ac_opf_instance`
construct a calculation instance module from a network module. The network is
shared, and the new module's history has an entry for the construction. See
[Collections and instances](collections.md).

```@docs
PioModule
Producer
ModuleSource
HistoryEntry
Diagnostic
SourceSpan
PowerIOError
UnknownValue
emit
EmitResult
Artifact
serialize
deserialize
```
