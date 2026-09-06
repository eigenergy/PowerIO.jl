# The DC calculations the C library computes: one `PioDcOperators` build over a
# balanced network serves every calculation, converted from zero based CSR to
# 1-based `SparseMatrixCSC` and from owned double spans to `Vector{Float64}`.

# Copy an owned CSR matrix into a `SparseMatrixCSC` and release it.
function _take_sparse(lib::AbstractString, ptr::Ptr{Cvoid})
    h = SparseMatrixHandle(ptr, lib)
    A = GC.@preserve h begin
        p = _ptr(h)
        rows = Int(ccall(_library_symbol(lib, :pio_sparse_matrix_rows), Csize_t, (Ptr{Cvoid},), p))
        cols = Int(ccall(_library_symbol(lib, :pio_sparse_matrix_columns), Csize_t, (Ptr{Cvoid},), p))
        offsets = _sizes(ccall(_library_symbol(lib, :pio_sparse_matrix_row_offsets), PioSizeView, (Ptr{Cvoid},), p))
        columns = _sizes(ccall(_library_symbol(lib, :pio_sparse_matrix_column_indices), PioSizeView, (Ptr{Cvoid},), p))
        values = _f64s(ccall(_library_symbol(lib, :pio_sparse_matrix_values), PioF64View, (Ptr{Cvoid},), p))
        I = Vector{Int}(undef, length(values))
        for r in 1:rows, k in offsets[r]+1:offsets[r+1]
            I[k] = r
        end
        SparseArrays.sparse(I, columns .+ 1, values, rows, cols)
    end
    release!(h)
    return A
end

_network(net::BalancedNetwork) = net
_network(m::PioModule{BalancedNetwork}) = m.value

# Build the operators once. The handle owns the bus and branch axes every
# calculation below shares.
function _dc_operators(net::BalancedNetwork, formula::AbstractString, skip_zero_impedance::Bool)
    formula = String(formula)
    return _with_network(net) do lib, p
        ptr = _checked(lib) do err
            ccall(_library_symbol(lib, :pio_calc_dc_operators), Ptr{Cvoid},
                  (Ptr{Cvoid}, Ptr{UInt8}, Csize_t, Bool, Ref{Ptr{Cvoid}}),
                  p, formula, sizeof(formula), skip_zero_impedance, err)
        end
        DcOperatorsHandle(ptr, lib)
    end
end

function _operators_sparse(sym::Symbol, net::BalancedNetwork, formula::AbstractString, skip::Bool)
    h = _dc_operators(net, formula, skip)
    lib = getfield(h, :lib)
    ptr = GC.@preserve h _checked(lib) do err
        ccall(_library_symbol(lib, sym), Ptr{Cvoid}, (Ptr{Cvoid}, Ref{Ptr{Cvoid}}), _ptr(h), err)
    end
    A = _take_sparse(lib, ptr)
    release!(h)
    return A
end

function _operators_vector(sym::Symbol, net::BalancedNetwork, formula::AbstractString, skip::Bool)
    h = _dc_operators(net, formula, skip)
    lib = getfield(h, :lib)
    ptr = GC.@preserve h _checked(lib) do err
        ccall(_library_symbol(lib, sym), Ptr{Cvoid}, (Ptr{Cvoid}, Ref{Ptr{Cvoid}}), _ptr(h), err)
    end
    values = _take_vector(lib, ptr)
    release!(h)
    return values
end

function _operators_vector(sym::Symbol, net::BalancedNetwork, formula::AbstractString, skip::Bool,
                           angles::AbstractVector{<:Real})
    va = Vector{Float64}(angles)
    h = _dc_operators(net, formula, skip)
    lib = getfield(h, :lib)
    ptr = GC.@preserve h va _checked(lib) do err
        ccall(_library_symbol(lib, sym), Ptr{Cvoid},
              (Ptr{Cvoid}, Ptr{Float64}, Csize_t, Ref{Ptr{Cvoid}}), _ptr(h), va, length(va), err)
    end
    values = _take_vector(lib, ptr)
    release!(h)
    return values
end

const _DC_FORMULA_DOC = """
`formula` selects the branch susceptance: `"series_susceptance"` (the
imaginary part of the series admittance, the default),
`"tap_adjusted_reactance"`, or `"reactance_only"`. Rows and columns are
1-based. A bus axis covers every bus in table order; a branch axis covers the
in-service, non self loop branches in table order, with three winding
transformer windings after the branches. [`calc_dc_index_map`](@ref) names
both axes. A zero impedance branch is a `PowerIOError` with code
`BUILD.OPERATOR.ZERO_IMPEDANCE` unless `skip_zero_impedance=true` drops it
from the branch axis. The argument is a `BalancedNetwork` or a
`PioModule{BalancedNetwork}`."""

"""
    calc_dc_index_map(net; formula="series_susceptance", skip_zero_impedance=false)

The axes every DC calculation shares, as a named tuple:

- `idx_to_bus[k]`: the source bus id of bus row or column `k`, every bus in
  table order;
- `bus_to_idx[id]`: the row of bus `id`;
- `idx_to_branch[k]`: the 1-based position in `net.branches` of branch row
  `k` (three winding transformer windings follow the branches), in-service
  non self loop branches only;
- `branch_ids[k]`: the stable identity of branch row `k`, the branch uid when
  the source states one and `"branches:<row>"` otherwise (`row` zero based);
- `skipped_branch_rows`: the 1-based positions of the zero impedance branches
  dropped under `skip_zero_impedance=true`, empty otherwise.

The same selection applies to the `c1..c8` rows of [`to_powerdata`](@ref)
after its own `status` filter. $_DC_FORMULA_DOC
"""
function calc_dc_index_map(net; formula::AbstractString="series_susceptance",
                           skip_zero_impedance::Bool=false)
    net = _network(net)
    h = _dc_operators(net, formula, skip_zero_impedance)
    lib = getfield(h, :lib)
    result = GC.@preserve h begin
        p = _ptr(h)
        idx_to_bus = _sizes(ccall(_library_symbol(lib, :pio_dc_operators_bus_ids), PioSizeView, (Ptr{Cvoid},), p))
        rows = _sizes(ccall(_library_symbol(lib, :pio_dc_operators_branch_rows), PioSizeView, (Ptr{Cvoid},), p))
        skipped = _sizes(ccall(_library_symbol(lib, :pio_dc_operators_skipped_branch_rows), PioSizeView, (Ptr{Cvoid},), p))
        n = Int(ccall(_library_symbol(lib, :pio_dc_operators_n_branches), Csize_t, (Ptr{Cvoid},), p))
        branch_ids = [_str(ccall(_library_symbol(lib, :pio_dc_operators_branch_identity), PioStringView,
                                 (Ptr{Cvoid}, Csize_t), p, Csize_t(k - 1))) for k in 1:n]
        (; idx_to_bus, bus_to_idx = Dict(id => k for (k, id) in enumerate(idx_to_bus)),
           idx_to_branch = rows .+ 1, branch_ids, skipped_branch_rows = skipped .+ 1)
    end
    release!(h)
    return result
end

"""
    calc_incidence_matrix(net; formula="series_susceptance", skip_zero_impedance=false) -> SparseMatrixCSC

Branch by bus incidence matrix: `+1` at the from bus and `-1` at the to bus of
every branch on the branch axis. $_DC_FORMULA_DOC
"""
calc_incidence_matrix(net; formula::AbstractString="series_susceptance", skip_zero_impedance::Bool=false) =
    _operators_sparse(:pio_dc_operators_incidence_matrix, _network(net), formula, skip_zero_impedance)

"""
    calc_branch_susceptances(net; formula="series_susceptance", skip_zero_impedance=false) -> Vector{Float64}

One susceptance per branch on the branch axis. $_DC_FORMULA_DOC
"""
calc_branch_susceptances(net; formula::AbstractString="series_susceptance", skip_zero_impedance::Bool=false) =
    _operators_vector(:pio_dc_operators_branch_susceptances, _network(net), formula, skip_zero_impedance)

"""
    calc_bus_susceptance_matrix(net; formula="series_susceptance", skip_zero_impedance=false) -> SparseMatrixCSC

The DC bus susceptance matrix `A' * Diagonal(b) * A`, buses by buses. $_DC_FORMULA_DOC
"""
calc_bus_susceptance_matrix(net; formula::AbstractString="series_susceptance", skip_zero_impedance::Bool=false) =
    _operators_sparse(:pio_dc_operators_bus_susceptance_matrix, _network(net), formula, skip_zero_impedance)

"""
    calc_branch_flow_matrix(net; formula="series_susceptance", skip_zero_impedance=false) -> SparseMatrixCSC

The branch flow matrix `Diagonal(b) * A`, branches by buses, mapping bus
angles to branch flows. $_DC_FORMULA_DOC
"""
calc_branch_flow_matrix(net; formula::AbstractString="series_susceptance", skip_zero_impedance::Bool=false) =
    _operators_sparse(:pio_dc_operators_branch_flow_matrix, _network(net), formula, skip_zero_impedance)

"""
    calc_branch_phase_shift_injection(net; formula="series_susceptance", skip_zero_impedance=false) -> Vector{Float64}

The per branch injection caused by transformer phase shifts, over the branch
axis. $_DC_FORMULA_DOC
"""
calc_branch_phase_shift_injection(net; formula::AbstractString="series_susceptance", skip_zero_impedance::Bool=false) =
    _operators_vector(:pio_dc_operators_branch_phase_shift_injection, _network(net), formula, skip_zero_impedance)

"""
    calc_bus_phase_shift_injection(net; formula="series_susceptance", skip_zero_impedance=false) -> Vector{Float64}

The per bus injection caused by transformer phase shifts, over the bus axis.
$_DC_FORMULA_DOC
"""
calc_bus_phase_shift_injection(net; formula::AbstractString="series_susceptance", skip_zero_impedance::Bool=false) =
    _operators_vector(:pio_dc_operators_bus_phase_shift_injection, _network(net), formula, skip_zero_impedance)

"""
    calc_branch_flow_dc(net, voltage_angles; formula="series_susceptance", skip_zero_impedance=false) -> Vector{Float64}

DC branch flows in per unit over the branch axis for the given bus voltage
angles in radians, one per bus on the bus axis. $_DC_FORMULA_DOC
"""
calc_branch_flow_dc(net, voltage_angles::AbstractVector{<:Real}; formula::AbstractString="series_susceptance",
                    skip_zero_impedance::Bool=false) =
    _operators_vector(:pio_dc_operators_branch_flow_dc, _network(net), formula, skip_zero_impedance, voltage_angles)

"""
    calc_bus_injection_dc(net, voltage_angles; formula="series_susceptance", skip_zero_impedance=false) -> Vector{Float64}

DC bus injections in per unit over the bus axis for the given bus voltage
angles in radians. $_DC_FORMULA_DOC
"""
calc_bus_injection_dc(net, voltage_angles::AbstractVector{<:Real}; formula::AbstractString="series_susceptance",
                      skip_zero_impedance::Bool=false) =
    _operators_vector(:pio_dc_operators_bus_injection_dc, _network(net), formula, skip_zero_impedance, voltage_angles)
