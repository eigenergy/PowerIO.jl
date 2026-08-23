# The DC incidence parts over the C ABI (`pio_branch_susceptance` and its three
# siblings, powerio v0.9 `--features matrix`).
#
# The matrix surface returns assembled matrices. The per-branch and per-bus
# quantities they are assembled *from* did not cross the boundary: only the
# signed incidence `A` reached a caller, through `calc_incidence_matrix`.
#
# A differentiable-modeling consumer treats the susceptance as a parameter
# vector rather than an ingredient — its DC network is `(A, b, sw)` and its
# susceptance matrix is a function it rebuilds, `B = A' * Diagonal(-b .* sw) *
# A` — so the assembled matrix is the wrong granularity: it has already summed
# away the thing being differentiated. Computing `b` outside instead
# reimplements a formula powerio 0.9 hardened (#292) and inherits none of the
# guards: the magnitude bound on the denominator, `NonFiniteSusceptance`
# instead of a silently dropped edge, `DegenerateTap` under `:matpower`. These
# carry the vectors and the guards together, and the convention becomes a
# choice a caller names rather than a formula it writes.

"""
    incidence_parts_available() -> Bool

True if the resolved C library exports the DC incidence part extractors
(powerio v0.9, `--features matrix`). [`calc_incidence_parts`](@ref) also needs
the `arrow` feature for the matrix itself; [`branch_susceptance`](@ref) does
not.
"""
incidence_parts_available() =
    all(_exports_symbol, (:pio_branch_susceptance, :pio_phase_shift_injection,
                          :pio_incidence_branch_rows, :pio_incidence_skipped_rows))

# The tokens the C surface takes, which are the ones Python's `convention=` and
# the CLI's `--convention` take. Resolved here rather than passed through so a
# misspelling is a Julia-side error naming the options, not a C refusal.
const _DC_CONVENTIONS = (
    series = "series",
    series_impedance = "series",
    matpower = "matpower",
    mp = "matpower",
    reactance_only = "reactance-only",
)

function _dc_convention_token(convention)
    key = Symbol(replace(lowercase(String(convention)), '-' => '_'))
    token = get(_DC_CONVENTIONS, key, nothing)
    token === nothing && throw(ArgumentError(
        "PowerIO: unknown DC convention $(repr(convention)); expected " *
        ":series (b = x/(r^2 + x^2), the default), :matpower (b = 1/(x*tau)), " *
        "or :reactance_only (b = 1/x)"))
    return token
end

# The four extractors share one shape: size query, allocate, fill, and a
# negative return carrying the guard's own `CODE: message` in the errbuf.
function _incidence_fill(net::BalancedNetwork, fname::AbstractString, sym::Symbol,
                         ::Type{E}, convention) where {E}
    lib = _lib()
    _ensure_compatible(lib)
    _require_export(fname, sym, "powerio v0.9, `--features matrix`", lib)
    token = _dc_convention_token(convention)
    h = _live_handle(net, fname)
    err = zeros(UInt8, _ERRLEN)
    n = GC.@preserve h ccall(_library_symbol(lib, sym), Cptrdiff_t,
                             (Ptr{Cvoid}, Cstring, Ptr{E}, Csize_t, Ptr{UInt8}, Csize_t),
                             h.ptr, token, Ptr{E}(C_NULL), 0, err, length(err))
    n < 0 && error("PowerIO.$fname: " * _cstr(err))
    out = Vector{E}(undef, Int(n))
    got = GC.@preserve h ccall(_library_symbol(lib, sym), Cptrdiff_t,
                               (Ptr{Cvoid}, Cstring, Ptr{E}, Csize_t, Ptr{UInt8}, Csize_t),
                               h.ptr, token, out, length(out), err, length(err))
    got < 0 && error("PowerIO.$fname: " * _cstr(err))
    got == n || error("PowerIO.$fname: the C ABI reported $n then filled $got")
    return out
end

# Rust rows are 0-based; every row number this package reports is 1-based.
_incidence_rows(v::Vector{Int64}) = Int[Int(x) + 1 for x in v]

"""
    branch_susceptance(net::BalancedNetwork; convention=:series) -> Vector{Float64}
    branch_susceptance(path; from=nothing, convention=:series) -> Vector{Float64}

The per-branch DC susceptance `b`, in incidence column order.

`convention` is `:series` (`b = x/(r² + x²)`, powerio 0.9's default, which
reads the whole series impedance), `:matpower` (`b = 1/(x τ)`), or
`:reactance_only` (`b = 1/x`, the textbook DC linearization a published result
needs written exactly that way).

`b` is a **positive** Laplacian edge weight, which is what powerio's
`branch_susceptance` returns; PowerModels and tellegen write the negation, so a
consumer negates once knowingly rather than guessing.

This is the one number a DC consumer cannot get from the matrix surface: the
assembled `B'` has already summed it away. Computing it instead reimplements a
formula the library hardened, and inherits none of its guards — a nonfinite
susceptance raises here, naming the branch, rather than joining the Laplacian
as a zero weight edge.

Column order is [`calc_incidence_parts`](@ref)'s `branch_rows`, which is
in-service branch order with self-loops and the rows the DC denominator guard
skipped removed. It is not the `branches(net)` order and `length(b)` is not the
branch count; read `branch_rows` to line the vector up with the case.

Needs a library built `--features matrix`; the `arrow` feature is not required
here, only for [`calc_incidence_parts`](@ref)'s matrix.
"""
branch_susceptance(net::BalancedNetwork; convention=:series) =
    _incidence_fill(net, "branch_susceptance", :pio_branch_susceptance,
                    Float64, convention)

branch_susceptance(path::AbstractString; from=nothing, convention=:series) =
    _matrix_from_path(net -> branch_susceptance(net; convention=convention),
                      path, "branch_susceptance"; from=from)

"""
    calc_incidence_parts(net::BalancedNetwork; convention=:series) -> NamedTuple
    calc_incidence_parts(path; from=nothing, convention=:series) -> NamedTuple

The DC network as the parts it is assembled from, under one `convention`:

- `matrix` — the signed incidence `A`, exactly what [`calc_incidence_matrix`](@ref)
  returns, so the bus id maps travel with it;
- `b` — the per-branch susceptance, length `m`, a positive Laplacian weight
  (see [`branch_susceptance`](@ref));
- `p_shift` — the phase shift bus injection, length `n`, in the `matrix` row
  order. All zeros under `:reactance_only`, which carries no shifts, and for a
  case with no phase shifter. This is MATPOWER `makeBdc`'s `Pbusinj`, the
  constant term of `L θ = C_g p_g − (p_d + g_s + p_shift)`; a caller that skips
  it drops the shifter's contribution silently;
- `branch_rows` — the 1-based source branch row of each column, the map from a
  position in `b` back to the case's branch table;
- `skipped_zero_impedance` — the 1-based rows of the in-service branches the DC
  denominator guard dropped. They are in the case and in no column, so a
  consumer rebuilding `B` from `A` and `b` needs them or its matrix and the
  library's disagree with nothing to say why;
- `convention` — the token that produced all of the above.

```julia
parts = calc_incidence_parts(net)
B = parts.matrix.matrix * Diagonal(parts.b) * parts.matrix.matrix'   # positive Laplacian
```

Needs a library built with both `matrix` and `arrow`: the matrix crosses as an
Arrow table. [`branch_susceptance`](@ref) alone needs only `matrix`.
"""
function calc_incidence_parts(net::BalancedNetwork; convention=:series)
    token = _dc_convention_token(convention)
    b = _incidence_fill(net, "calc_incidence_parts", :pio_branch_susceptance,
                        Float64, convention)
    p_shift = _incidence_fill(net, "calc_incidence_parts", :pio_phase_shift_injection,
                              Float64, convention)
    rows = _incidence_rows(_incidence_fill(net, "calc_incidence_parts",
                                           :pio_incidence_branch_rows, Int64, convention))
    skipped = _incidence_rows(_incidence_fill(net, "calc_incidence_parts",
                                              :pio_incidence_skipped_rows, Int64, convention))
    matrix = calc_incidence_matrix(net)
    # The Arrow incidence table is built under the default convention. The
    # column set does not depend on the convention -- the guard that drops a
    # column reads the reactance alone -- so the two agree, and if a future
    # release makes them disagree a caller must not find out by indexing.
    size(matrix.matrix, 2) == length(b) || error(
        "PowerIO.calc_incidence_parts: the incidence matrix has " *
        "$(size(matrix.matrix, 2)) columns and the susceptance vector has " *
        "$(length(b)); they no longer describe the same DC network")
    length(rows) == length(b) || error(
        "PowerIO.calc_incidence_parts: the column map has $(length(rows)) " *
        "entries for $(length(b)) columns")
    return (; matrix, b, p_shift, branch_rows = rows,
            skipped_zero_impedance = skipped, convention = token)
end

calc_incidence_parts(path::AbstractString; from=nothing, convention=:series) =
    _matrix_from_path(net -> calc_incidence_parts(net; convention=convention),
                      path, "calc_incidence_parts"; from=from)
