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

"""
    PowerIO.IncidenceMatrix{T}

Sparse branch by bus incidence matrix with its bus ids and source branch rows.
`matrix[e, i]` is `+1` at branch `e`'s from bus and `-1` at its to bus.
`branch_rows[e]` is the 1-based row in the parsed branch table; zero denotes a
branch introduced while building the indexed network.
"""
struct IncidenceMatrix{T}
    idx_to_bus::Vector{Int}
    bus_to_idx::Dict{Int,Int}
    branch_rows::Vector{Int}
    matrix::SparseArrays.SparseMatrixCSC{T,Int}
end

Base.show(io::IO, x::IncidenceMatrix{<:Number}) =
    print(io, "IncidenceMatrix(", size(x.matrix, 1), " branches, ",
          size(x.matrix, 2), " buses, ", SparseArrays.nnz(x.matrix), " entries)")

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

Return Rust's FDPF `B'` matrix as a `PowerIO.AdmittanceMatrix{Float64}`.
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

Return the PowerModels bus susceptance matrix
`B = A' * Diagonal(b) * A` under the `:series` convention, where
`b[e] = imag(inv(r[e] + im*x[e]))`. The result is symmetric. Phase shifts are
not included in `B`; [`DcPowerFlowData`](@ref) returns their affine bus
injection separately.
"""
function calc_susceptance_matrix(net::BalancedNetwork)
    A, b, idx_to_bus, bus_to_idx =
        _series_incidence_and_susceptance(net, "calc_susceptance_matrix")
    Bf = _branch_susceptance_matrix(A, b)
    B = transpose(A) * Bf
    return AdmittanceMatrix(idx_to_bus, bus_to_idx, B)
end

calc_susceptance_matrix(path::AbstractString; from=nothing) =
    _matrix_from_path(calc_susceptance_matrix, path, "calc_susceptance_matrix"; from=from)

"""
    calc_incidence_matrix(net::BalancedNetwork)
    calc_incidence_matrix(path; from=nothing)

Return the signed incidence matrix in PowerModels orientation: branches by
buses, with `+1` at each branch's from bus and `-1` at its to bus. The result is
an [`IncidenceMatrix`](@ref), which carries the external bus ids and source
branch rows.
"""
function _incidence_arrow(net::BalancedNetwork, fname::AbstractString)
    h = _live_handle(net, fname)
    coo = _matrix_arrow_from_handle(h, :incidence)
    idx_to_bus, bus_to_idx = _matrix_bus_maps(h, coo.row_count)
    return h, coo, idx_to_bus, bus_to_idx
end

function _sparse_incidence_from_owned_coo!(coo)
    bus_rows = getproperty(coo, :row_index)
    branch_cols = getproperty(coo, :col_index)
    @inbounds for i in eachindex(bus_rows)
        bus_rows[i] += 1
        branch_cols[i] += 1
    end
    return SparseArrays.sparse(
        branch_cols,
        bus_rows,
        getproperty(coo, :value),
        Int(getproperty(coo, :col_count)),
        Int(getproperty(coo, :row_count)),
    )
end

function _incidence_matrix_from_owned_coo!(coo, idx_to_bus, bus_to_idx, branch_rows)
    matrix = _sparse_incidence_from_owned_coo!(coo)
    return IncidenceMatrix(idx_to_bus, bus_to_idx, branch_rows, matrix)
end

function _matrix_branch_rows(h::BalancedNetworkHandle, m::Integer)
    axis = _arrow_from_handle(h, :matrix_branch, true)
    rows = Vector{Int}(undef, Int(m))
    seen = falses(Int(m))
    for k in eachindex(axis.index)
        idx = Int(axis.index[k]) + 1
        1 <= idx <= length(rows) || error(
            "PowerIO.calc_incidence_matrix: matrix branch index $(axis.index[k]) is out of range")
        seen[idx] && error(
            "PowerIO.calc_incidence_matrix: duplicate matrix branch index $(axis.index[k])")
        source_row = Int(axis.source_row[k])
        rows[idx] = source_row < 0 ? 0 : source_row + 1
        seen[idx] = true
    end
    all(seen) || error("PowerIO.calc_incidence_matrix: matrix branch table is missing an index")
    return rows
end

function calc_incidence_matrix(net::BalancedNetwork)
    h, coo, idx_to_bus, bus_to_idx = _incidence_arrow(net, "calc_incidence_matrix")
    branch_rows = _matrix_branch_rows(h, coo.col_count)
    return _incidence_matrix_from_owned_coo!(
        coo, idx_to_bus, bus_to_idx, branch_rows)
end

calc_incidence_matrix(path::AbstractString; from=nothing) =
    _matrix_from_path(calc_incidence_matrix, path, "calc_incidence_matrix"; from=from)

function _branch_susceptance_matrix(A::SparseArrays.SparseMatrixCSC{Float64,Int},
                                        b::AbstractVector{<:Real})
    size(A, 1) == length(b) || throw(DimensionMismatch(
        "incidence matrix has $(size(A, 1)) branch rows but b has $(length(b)) values"))
    Bf = copy(A)
    rowval = SparseArrays.rowvals(Bf)
    nzval = SparseArrays.nonzeros(Bf)
    for bus in axes(Bf, 2)
        for ptr in SparseArrays.nzrange(Bf, bus)
            nzval[ptr] *= b[rowval[ptr]]
        end
    end
    return Bf
end

function _series_incidence_and_susceptance(net::BalancedNetwork, fname::AbstractString)
    _, coo, idx_to_bus, bus_to_idx = _incidence_arrow(net, fname)
    m = Int(coo.col_count)
    b = Vector{Float64}(undef, m)
    got = _dc_vector_call(net, fname, :pio_branch_susceptance,
                          Float64, "series", b, m)
    _check_filled(got, m, "pio_branch_susceptance")
    A = _sparse_incidence_from_owned_coo!(coo)
    return A, b, idx_to_bus, bus_to_idx
end

"""
    calc_branch_susceptance_matrix(net::BalancedNetwork)
    calc_branch_susceptance_matrix(path; from=nothing)

Return the PowerModels branch susceptance matrix
`Bf = Diagonal(b) * A` under the `:series` convention. Rows are the branch rows
and columns are the bus columns of [`DcPowerFlowData`](@ref).
"""
function calc_branch_susceptance_matrix(net::BalancedNetwork)
    A, b, _, _ =
        _series_incidence_and_susceptance(net, "calc_branch_susceptance_matrix")
    return _branch_susceptance_matrix(A, b)
end

calc_branch_susceptance_matrix(path::AbstractString; from=nothing) =
    _matrix_from_path(calc_branch_susceptance_matrix, path,
                      "calc_branch_susceptance_matrix"; from=from)
