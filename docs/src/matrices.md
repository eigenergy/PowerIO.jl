# Matrices

The calculations on this page take a `BalancedNetwork` or a
`PioModule{BalancedNetwork}` and return `SparseMatrixCSC` or `Vector{Float64}`
values with 1-based indices. The DC calculations come from the powerio
library; the admittance matrices are assembled in Julia.

## DC calculations

The powerio library computes the eight DC calculations, under the same names
as the Rust, Python, and C APIs. With `A` the branch by bus incidence matrix
(`+1` at the from bus, `-1` at the to bus of every in-service branch) and `b`
the branch susceptances:

```julia
A  = calc_incidence_matrix(net)            # branches by buses
b  = calc_branch_susceptances(net)         # one per in-service branch
B  = calc_bus_susceptance_matrix(net)      # A' * Diagonal(b) * A
Bf = calc_branch_flow_matrix(net)          # Diagonal(b) * A
ps = calc_branch_phase_shift_injection(net)
pb = calc_bus_phase_shift_injection(net)

va = zeros(length(net.buses))              # bus voltage angles, radians
pf = calc_branch_flow_dc(net, va)          # -(Bf * va) + ps
p  = calc_bus_injection_dc(net, va)        # -(B * va) + pb
```

`formula="series_susceptance"` (the default) uses the imaginary part of the
series admittance as the branch susceptance. A bus axis covers every bus in
table order; a branch axis covers the in-service, non self loop branches in
table order, with three winding transformer windings after the branches.
[`calc_dc_index_map`](@ref) names both axes. The admittance matrices below and
[`to_powerdata`](@ref) do not share the branch axis.

## Islands and DC sensitivity factors

[`network_islands`](@ref) partitions a balanced network into AC islands with
the library's own rule: buses joined by in-service branches, closed switches,
and in-service three winding transformer windings. HVDC lines do not join
islands, and a bus typed `"ISOLATED"` belongs to no island.

[`calc_ptdf`](@ref) and [`calc_lodf`](@ref) return the dense DC power
transfer and line outage distribution factors from the routine the Rust and
Python APIs call. The DC bus susceptance matrix is grounded at every
reference bus, one per island, so every reference bus column of the PTDF is
zero. Each result names its branch and bus axes and the reference set.

```julia
r = network_islands(net)
r[1].bus_ids, r[1].reference_bus_ids, r.isolated_bus_ids

H = calc_ptdf(net)                          # PtdfMatrix, branches by buses
H.matrix[1, H.bus_to_idx[2]]
H.reference_bus_ids
calc_ptdf(net; formula="tap_adjusted_reactance", solver=:sparse)
L = calc_lodf(net)                          # LodfMatrix, branches by branches
```

## Admittance matrices

[`calc_admittance_matrix`](@ref) assembles the complex bus admittance matrix
`Y = G + jB` in Julia from the element tables, following MATPOWER's `makeYbus`
as the powerio matrix crate implements it. For each in-service branch from bus
`i` to bus `j` with series impedance `z = r + jx`, terminal charging `y_fr` and
`y_to`, and complex tap `a = tap * exp(j * shift)`:

```text
Y[i,i] += (1/z + y_fr) / |a|^2
Y[j,j] += 1/z + y_to
Y[i,j] += -(1/z) / conj(a)
Y[j,i] += -(1/z) / a
```

plus the in-service bus shunts `Y[i,i] += (g_s + j b_s) / base_mva`. The result
is a [`BusMappedMatrix`](@ref) with `idx_to_bus`, `bus_to_idx`, and the sparse
`matrix`.

```julia
Y = calc_admittance_matrix(net)
Y.matrix[Y.bus_to_idx[4], Y.bus_to_idx[5]]
calc_admittance_matrix(net; include_taps=false)
calc_admittance_matrix("case9.m")          # parse, then assemble
```

[`calc_bprime_matrix`](@ref) and [`calc_bdoubleprime_matrix`](@ref) are the
fast decoupled `B'` and `B''` matrices. They use the same kernel, with
charging, taps, shifts, shunts, and series resistance switched on or off as
MATPOWER's `makeB` does, and the result negated. `scheme=:bx` (the default) or
`:xb` selects where the series resistance is dropped.

A branch whose impedance magnitude is below the divisibility threshold is an
error unless you pass `skip_zero_impedance=true`, which drops it.

```@docs
calc_dc_index_map
calc_incidence_matrix
calc_branch_susceptances
calc_bus_susceptance_matrix
calc_branch_flow_matrix
calc_branch_phase_shift_injection
calc_bus_phase_shift_injection
calc_branch_flow_dc
calc_bus_injection_dc
calc_admittance_matrix
calc_bprime_matrix
calc_bdoubleprime_matrix
calc_branch_admittances
BusMappedMatrix
network_islands
NetworkIslands
Island
calc_ptdf
calc_lodf
PtdfMatrix
LodfMatrix
```
