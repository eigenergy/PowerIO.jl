# Sparse matrix helpers over the Rust matrix API. The C ABI transports
# matrix entries as Arrow COO tables; this file turns them into Julia sparse
# matrices and PowerModels compatible wrappers.

"""
    PowerIO.AdmittanceMatrix{T}

Sparse bus matrix plus the bus id mapping used by the matrix rows and columns.
The layout matches PowerModels' `AdmittanceMatrix`: `idx_to_bus[i]` is the
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

`B'` is the fast decoupled power flow matrix, so a phase shifting branch folds
into the off diagonal and the result is **not symmetric in general**. On
PowerModels' `case5.m`, whose 3-4 pair carries a one degree shift, the two off
diagonal entries differ by 0.23.

It is therefore not the DC OPF `B`-theta Laplacian, which is a different matrix:
that one weights each branch by `DcConvention`, stays symmetric, and routes phase
shifts through the injection vector rather than the matrix. Build that one from
[`calc_incidence_matrix`](@ref) and the branch series values.
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
