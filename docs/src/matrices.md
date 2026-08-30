# Matrices

PowerIO constructs sparse matrices in Rust and returns Julia
`SparseMatrixCSC` values.

The PowerIO C ABI transports common power system matrix entries as Arrow COO
tables. Julia keeps each sparse matrix with its bus row mapping in a
[`BusMappedMatrix`](@ref).

The shipped matrix API supports [`BalancedNetwork`](@ref). Distribution system
matrices belong in this API family once Rust exposes distribution matrix
constructors.

## Rust matrix builders
```julia
case = parse_file("case14.m")

ybus = calc_admittance_matrix(case)      # BusMappedMatrix{ComplexF64}
Y = ybus.matrix

sm = calc_susceptance_matrix(case)     # fast decoupled B' with PowerModels sign
B = sm.matrix

# The released 0.10 network overload retains its old bus by branch result.
A_compat = calc_incidence_matrix(case.value).matrix
Bp = calc_bprime_matrix(case).matrix   # Rust B' positive Laplacian
Bpp = calc_bdoubleprime_matrix(case).matrix
```

## Structure

The matrix feature functions in this section return `BusMappedMatrix`, which
carries:

- `idx_to_bus`: row index to external bus id.
- `bus_to_idx`: external bus id to row index.
- `matrix`: the sparse matrix.

The row and column index space is the dense matrix row index chosen by Rust.
Use `idx_to_bus` and `bus_to_idx` when you need to translate between matrix
rows and external bus ids.

The released `calc_incidence_matrix(::BalancedNetwork)` overload has branch
columns rather than bus columns, so only its rows use the bus maps. This is a
0.10 compatibility result. The ordinary module overload below returns the
PowerModels branch by bus matrix directly; 1.0 reconciles the old network and
path overloads to that orientation.

## Sign Convention

`calc_susceptance_matrix(net).matrix` follows the PowerModels sign convention.
Rust's `B'` keeps the positive Laplacian convention, so:

```julia
calc_susceptance_matrix(case).matrix == -calc_bprime_matrix(case).matrix
```

This fast decoupled matrix is not the canonical DC power flow bus
susceptance matrix. Use the direct module methods for that contract:

```julia
A  = calc_incidence_matrix(case)             # branches by buses
B  = calc_bus_susceptance_matrix(case)       # A' * Diagonal(b) * A
Bf = calc_branch_susceptance_matrix(case)    # Diagonal(b) * A
p_shift = calc_phase_shift_injection(case)   # A' * (b .* shift)
f = calc_branch_flow_dc(case, voltage_angles)
p = A' * f                              # bus injections
```

`B` stays symmetric when phase shifters are present. Their angle contribution
is returned separately by `calc_phase_shift_injection` and included by
`calc_branch_flow_dc`.
The three calculations whose result has a branch axis refuse a network when
the DC preparation omitted a branch, because a shortened bare matrix or vector
would lose its row mapping. Inspect `dc_data(case)` for the omitted branch IDs
and reasons. The bus matrix and phase shift injection remain available because
their bus axis is complete.
`to_dense(case).bus_ids` maps the matrix bus order to source bus identifiers.
The raw DC spans and their 0.10 compatibility names are listed in the
[migration guide](migration-0.10.md).

[`to_arrow`](@ref) remains available for lower level consumers that want COO
tables directly:

```julia
coo = to_arrow(case, :ybus)   # row_index, col_index, g, b
```
