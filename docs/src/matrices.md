# Matrices

PowerIO constructs sparse matrices in Rust and returns Julia
`SparseMatrixCSC` values.

The PowerIO C ABI transports common power system matrix entries as Arrow COO
tables. Julia keeps each sparse matrix with its bus row mapping in a
[`BusMappedMatrix`](@ref).

The shipped matrix API supports [`BalancedNetwork`](@ref). Distribution system
matrices belong in this API family once Rust exposes distribution matrix
constructors.

## Usage
```julia
net = parse_file("case14.m").value

ybus = calc_admittance_matrix(net)       # BusMappedMatrix{ComplexF64}
Y = ybus.matrix

sm = calc_susceptance_matrix(net)     # NOTE: PowerModels sign convention
B = sm.matrix

A = calc_incidence_matrix(net).matrix # rows are buses, columns are branches
Bp = calc_bprime_matrix(net).matrix   # Rust B' positive Laplacian
Bpp = calc_bdoubleprime_matrix(net).matrix
```

## Structure

All five `calc_*` functions return `BusMappedMatrix`, which carries:

- `idx_to_bus`: row index to external bus id.
- `bus_to_idx`: external bus id to row index.
- `matrix`: the sparse matrix.

The row and column index space is the dense matrix row index chosen by Rust.
Use `idx_to_bus` and `bus_to_idx` when you need to translate between matrix
rows and external bus ids.

`calc_incidence_matrix` has branch columns rather than bus columns, so only its
rows use the bus maps.

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
