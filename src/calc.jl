# The DC calculations the C library computes: `pio_calc_*` over a balanced
# network, converted from zero based CSR to 1-based `SparseMatrixCSC` and from
# owned double spans to `Vector{Float64}`.

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

function _calc_sparse(sym::Symbol, net::BalancedNetwork, formula::AbstractString)
    formula = String(formula)
    return _with_network(net) do lib, p
        ptr = _checked(lib) do err
            ccall(_library_symbol(lib, sym), Ptr{Cvoid},
                  (Ptr{Cvoid}, Ptr{UInt8}, Csize_t, Ref{Ptr{Cvoid}}), p, formula, sizeof(formula), err)
        end
        _take_sparse(lib, ptr)
    end
end

function _calc_vector(sym::Symbol, net::BalancedNetwork, formula::AbstractString)
    formula = String(formula)
    return _with_network(net) do lib, p
        ptr = _checked(lib) do err
            ccall(_library_symbol(lib, sym), Ptr{Cvoid},
                  (Ptr{Cvoid}, Ptr{UInt8}, Csize_t, Ref{Ptr{Cvoid}}), p, formula, sizeof(formula), err)
        end
        _take_vector(lib, ptr)
    end
end

function _calc_vector(sym::Symbol, net::BalancedNetwork, formula::AbstractString, angles::AbstractVector{<:Real})
    formula = String(formula)
    va = Vector{Float64}(angles)
    return _with_network(net) do lib, p
        ptr = GC.@preserve va _checked(lib) do err
            ccall(_library_symbol(lib, sym), Ptr{Cvoid},
                  (Ptr{Cvoid}, Ptr{UInt8}, Csize_t, Ptr{Float64}, Csize_t, Ref{Ptr{Cvoid}}),
                  p, formula, sizeof(formula), va, length(va), err)
        end
        _take_vector(lib, ptr)
    end
end

const _DC_FORMULA_DOC = """
`formula` selects the branch susceptance: `"series_susceptance"` (the
imaginary part of the series admittance, the default) or another formula the
library accepts. Row and column order follow the bus and branch tables;
indices are 1-based. The argument is a `BalancedNetwork` or a
`PioModule{BalancedNetwork}`."""

"""
    calc_incidence_matrix(net; formula="series_susceptance") -> SparseMatrixCSC

Branch by bus incidence matrix: `+1` at the from bus and `-1` at the to bus of
every in-service branch. $_DC_FORMULA_DOC
"""
calc_incidence_matrix(net; formula::AbstractString="series_susceptance") =
    _calc_sparse(:pio_calc_incidence_matrix, _network(net), formula)

"""
    calc_branch_susceptances(net; formula="series_susceptance") -> Vector{Float64}

One susceptance per in-service branch. $_DC_FORMULA_DOC
"""
calc_branch_susceptances(net; formula::AbstractString="series_susceptance") =
    _calc_vector(:pio_calc_branch_susceptances, _network(net), formula)

"""
    calc_bus_susceptance_matrix(net; formula="series_susceptance") -> SparseMatrixCSC

The DC bus susceptance matrix `A' * Diagonal(b) * A`. $_DC_FORMULA_DOC
"""
calc_bus_susceptance_matrix(net; formula::AbstractString="series_susceptance") =
    _calc_sparse(:pio_calc_bus_susceptance_matrix, _network(net), formula)

"""
    calc_branch_flow_matrix(net; formula="series_susceptance") -> SparseMatrixCSC

The branch flow matrix `Diagonal(b) * A`, mapping bus angles to branch flows.
$_DC_FORMULA_DOC
"""
calc_branch_flow_matrix(net; formula::AbstractString="series_susceptance") =
    _calc_sparse(:pio_calc_branch_flow_matrix, _network(net), formula)

"""
    calc_branch_phase_shift_injection(net; formula="series_susceptance") -> Vector{Float64}

The per branch injection caused by transformer phase shifts. $_DC_FORMULA_DOC
"""
calc_branch_phase_shift_injection(net; formula::AbstractString="series_susceptance") =
    _calc_vector(:pio_calc_branch_phase_shift_injection, _network(net), formula)

"""
    calc_bus_phase_shift_injection(net; formula="series_susceptance") -> Vector{Float64}

The per bus injection caused by transformer phase shifts. $_DC_FORMULA_DOC
"""
calc_bus_phase_shift_injection(net; formula::AbstractString="series_susceptance") =
    _calc_vector(:pio_calc_bus_phase_shift_injection, _network(net), formula)

"""
    calc_branch_flow_dc(net, voltage_angles; formula="series_susceptance") -> Vector{Float64}

DC branch flows in per unit for the given bus voltage angles in radians,
one per bus in table order. $_DC_FORMULA_DOC
"""
calc_branch_flow_dc(net, voltage_angles::AbstractVector{<:Real}; formula::AbstractString="series_susceptance") =
    _calc_vector(:pio_calc_branch_flow_dc, _network(net), formula, voltage_angles)

"""
    calc_bus_injection_dc(net, voltage_angles; formula="series_susceptance") -> Vector{Float64}

DC bus injections in per unit for the given bus voltage angles in radians.
$_DC_FORMULA_DOC
"""
calc_bus_injection_dc(net, voltage_angles::AbstractVector{<:Real}; formula::AbstractString="series_susceptance") =
    _calc_vector(:pio_calc_bus_injection_dc, _network(net), formula, voltage_angles)
