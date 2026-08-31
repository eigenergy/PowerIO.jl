# Sparse matrix helpers over the Rust matrix API. The C ABI transports
# matrix entries as Arrow COO tables; this file turns them into Julia sparse
# matrices and wrappers that retain the bus row mapping.

"""
    BusMappedMatrix{T}

Sparse matrix plus the bus id mapping used by its rows. `idx_to_bus[i]` is the
external bus id at sparse row `i`, `bus_to_idx[id]` is the row for a bus id,
and `matrix` holds the sparse values. Square bus matrices use the same mapping
for columns.
"""
struct BusMappedMatrix{T}
    idx_to_bus::Vector{Int}
    bus_to_idx::Dict{Int,Int}
    matrix::SparseArrays.SparseMatrixCSC{T,Int}
end

Base.show(io::IO, x::BusMappedMatrix{<:Number}) =
    print(io, "BusMappedMatrix(", length(x.idx_to_bus), " bus rows, ",
          SparseArrays.nnz(x.matrix), " entries)")

function _matrix_from_path(f, path::AbstractString, fname::AbstractString;
                           format::Union{AbstractString,Nothing}=nothing)
    net = _parse_balanced(path; format)
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

# Map the dense matrix rows and columns back to external bus ids through the
# authoritative `matrix_bus` axis table. The matrix COO rows carry the
# `matrix_bus` axis (checked against schema metadata in `_check_matrix_axes`), so
# that axis map is what indexes them — not the handle's bus order. Any Rust-side
# reorder or expansion (e.g. 3-winding star-point lowering) is reflected here
# directly, with no bus-count coincidence standing in for the axis map.
function _matrix_bus_maps(h::BalancedNetworkHandle, matrix_n::Integer)
    idx_to_bus, bus_to_idx = _matrix_bus_maps_from_arrow(h)
    length(idx_to_bus) == Int(matrix_n) ||
        error("PowerIO matrix: matrix_bus axis has $(length(idx_to_bus)) entries, " *
              "but the matrix has $matrix_n rows")
    return idx_to_bus, bus_to_idx
end

_matrix_bus_maps(net::BalancedNetwork) =
    _matrix_bus_maps_from_arrow(_live_handle(net, "matrix_bus"))

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
    return BusMappedMatrix(idx_to_bus, bus_to_idx, _sparse_from_owned_coo!(coo, coo.value))
end

"""
    calc_admittance_matrix(net::BalancedNetwork)
    calc_admittance_matrix(path; format=nothing)

Return the Rust computed bus admittance matrix `Ybus` as a
`BusMappedMatrix{ComplexF64}`. Matrix rows and columns use the dense
row index chosen by Rust; `idx_to_bus` maps those rows back to external bus ids.
"""
function calc_admittance_matrix(net::BalancedNetwork)
    h = _live_handle(net, "calc_admittance_matrix")
    coo = _matrix_arrow_from_handle(h, :ybus)
    idx_to_bus, bus_to_idx = _matrix_bus_maps(h, coo.row_count)
    values = complex.(coo.g, coo.b)
    return BusMappedMatrix(idx_to_bus, bus_to_idx, _sparse_from_owned_coo!(coo, values))
end

calc_admittance_matrix(path::AbstractString;
                       format::Union{AbstractString,Nothing}=nothing) =
    _matrix_from_path(calc_admittance_matrix, path, "calc_admittance_matrix"; format)

"""
    calc_bprime_matrix(net::BalancedNetwork)
    calc_bprime_matrix(path; format=nothing)

Return Rust's FDPF `B'` matrix as a `BusMappedMatrix{Float64}`. This
preserves Rust's positive Laplacian convention.
"""
calc_bprime_matrix(net::BalancedNetwork) = _wrapped_real_matrix(net, :bprime)

calc_bprime_matrix(path::AbstractString;
                   format::Union{AbstractString,Nothing}=nothing) =
    _matrix_from_path(calc_bprime_matrix, path, "calc_bprime_matrix"; format)

"""
    calc_bdoubleprime_matrix(net::BalancedNetwork)
    calc_bdoubleprime_matrix(path; format=nothing)

Return Rust's FDPF `B''` matrix as a `BusMappedMatrix{Float64}`.
"""
calc_bdoubleprime_matrix(net::BalancedNetwork) = _wrapped_real_matrix(net, :bdoubleprime)

calc_bdoubleprime_matrix(path::AbstractString;
                         format::Union{AbstractString,Nothing}=nothing) =
    _matrix_from_path(calc_bdoubleprime_matrix, path, "calc_bdoubleprime_matrix"; format)

"""
    calc_incidence_matrix(net::BalancedNetwork; formula="series_susceptance")
    calc_incidence_matrix(path; format=nothing, formula="series_susceptance")

Calculate the canonical signed incidence matrix as branches by buses, with
`+1` at the from bus and `-1` at the to bus. These overloads have the same
orientation and return type as the [`PioModule`](@ref) method.
"""
calc_incidence_matrix(net::BalancedNetwork;
                      formula::AbstractString="series_susceptance") =
    calc_incidence_matrix(PioModule(net); formula)

calc_incidence_matrix(path::AbstractString;
                      format::Union{AbstractString,Nothing}=nothing,
                      formula::AbstractString="series_susceptance") =
    calc_incidence_matrix(parse_file(path; format); formula)
