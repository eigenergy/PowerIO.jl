# Matrices

The matrix functions return Julia sparse matrices assembled by the Rust core.
They support [`BalancedNetwork`](@ref).

```julia
net = parse_file("case14.m")

Ybus = calc_admittance_matrix(net).matrix
Bp = calc_bprime_matrix(net).matrix
Bpp = calc_bdoubleprime_matrix(net).matrix

dc = DcPowerFlowData(net; convention=:series)
A = dc.incidence_matrix.matrix
b = dc.branch_susceptance
p_shift = dc.phase_shift_injection

B = calc_susceptance_matrix(net).matrix
Bf = calc_branch_susceptance_matrix(net)
```

`AdmittanceMatrix` carries a square bus matrix with `idx_to_bus` and
`bus_to_idx`. `IncidenceMatrix` carries the rectangular branch by bus matrix,
the same bus maps, and `branch_rows`.

## DC power flow

[`DcPowerFlowData`](@ref) follows the PowerModels orientation and signs:

```julia
A[e, from] = +1
A[e, to] = -1

b_series = imag(inv(r + im*x))
b_matpower = -1 / (x*tap)
b_reactance_only = -1 / x

B = A' * Diagonal(b) * A
Bf = Diagonal(b) * A
p_shift = A' * (b .* shift)

p_bus = -B * va + p_shift
p_branch = -Bf * va
```

`B` is the bus susceptance matrix and `Bf` is the branch susceptance matrix.
Phase shifts stay in `p_shift`, so `B` remains symmetric.

`dc.branch_rows[e]` is the 1-based branch table row for row `e` of `A` and
entry `e` of `b`. `dc.skipped_branch_rows` lists in-service branches omitted
because their DC denominator is too small. `dc.convention` is `:series`,
`:matpower`, or `:reactance_only`.

[`branch_susceptance`](@ref) returns `b` alone and needs a library built with
the `matrix` feature. `DcPowerFlowData` also needs `arrow` for `A`.

[`to_arrow`](@ref) remains available for callers that want the Rust COO tables
directly:

```julia
coo = to_arrow(net, :ybus)   # row_index, col_index, g, b
```
