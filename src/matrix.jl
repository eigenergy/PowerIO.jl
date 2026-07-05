# Sparse matrix helpers over the Rust matrix surface. The C ABI transports
# matrix entries as Arrow COO tables; this file turns them into Julia sparse
# matrices and PowerModels shaped wrappers.

"""
    PowerIO.AdmittanceMatrix{T}

Sparse bus matrix plus the bus id mapping used by the matrix rows and columns.
The shape matches PowerModels' `AdmittanceMatrix`: `idx_to_bus[i]` is the
external bus id at sparse row `i`, `bus_to_idx[id]` is the row for a bus id,
and `matrix` holds the sparse values.
"""
struct AdmittanceMatrix{T}
    idx_to_bus::Vector{Int}
    bus_to_idx::Dict{Int,Int}
    matrix::SparseArrays.SparseMatrixCSC{T,Int}
end

Base.show(io::IO, x::AdmittanceMatrix{<:Number}) =
    print(io, "AdmittanceMatrix(", length(x.idx_to_bus), " buses, ",
          SparseArrays.nnz(x.matrix), " entries)")

function _matrix_from_path(f, path::AbstractString, fname::AbstractString; from=nothing)
    net = parse_file(path; from=from)
    net isa BalancedNetwork ||
        error("PowerIO.$fname: matrix APIs currently support balanced networks only")
    try
        return f(net)
    finally
        h = getfield(net, :handle)
        h === nothing || h.ptr == C_NULL || finalize(h)
    end
end

function _bus_maps_from_ids(ids::AbstractVector{<:Integer})
    n = length(ids)
    idx_to_bus = Vector{Int}(undef, n)
    for i in eachindex(ids)
        idx_to_bus[i] = Int(ids[i])
    end
    bus_to_idx = Dict{Int,Int}()
    sizehint!(bus_to_idx, n)
    for (idx, id) in enumerate(idx_to_bus)
        bus_to_idx[id] = idx
    end
    return idx_to_bus, bus_to_idx
end

function _matrix_bus_maps_from_arrow(h::BalancedNetworkHandle)
    axis = _arrow_from_handle(h, :matrix_bus, true)
    n = length(axis.index)
    idx_to_bus = Vector{Int}(undef, n)
    seen = falses(n)
    for k in eachindex(axis.index)
        idx = Int(axis.index[k]) + 1
        (1 <= idx <= n) || error("PowerIO matrix: matrix bus index $(axis.index[k]) is out of range")
        seen[idx] && error("PowerIO matrix: duplicate matrix bus index $(axis.index[k])")
        idx_to_bus[idx] = Int(axis.bus_id[k])
        seen[idx] = true
    end
    all(seen) || error("PowerIO matrix: matrix bus table is missing an index")
    return _bus_maps_from_ids(idx_to_bus)
end

function _matrix_bus_maps(h::BalancedNetworkHandle, matrix_n::Integer)
    count = Int(GC.@preserve h ccall(_library_symbol(getfield(h, :lib), :pio_n_buses),
                                     Csize_t, (Ptr{Cvoid},), h.ptr))
    count == Int(matrix_n) && return _bus_maps_from_ids(_handle_bus_ids(h, count))
    return _matrix_bus_maps_from_arrow(h)
end

_matrix_bus_maps(net::BalancedNetwork) =
    _matrix_bus_maps_from_arrow(_live_handle(net, "matrix_bus"))

function _check_matrix_axes(coo, table::Symbol, row_axis::AbstractString, col_axis::AbstractString)
    getproperty(coo, :row_axis) == row_axis ||
        error("PowerIO.$table: expected row axis $row_axis, got $(getproperty(coo, :row_axis))")
    getproperty(coo, :col_axis) == col_axis ||
        error("PowerIO.$table: expected col axis $col_axis, got $(getproperty(coo, :col_axis))")
    return
end

function _sparse_from_owned_coo!(coo, values)
    rows = getproperty(coo, :row_index)
    cols = getproperty(coo, :col_index)
    @inbounds for i in eachindex(rows)
        rows[i] += 1
        cols[i] += 1
    end
    return SparseArrays.sparse(
        rows,
        cols,
        values,
        Int(getproperty(coo, :row_count)),
        Int(getproperty(coo, :col_count)),
    )
end

function _wrapped_real_matrix(net::BalancedNetwork, table::Symbol)
    h = _live_handle(net, String(table))
    coo = _matrix_arrow_from_handle(h, table)
    idx_to_bus, bus_to_idx = _matrix_bus_maps(h, coo.row_count)
    return AdmittanceMatrix(idx_to_bus, bus_to_idx, _sparse_from_owned_coo!(coo, coo.value))
end

"""
    calc_admittance_matrix(net::BalancedNetwork)
    calc_admittance_matrix(path; from=nothing)

Return the Rust computed bus admittance matrix `Ybus` as a
`PowerIO.AdmittanceMatrix{ComplexF64}`. Matrix rows and columns use the dense
row index chosen by Rust; `idx_to_bus` maps those rows back to external bus ids.
"""
function calc_admittance_matrix(net::BalancedNetwork)
    h = _live_handle(net, "calc_admittance_matrix")
    coo = _matrix_arrow_from_handle(h, :ybus)
    idx_to_bus, bus_to_idx = _matrix_bus_maps(h, coo.row_count)
    values = complex.(coo.g, coo.b)
    return AdmittanceMatrix(idx_to_bus, bus_to_idx, _sparse_from_owned_coo!(coo, values))
end

calc_admittance_matrix(path::AbstractString; from=nothing) =
    _matrix_from_path(calc_admittance_matrix, path, "calc_admittance_matrix"; from=from)

"""
    calc_bprime_matrix(net::BalancedNetwork)
    calc_bprime_matrix(path; from=nothing)

Return Rust's FDPF `B'` matrix as a `PowerIO.AdmittanceMatrix{Float64}`. This
preserves Rust's positive Laplacian convention.
"""
calc_bprime_matrix(net::BalancedNetwork) = _wrapped_real_matrix(net, :bprime)

calc_bprime_matrix(path::AbstractString; from=nothing) =
    _matrix_from_path(calc_bprime_matrix, path, "calc_bprime_matrix"; from=from)

"""
    calc_bdoubleprime_matrix(net::BalancedNetwork)
    calc_bdoubleprime_matrix(path; from=nothing)

Return Rust's FDPF `B''` matrix as a `PowerIO.AdmittanceMatrix{Float64}`.
"""
calc_bdoubleprime_matrix(net::BalancedNetwork) = _wrapped_real_matrix(net, :bdoubleprime)

calc_bdoubleprime_matrix(path::AbstractString; from=nothing) =
    _matrix_from_path(calc_bdoubleprime_matrix, path, "calc_bdoubleprime_matrix"; from=from)

"""
    calc_susceptance_matrix(net::BalancedNetwork)
    calc_susceptance_matrix(path; from=nothing)

Return a PowerModels sign convention susceptance matrix as a
`PowerIO.AdmittanceMatrix{Float64}`. This is the sign adjusted form of Rust's
`B'` matrix: `calc_susceptance_matrix(net).matrix == -calc_bprime_matrix(net).matrix`.
"""
function calc_susceptance_matrix(net::BalancedNetwork)
    bp = calc_bprime_matrix(net)
    return AdmittanceMatrix(bp.idx_to_bus, bp.bus_to_idx, -bp.matrix)
end

calc_susceptance_matrix(path::AbstractString; from=nothing) =
    _matrix_from_path(calc_susceptance_matrix, path, "calc_susceptance_matrix"; from=from)

"""
    calc_incidence_matrix(net::BalancedNetwork)
    calc_incidence_matrix(path; from=nothing)

Return the Rust computed signed incidence matrix as a
`SparseMatrixCSC{Float64,Int}`. Rows use the `matrix_bus` axis and columns use
the `matrix_branch` axis selected by Rust.
"""
function calc_incidence_matrix(net::BalancedNetwork)
    h = _live_handle(net, "calc_incidence_matrix")
    coo = _matrix_arrow_from_handle(h, :incidence)
    return _sparse_from_owned_coo!(coo, coo.value)
end

calc_incidence_matrix(path::AbstractString; from=nothing) =
    _matrix_from_path(calc_incidence_matrix, path, "calc_incidence_matrix"; from=from)
