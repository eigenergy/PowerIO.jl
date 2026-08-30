# Modules

PowerIO 0.10 parses every source into a [`PioModule`](@ref): one typed value
with its retained source, diagnostics, source map, and history. A `.pio.json`
version 1 document serializes the value and durable records. This binding
wraps the ABI v6 handle surface: structured error handles, module entry
points, and numerical operators.

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
kind
diagnostics
Diagnostic
SourceSpan
inspect
source_format
emit
to_json(::PioModule)
from_json(::Type{PioModule}, ::AbstractString)
state_inventory
select_state
to_balanced_report
to_balanced
PowerIOError
```

`m.diagnostics` is the preferred field-like spelling; `diagnostics(m)` remains
a 0.10 compatibility function. Output goes through `emit`:
`emit(m, "matpower")` returns text and findings, while
`emit(m, "matpower", "case.m")` writes to a file or directory.

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

A balanced network or balanced operating point time series follows Julia's
integer collection conventions:

```julia
series = parse_file("network.csv"; format="pypsa-csv")
length(series)
first_state = series[1]       # a selected PioModule
for state in series
    n_buses(state)
end
```

A multiconductor operating point series keeps its typed value and explicit
`state_inventory`, but has no collection indexing until terminal state has a
lossless static network representation. `select_state` returns the structured
`REQUEST.STATE.UNBOUND_EXPORT` refusal instead of inventing that mapping.

A scenario set uses its scenario identifiers as string keys:

```julia
ids = keys(scenarios)
state = scenarios[first(ids)]
```

## Typed records

```@docs
ModuleHistoryEntry
ModuleSource
history
module_sources
sources
```

## DC matrices and flows

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

The module methods return the canonical matrices directly. The selected
formula defaults to series susceptance and can be changed with the `formula`
keyword.

```julia
case = parse_file("case14.m")
A = calc_incidence_matrix(case)              # branches by buses
B = calc_bus_susceptance_matrix(case)        # buses by buses
Bf = calc_branch_susceptance_matrix(case)    # branches by buses
p_shift = calc_phase_shift_injection(case)   # buses
f = calc_branch_flow_dc(case, voltage_angles)
p = A' * f                              # bus injections
```

```@docs
PowerIO.calc_incidence_matrix(::PioModule{BalancedNetwork})
PowerIO.calc_bus_susceptance_matrix(::PioModule{BalancedNetwork})
PowerIO.calc_branch_susceptance_matrix(::PioModule{BalancedNetwork})
PowerIO.calc_phase_shift_injection(::PioModule{BalancedNetwork})
PowerIO.calc_branch_flow_dc(::PioModule{BalancedNetwork}, ::AbstractVector{<:Real})
```
