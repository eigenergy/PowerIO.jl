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
net = parse_file("case14.m")

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

## The DC parts, not only the assembled matrix

The `calc_*` functions above return matrices that are already assembled. A
consumer differentiating a DC OPF solution treats the per-branch susceptance as
a *parameter vector* rather than an ingredient — its DC network is `(A, b, sw)`
and its susceptance matrix is a function it rebuilds,
`B = A' * Diagonal(-b .* sw) * A` — so an assembled `B'` is the wrong
granularity: it has already summed away the thing being differentiated.

[`calc_incidence_parts`](@ref) returns the parts instead:

```julia
parts = calc_incidence_parts(net; convention=:series)
parts.matrix                  # the signed incidence, as calc_incidence_matrix returns
parts.b                       # per-branch susceptance, a positive Laplacian weight
parts.p_shift                 # phase shift bus injection, in matrix row order
parts.branch_rows             # 1-based column to source branch row
parts.skipped_zero_impedance  # 1-based rows the DC denominator guard dropped

A = parts.matrix.matrix
A * spdiagm(0 => parts.b) * A' == calc_bprime_matrix(net).matrix   # exactly
```

[`branch_susceptance`](@ref) returns the vector alone, and needs a library built
`--features matrix` without `arrow`.

Ask for `b` rather than computing it. The formula is
`x / (r² + x²)` under `:series`, and reproducing it outside inherits none of the
guards powerio 0.9 put on this path: the denominator is bounded on magnitude
rather than compared against a fixed constant, a nonfinite susceptance raises
naming the branch instead of joining the Laplacian as a zero weight edge, and a
`:matpower` tap too small to divide by is refused. `convention` is `:series`
(the default, reading the whole series impedance), `:matpower` (`b = 1/(x τ)`),
or `:reactance_only` (`b = 1/x`, the textbook linearization a published result
needs written exactly that way) — a token you name rather than a formula you
write.

`skipped_zero_impedance` and `branch_rows` travel with the vectors because a
consumer rebuilding `B` from `A` and `b` needs to know which branches the
builder dropped, or its matrix and the library's disagree with nothing to say
why.

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
