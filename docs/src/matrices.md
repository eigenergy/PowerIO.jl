# Matrices

PowerIO returns native Julia sparse matrices backed by Rust matrix construction.
Matrix builders are a core API, not a transmission guide footnote.

The PowerIO C ABI transports common power system matrix entries as Arrow COO
tables. Julia materializes those entries as `SparseMatrixCSC` values and stores
matrix metadata in wrappers that are familiar to PowerModels users.

The shipped matrix API supports [`BalancedNetwork`](@ref). Distribution system
matrices belong in this API family once Rust exposes distribution matrix
constructors.

## Usage
```julia
net = PowerIO.parse("case14.m"; value_type=BalancedNetwork)

ybus = calc_admittance_matrix(net)       # PowerIO.AdmittanceMatrix{ComplexF64}
Y = ybus.matrix

sm = calc_susceptance_matrix(net)     # NOTE: PowerModels sign convention
B = sm.matrix

A = calc_incidence_matrix(net).matrix # rows are buses, columns are branches
Bp = calc_bprime_matrix(net).matrix   # Rust B' positive Laplacian
Bpp = calc_bdoubleprime_matrix(net).matrix
```

## Structure

All five `calc_*` functions return `PowerIO.AdmittanceMatrix`, which carries:

- `idx_to_bus`: row index to external bus id.
- `bus_to_idx`: external bus id to row index.
- `matrix`: the sparse matrix.

The row and column index space is the dense matrix row index chosen by Rust.
Use `idx_to_bus` and `bus_to_idx` when you need to translate between matrix
rows and external bus ids.

`calc_incidence_matrix` is the one whose columns are branches rather than buses,
so only its rows go through the bus maps. It returns the same wrapper as the
other four so the maps travel with the matrix; the type name reads oddly for a
bus-by-branch matrix, and renaming it is a 1.0 question.

## Sign Convention

`calc_susceptance_matrix(net).matrix` follows the PowerModels sign convention.
Rust's `B'` keeps the positive Laplacian convention, so:

```julia
calc_susceptance_matrix(net).matrix == -calc_bprime_matrix(net).matrix
```

[`to_arrow`](@ref) remains available for lower level consumers that want COO
tables directly:

```julia
coo = to_arrow(net, :ybus)   # row_index, col_index, g, b
```
