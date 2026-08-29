# Modules

PowerIO 0.10 parses every source into a [`PioModule`](@ref): one typed value
with its retained source, diagnostics, source map, and history. A `.pio.json`
version 1 document serializes the value and durable records. This binding
wraps the ABI v6 handle surface: structured error handles, the module entry
points, and the DC branch data with borrowed array views.

Every handle is an independently owned reference over an immutable value.
Releasing a parent never invalidates a retained child, and every ccall on a
handle resolves its symbol from the library that created the handle, so a
handle outlives a `set_library!` switch. Parsing checks the resolved library
first: an ABI version this binding does not accept raises a directed error
naming both versions before any other ccall runs.

## The module surface

```@docs
PioModule
parse_file
parse_bytes
kind
diagnostics
Diagnostic
SourceSpan
inspect
source_format
write_file
write_str
write_report_str
write_json
state_inventory
select_state
lowering_readiness
lower_to_balanced
PowerIOCError
```

## Typed values

The value families a module can hold. The two network kinds are documented on
their own pages; the calculation, series, and scenario kinds are typed
carriers whose operations run on the module.

```@docs
TimeSeries
ScenarioSet
OperatingPoint
UnknownValue
DcPfInstance
AcPfInstance
DcOpfInstance
AcOpfInstance
McAcPfInstance
McAcOpfInstance
AcScucInstance
DcPfSolution
AcPfSolution
DcOpfSolution
AcOpfSolution
McAcPfSolution
McAcOpfSolution
AcScucSolution
```

## Typed records

```@docs
ModuleHistoryEntry
ModuleSource
history
sources
```

## DC branch data

The public equations and signs match PowerModels directly:

```text
A[e, from] = +1
A[e, to]   = -1
B  = A' * Diagonal(b) * A
Bf = Diagonal(b) * A
p_shift  = A' * (b .* shift)
p_bus    = -B * va + p_shift
p_branch = -Bf * va + b .* shift
```

Numeric spans surface as [`BorrowedVector`](@ref) read only views that keep
their owner handle alive; `copy` returns an ordinary mutable Julia array.
The stable element mappings (`row_ids`, `bus_ids`, and `omitted`) interpret
every row without another network extraction.

```@docs
DcData
dc_data
BorrowedVector
branch_flow
PowerIO.n_rows
PowerIO.n_buses(::DcData)
PowerIO.from_indices
PowerIO.to_indices
PowerIO.susceptance
PowerIO.shift
PowerIO.shift_injection
PowerIO.row_ids
PowerIO.bus_ids
PowerIO.omitted
PowerIO.formula
```

## Assembled matrices

```@docs
incidence_matrix
susceptance_laplacian
flow_matrix
bus_injection
```
