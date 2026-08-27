# Stored modules and ABI v6

PowerIO 1.0 stores one typed value with its common records as a
`PioModule<PioValue>`, serialized as `.pio.json` version 1. This binding
wraps the ABI v6 handle surface: structured error handles, the stored module
entry points, and the DC branch data with borrowed array views.

Every handle is an independently owned reference over an immutable value.
Releasing a parent never invalidates a retained child, and every ccall on a
handle resolves its symbol from the library that created the handle, so a
handle outlives a `set_library!` switch. The v6 entry points ship with
powerio releases past 0.9. Reading or parsing a module checks the resolved
library first: an ABI version this binding does not accept, or an accepted
version missing the v6 entry points (a v5 library), each raise a directed
error naming what is wrong before any v6 ccall runs.

## Modules

```@docs
StoredModule
read_module
parse_module
parse_module_str
write_module
module_kind
inspect_module
state_inventory
export_state
lower_module_to_balanced
PowerIOCError
```

## Typed records

```@docs
ModuleDiagnostic
ModuleHistoryEntry
ModuleSource
module_diagnostics
module_history
module_sources
```

## DC branch data

The public equations and signs match PowerModels directly:

```text
A[e, from] = +1
A[e, to]   = -1
B  = A' * Diagonal(b) * A
Bf = Diagonal(b) * A
p_shift  = -A' * (b .* shift)
p_bus    = -B * va + p_shift
p_branch = -Bf * va - b .* shift
```

Numeric spans surface as [`BorrowedVector`](@ref) read only views that keep
their owner handle alive; `copy` returns an ordinary mutable Julia array.
The stable element mappings (`PowerIO.row_ids`, `PowerIO.bus_ids`,
`PowerIO.omitted`) interpret every row without another network extraction.

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
PowerIO.shift_injection
PowerIO.row_ids
PowerIO.bus_ids
PowerIO.omitted
PowerIO.formula
```
