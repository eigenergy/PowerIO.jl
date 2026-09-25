# PTDF sensitivity

PowerIO provides a deterministic DC power transfer distribution factor (PTDF)
calculation built directly on the package existing DC operator axes.

## Definition

For a selected reference bus `r`, the PTDF columns represent transfers from
each non-reference bus to `r`. The implementation reuses the package incidence,
bus susceptance, and branch-flow operators, with the same branch orientation
and sign convention as the other DC calculations.

```julia
using PowerIO

net = parse("case9.m").value
ptdf = calc_ptdf(net)

ptdf.reference_bus
ptdf.bus_axis
ptdf.branch_axis
ptdf.matrix
```

A PTDF column can be applied to a balanced transaction directly:

```julia
transaction = zeros(length(ptdf.bus_axis))
transaction[findfirst(==(2), ptdf.bus_axis)] = 1.0
branch_flow_change = ptdf.matrix * transaction
```

The result is deterministic and does not invoke a power-flow solver. The
reduced bus susceptance matrix must be nonsingular; singular or islanded
topologies are reported instead of being handled with a pseudoinverse.

`reference_bus=:auto` selects the first `"REF"` bus in network table order.
For reproducible studies, an explicit bus id can be supplied.