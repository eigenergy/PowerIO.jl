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

function _matrix_network(path::AbstractString, fname::AbstractString; from=nothing)
    net = parse_file(path; from=from)
    net isa BalancedNetwork && return net
    error("PowerIO.$fname: matrix APIs currently support balanced networks only")
end

function _solver_bus_maps(net::BalancedNetwork)
    sb = to_arrow(net, :solver_bus)
    n = length(sb.index)
    idx_to_bus = Vector{Int}(undef, n)
    seen = falses(n)
    for k in eachindex(sb.index)
        idx = Int(sb.index[k]) + 1
        (1 <= idx <= n) || error("PowerIO matrix: solver bus index $(sb.index[k]) is out of range")
        seen[idx] && error("PowerIO matrix: duplicate solver bus index $(sb.index[k])")
        idx_to_bus[idx] = Int(sb.bus_id[k])
        seen[idx] = true
    end
    all(seen) || error("PowerIO matrix: solver bus table is missing an index")
    bus_to_idx = Dict(id => idx for (idx, id) in enumerate(idx_to_bus))
    return idx_to_bus, bus_to_idx
end

function _sparse_from_coo(coo, values)
    return SparseArrays.sparse(
        getproperty(coo, :row_index) .+ 1,
        getproperty(coo, :col_index) .+ 1,
        values,
        Int(getproperty(coo, :row_count)),
        Int(getproperty(coo, :col_count)),
    )
end

function _wrapped_real_matrix(net::BalancedNetwork, table::Symbol)
    coo = to_arrow(net, table)
    idx_to_bus, bus_to_idx = _solver_bus_maps(net)
    return AdmittanceMatrix(idx_to_bus, bus_to_idx, _sparse_from_coo(coo, coo.value))
end

"""
    calc_admittance_matrix(net::BalancedNetwork)
    calc_admittance_matrix(path; from=nothing)

Return the Rust computed bus admittance matrix `Ybus` as a
`PowerIO.AdmittanceMatrix{ComplexF64}`. Matrix rows and columns use the dense
row index chosen by Rust; `idx_to_bus` maps those rows back to external bus ids.
"""
function calc_admittance_matrix(net::BalancedNetwork)
    coo = to_arrow(net, :ybus)
    idx_to_bus, bus_to_idx = _solver_bus_maps(net)
    values = coo.g .+ im .* coo.b
    return AdmittanceMatrix(idx_to_bus, bus_to_idx, _sparse_from_coo(coo, values))
end

calc_admittance_matrix(path::AbstractString; from=nothing) =
    calc_admittance_matrix(_matrix_network(path, "calc_admittance_matrix"; from=from))

"""
    calc_bprime_matrix(net::BalancedNetwork)
    calc_bprime_matrix(path; from=nothing)

Return Rust's FDPF `B'` matrix as a `PowerIO.AdmittanceMatrix{Float64}`. This
preserves Rust's positive Laplacian convention.
"""
calc_bprime_matrix(net::BalancedNetwork) = _wrapped_real_matrix(net, :bprime)

calc_bprime_matrix(path::AbstractString; from=nothing) =
    calc_bprime_matrix(_matrix_network(path, "calc_bprime_matrix"; from=from))

"""
    calc_bdoubleprime_matrix(net::BalancedNetwork)
    calc_bdoubleprime_matrix(path; from=nothing)

Return Rust's FDPF `B''` matrix as a `PowerIO.AdmittanceMatrix{Float64}`.
"""
calc_bdoubleprime_matrix(net::BalancedNetwork) = _wrapped_real_matrix(net, :bdoubleprime)

calc_bdoubleprime_matrix(path::AbstractString; from=nothing) =
    calc_bdoubleprime_matrix(_matrix_network(path, "calc_bdoubleprime_matrix"; from=from))

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
    calc_susceptance_matrix(_matrix_network(path, "calc_susceptance_matrix"; from=from))

"""
    calc_incidence_matrix(net::BalancedNetwork)
    calc_incidence_matrix(path; from=nothing)

Return the Rust computed signed incidence matrix as a
`SparseMatrixCSC{Float64,Int}`. Rows use the dense solver bus index space and
columns follow the in service branch order selected by Rust.
"""
function calc_incidence_matrix(net::BalancedNetwork)
    coo = to_arrow(net, :incidence)
    return _sparse_from_coo(coo, coo.value)
end

calc_incidence_matrix(path::AbstractString; from=nothing) =
    calc_incidence_matrix(_matrix_network(path, "calc_incidence_matrix"; from=from))
