# The DC incidence parts over the C ABI (`pio_branch_susceptance` and its three
# siblings, powerio v0.9 `--features matrix`).
#
# The matrix surface returns assembled matrices. The per-branch and per-bus
# quantities they are assembled *from* did not cross the boundary: only the
# signed incidence `A` reached a caller, through `calc_incidence_matrix`.
#
# A differentiable-modeling consumer treats the susceptance as a parameter
# vector rather than an ingredient — its DC network is `(A, b, sw)` and its
# positive Laplacian is a function it rebuilds:
# `L = A * Diagonal(b .* sw) * A'`. The assembled matrix is the wrong
# granularity because it has already summed away the thing being
# differentiated. Computing `b` outside instead
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
    all(_exports_symbol, (:pio_incidence_parts, :pio_branch_susceptance,
                          :pio_phase_shift_injection,
                          :pio_incidence_branch_rows, :pio_incidence_skipped_rows))

# The tokens the C surface takes, which are the ones Python's `convention=` and
# the CLI's `--convention` take. Resolved here rather than passed through so a
# misspelling is a Julia-side error naming the options, not a C refusal.
#
# The mirror is of `DcConvention::from_token` (powerio/src/dc.rs), which owns
# the set. The keys are stored under the shared `_canonical_token_key`, which
# normalizes the way that owner does — both separators deleted rather than one
# folded into the other — so `"seriesimpedance"` and `"reactanceonly"` resolve
# here as they already do through Python and the CLI. Rewriting `-` to `_`
# instead refused three spellings the library accepts. The drift-canary test
# feeds every key back through the C ABI.
const _DC_CONVENTIONS = Dict("series" => "series",
                             "seriesimpedance" => "series",
                             "matpower" => "matpower",
                             "mp" => "matpower",
                             "reactanceonly" => "reactance-only")

# The 0.8 spellings of `b = 1/x`, which was also 0.8's default. Named rather
# than resolved, for the reason the core gives: the nearest-looking option,
# `:series`, is a different formula, so a caller who guesses gets numbers
# instead of an error.
const _DC_CONVENTION_RETIRED = ("paper", "paperpure", "pure")

function _dc_convention_token(convention)
    # Typed before converted: `nothing` is how this package spells "the
    # default" for `from=`, so `convention=nothing` is a plausible call, and
    # `String(nothing)` answered it with a `MethodError` naming Base rather
    # than the error naming the options this table exists to give.
    convention isa Union{Symbol,AbstractString} || throw(ArgumentError(
        "PowerIO: a DC convention is named by a Symbol or a String, got " *
        "$(repr(convention)); expected :series, :matpower or :reactance_only"))
    key = _canonical_token_key(convention)
    key in _DC_CONVENTION_RETIRED && throw(ArgumentError(
        "PowerIO: convention 'paper-pure' is now :reactance_only; it is no longer " *
        "the default, and :series is a different formula (b = x/(r^2 + x^2))"))
    token = get(_DC_CONVENTIONS, key, nothing)
    token === nothing && throw(ArgumentError(
        "PowerIO: unknown DC convention $(repr(convention)); expected " *
        ":series (b = x/(r^2 + x^2), the default), :matpower (b = 1/(x*tau)), " *
        "or :reactance_only (b = 1/x)"))
    return token
end

# One extractor call: write up to `cap` values into `out` and return the total
# the library has, whatever `cap` was. A negative return carries the guard's
# own `CODE: message` in the errbuf.
#
# `token` arrives resolved. The public entry points resolve once, so a
# misspelled convention is still refused before any handle work — which is the
# reason the table exists — without re-walking it for each vector.
#
# The library is the handle's, not `_lib()`. `set_library!` is public API for
# pointing at a locally built cdylib and can be called while a parsed network
# is still alive; the pointer inside that handle is an allocation of the build
# that parsed it, and handing it to another build's `pio_branch_susceptance` is
# a type confusion neither side catches, since `_ensure_compatible` only
# handshakes an integer version. Every other handle-taking ccall in this
# package already resolves through `getfield(h, :lib)` for the same reason the
# free function is memoized per path.
function _incidence_call(net::BalancedNetwork, fname::AbstractString, sym::Symbol,
                         ::Type{E}, token::AbstractString, out, cap::Integer) where {E}
    h = _live_handle(net, fname)
    lib = getfield(h, :lib)
    _ensure_compatible(lib)
    _require_export(fname, sym, "powerio v0.9, `--features matrix`", lib)
    err = zeros(UInt8, _ERRLEN)
    n = GC.@preserve h ccall(_library_symbol(lib, sym), Cptrdiff_t,
                             (Ptr{Cvoid}, Cstring, Ptr{E}, Csize_t, Ptr{UInt8}, Csize_t),
                             h.ptr, token, out, cap, err, length(err))
    n < 0 && error("PowerIO.$fname: " * _cstr(err))
    return Int(n)
end

# Size query, allocate, fill — for one standalone vector whose length nothing
# else knows. `calc_incidence_parts` uses the bulk extractor below instead.
function _incidence_fill(net::BalancedNetwork, fname::AbstractString, sym::Symbol,
                         ::Type{E}, token::AbstractString) where {E}
    n = _incidence_call(net, fname, sym, E, token, Ptr{E}(C_NULL), 0)
    out = Vector{E}(undef, n)
    got = _incidence_call(net, fname, sym, E, token, out, length(out))
    _check_filled(got, n, string(sym))
    return out
end

# Fill all four vectors from one Rust incidence build. The Arrow matrix gives
# exact capacities for the branch and bus vectors. The source branch count
# bounds skipped rows, including when `token` keeps a branch the Arrow table's
# fixed :series convention drops.
function _incidence_parts_fill(net::BalancedNetwork, token::AbstractString, m::Int, n::Int)
    h = _live_handle(net, "calc_incidence_parts")
    lib = getfield(h, :lib)
    _ensure_compatible(lib)
    _require_export("calc_incidence_parts", :pio_incidence_parts,
                    "powerio v0.9, `--features matrix`", lib)
    nb = Int(GC.@preserve h ccall(_library_symbol(lib, :pio_n_branches), Csize_t,
                                  (Ptr{Cvoid},), h.ptr))
    b = Vector{Float64}(undef, m)
    rows = Vector{Int64}(undef, m)
    p_shift = Vector{Float64}(undef, n)
    skipped = Vector{Int64}(undef, nb)
    out_m, out_n, out_skipped = Ref{Csize_t}(0), Ref{Csize_t}(0), Ref{Csize_t}(0)
    err = zeros(UInt8, _ERRLEN)
    status = GC.@preserve h ccall(
        _library_symbol(lib, :pio_incidence_parts), Cint,
        (Ptr{Cvoid}, Cstring, Ptr{Float64}, Ptr{Int64}, Csize_t,
         Ptr{Float64}, Csize_t, Ptr{Int64}, Csize_t,
         Ref{Csize_t}, Ref{Csize_t}, Ref{Csize_t}, Ptr{UInt8}, Csize_t),
        h.ptr, token, b, rows, m, p_shift, n, skipped, nb,
        out_m, out_n, out_skipped, err, length(err))
    status == 0 || error("PowerIO.calc_incidence_parts: " * _cstr(err))

    got_m, got_n, got_skipped = Int(out_m[]), Int(out_n[]), Int(out_skipped[])
    got_m == m || error(
        "PowerIO.calc_incidence_parts: the incidence matrix has $m columns and the C ABI " *
        "reported $got_m; they no longer describe the same DC network")
    got_n == n || error(
        "PowerIO.calc_incidence_parts: the incidence matrix has $n rows and the C ABI " *
        "reported $got_n; they no longer describe the same DC network")
    got_skipped <= nb || error(
        "PowerIO.calc_incidence_parts: the case has $nb branches and the C ABI reports " *
        "$got_skipped skipped rows; they no longer describe the same DC network")
    resize!(skipped, got_skipped)
    return b, p_shift, rows, skipped
end

# Rust rows are 0-based; every row number this package reports is 1-based.
function _incidence_rows(v::Vector{Int64})
    if Int === Int64
        for i in eachindex(v)
            v[i] == typemax(Int64) && error("PowerIO: incidence row does not fit in Int")
            v[i] += 1
        end
        return v
    end
    return Int[Int(x) + 1 for x in v]
end

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
                    Float64, _dc_convention_token(convention))

branch_susceptance(path::AbstractString; from=nothing, convention=:series) =
    _matrix_from_path(net -> branch_susceptance(net; convention=convention),
                      path, "branch_susceptance"; from=from)

# The matrix `calc_incidence_parts` is assembled around, with the two guards
# that belong to it alone. Split out so `calc_incidence_parts` reads as the
# spine it is: token, matrix, shape, fills.
#
# The `arrow` feature is required here rather than left to the `try` below. A
# library built `--features matrix` without it — the build `branch_susceptance`
# documents as enough, so a plausible one to be holding — fails inside
# `calc_incidence_matrix` with the toolchain message that names the missing
# feature, and under a non-default convention the rewrite below would bury that
# under a claim about the case's data which is not true of it. Asked through
# the handle's own library, as every other resolution in this file is.
function _incidence_matrix_for_parts(net::BalancedNetwork, convention,
                                     token::AbstractString)
    h = _live_handle(net, "calc_incidence_parts")
    lib = getfield(h, :lib)
    _ensure_compatible(lib)
    _require_export("calc_incidence_parts", :pio_to_arrow,
                    "powerio v0.9, `--features matrix,arrow`", lib)
    return try
        calc_incidence_matrix(net)
    catch err
        # The Arrow incidence table takes no convention over the C ABI; it is
        # always the default `:series`, which is the strictest of the three
        # because it is the only one that reads the resistance. A branch whose
        # `r` is nonfinite and whose `x` is fine therefore computes under the
        # requested convention and is refused here, and the `to_arrow` message
        # names neither this function nor the convention that did the refusing.
        #
        # Only report that mismatch once it is one. A case that is corrupt
        # under every convention would otherwise be blamed on the default and
        # send its caller looking for a convention that carries it, so ask the
        # requested one and let its own refusal — which names the branch —
        # stand. A size query with a null buffer is that ask: on the C side it
        # is the same full incidence build the filling call would run, and it
        # raises the same guard, so nothing is allocated to be discarded.
        # This runs on the error path alone.
        token == "series" && rethrow()
        _incidence_call(net, "calc_incidence_parts", :pio_branch_susceptance,
                        Float64, token, Ptr{Float64}(C_NULL), 0)
        error("PowerIO.calc_incidence_parts: `matrix` is the library's Arrow " *
              "incidence table, which it builds under the default :series " *
              "convention whatever `convention` asks for, and :series refuses " *
              "this case where :$(convention) carries it: " *
              sprint(showerror, err) *
              ". `branch_susceptance` returns the vector alone.")
    end
end

"""
    calc_incidence_parts(net::BalancedNetwork; convention=:series) -> NamedTuple
    calc_incidence_parts(path; from=nothing, convention=:series) -> NamedTuple

The DC network as the parts it is assembled from, under one `convention`:

- `matrix` — the signed incidence `A`, exactly what [`calc_incidence_matrix`](@ref)
  returns, so the bus id maps travel with it. Its columns and signs do not
  depend on `convention`, but the C ABI takes no convention on the Arrow table
  it crosses as: the library builds it under the default `:series`, so a case
  only another convention can carry — a nonfinite `r` beside a usable `x` — has
  no matrix here, and [`branch_susceptance`](@ref) is the way to the vector
  alone;
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
    # The matrix first because it owns the shape. One bulk C call then fills
    # every vector from one matching incidence build.
    matrix = _incidence_matrix_for_parts(net, convention, token)
    m = size(matrix.matrix, 2)
    n = length(matrix.idx_to_bus)
    b, p_shift, rows, skipped = _incidence_parts_fill(net, token, m, n)
    rows = _incidence_rows(rows)
    skipped = _incidence_rows(skipped)
    return (; matrix, b, p_shift, branch_rows = rows,
            skipped_zero_impedance = skipped, convention = token)
end

calc_incidence_parts(path::AbstractString; from=nothing, convention=:series) =
    _matrix_from_path(net -> calc_incidence_parts(net; convention=convention),
                      path, "calc_incidence_parts"; from=from)
