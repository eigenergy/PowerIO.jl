"""
    LoadSeries{T}

A dense per-bus time series of loads over a parsed network. `pd` and `qd` are
`n_buses` by `n_periods` matrices of active/reactive demand, per unit on `base_mva` and
ordered by the network's buses; `bus_ids[k]` is the source id of row `k`, so the
row-to-bus alignment is recorded rather than assumed. Read a period `t` off the matrices
directly (`series.pd[:, t]`); get the counts with [`n_periods`](@ref) / `n_buses`.

This is a focused convenience for ExaModelsPower's multiperiod OPF, which supplies dense
per-bus `.Pd`/`.Qd` load tables. PowerIO's general, format-neutral time series is the
`OperatingPointSeries` (the type of the same name in the powerio Rust core): a time axis
plus per-period sparse field updates over a base network, which represents more than
loads and stores only what changes each period. A later release binds that type; consumers
are encouraged to move to it at their own pace, and `LoadSeries` will not be hard removed.

Build one from a load matrix, a per-period demand multiplier, an id-keyed load table, or
two whitespace-delimited files:

```julia
PowerIO.LoadSeries(net, pd_mw, qd_mw)          # rows = buses in network order, MW
PowerIO.LoadSeries(net, curve)                 # scale the base-case loads per period
PowerIO.LoadSeries(net, pd_by_id, qd_by_id)    # Dict(bus_id => per-period MW vector)
PowerIO.read_load_series(net, pd_path, qd_path) # same layout as the matrix form, from files
```
"""
struct LoadSeries{T}
    pd::Matrix{T}
    qd::Matrix{T}
    bus_ids::Vector{Int}
    base_mva::T
end

"""
    n_periods(series) -> Int

Number of periods in a [`LoadSeries`](@ref).
"""
n_periods(s::LoadSeries) = size(s.pd, 2)
n_buses(s::LoadSeries) = size(s.pd, 1)

function Base.show(io::IO, s::LoadSeries{T}) where {T}
    print(io, "LoadSeries{$T}: ", n_buses(s), " buses, ", n_periods(s), " periods")
end

# Base loads (per unit), bus ids, and base MVA in the exact bus order
# parse_ac_power_data / mpopf use, so a series aligns to `data.bus` with no
# positional guessing.
function _load_alignment(net::BalancedNetwork, ::Type{T}) where {T<:Real}
    pd = to_powerdata(net; T=T)
    bus_ids = Int[Int(b.bus_i) for b in pd.bus]
    base_pd = T[b.pd for b in pd.bus]
    base_qd = T[b.qd for b in pd.bus]
    return T(pd.baseMVA), bus_ids, base_pd, base_qd
end

function _check_load_matrix(pd_mw::AbstractMatrix, qd_mw::AbstractMatrix, nbus::Int)
    size(pd_mw) == size(qd_mw) ||
        throw(DimensionMismatch(
            "LoadSeries: Pd is $(size(pd_mw)) but Qd is $(size(qd_mw))"))
    size(pd_mw, 1) == nbus ||
        throw(DimensionMismatch(
            "LoadSeries: load matrix has $(size(pd_mw, 1)) rows but the network has " *
            "$nbus buses (rows must be buses in the network's order)"))
    return nothing
end

function _perunit(x_mw::AbstractMatrix, base::T) where {T<:Real}
    out = Matrix{T}(undef, size(x_mw))
    @inbounds for j in axes(x_mw, 2), i in axes(x_mw, 1)
        v = T(x_mw[i, j]) / base
        isfinite(v) ||
            throw(ArgumentError("LoadSeries: non-finite load at bus row $i, period $j"))
        out[i, j] = v
    end
    return out
end

"""
    LoadSeries(net::BalancedNetwork, pd_mw, qd_mw; T=Float64)

Build a series from active/reactive load matrices in MW, `n_buses` by `n_periods`, whose
rows are the buses in `net`'s order. Values are converted to per unit on the network's
base MVA.
"""
function LoadSeries(net::BalancedNetwork, pd_mw::AbstractMatrix,
                    qd_mw::AbstractMatrix; T::Type{<:Real}=Float64)
    base, bus_ids, _, _ = _load_alignment(net, T)
    _check_load_matrix(pd_mw, qd_mw, length(bus_ids))
    LoadSeries{T}(_perunit(pd_mw, base), _perunit(qd_mw, base), bus_ids, base)
end

"""
    LoadSeries(net::BalancedNetwork, curve::AbstractVector; T=Float64)

Build a series by scaling the base-case bus loads by `curve[t]` in each period `t`. Only
the loads are scaled; fixed bus shunts stay at their base value.
"""
function LoadSeries(net::BalancedNetwork, curve::AbstractVector; T::Type{<:Real}=Float64)
    isempty(curve) &&
        throw(ArgumentError("LoadSeries: curve must have at least one period"))
    base, bus_ids, base_pd, base_qd = _load_alignment(net, T)
    c = T[T(x) for x in curve]
    pd = base_pd * transpose(c)
    qd = base_qd * transpose(c)
    LoadSeries{T}(pd, qd, bus_ids, base)
end

"""
    LoadSeries(net::BalancedNetwork, pd_by_id::AbstractDict, qd_by_id::AbstractDict; T=Float64)

Build a series from id-keyed load tables: each dict maps a source bus id to its per-period
MW vector. Every bus in `net` must have an entry and all vectors must share the same
length. This removes the positional row assumption of the matrix form.
"""
function LoadSeries(net::BalancedNetwork, pd_by_id::AbstractDict,
                    qd_by_id::AbstractDict; T::Type{<:Real}=Float64)
    base, bus_ids, _, _ = _load_alignment(net, T)
    pd = _matrix_from_id_table(pd_by_id, bus_ids, :Pd)
    qd = _matrix_from_id_table(qd_by_id, bus_ids, :Qd)
    _check_load_matrix(pd, qd, length(bus_ids))
    LoadSeries{T}(_perunit(pd, base), _perunit(qd, base), bus_ids, base)
end

function _matrix_from_id_table(by_id::AbstractDict, bus_ids::Vector{Int}, which::Symbol)
    nper = -1
    for id in bus_ids
        haskey(by_id, id) ||
            throw(ArgumentError("LoadSeries: $which has no entry for bus $id"))
        len = length(by_id[id])
        nper == -1 && (nper = len)
        len == nper ||
            throw(DimensionMismatch(
                "LoadSeries: $which vectors have unequal lengths ($nper vs $len)"))
    end
    out = Matrix{Float64}(undef, length(bus_ids), nper)
    for (k, id) in enumerate(bus_ids)
        out[k, :] .= by_id[id]
    end
    return out
end

"""
    read_load_series(net::BalancedNetwork, pd_path, qd_path; T=Float64)

Read two whitespace-delimited MW load matrices (rows = buses in `net`'s order, columns =
periods) and build a [`LoadSeries`](@ref). Replaces a raw `readdlm` of the `.Pd` / `.Qd`
files with a dimension-checked, per-unitized, bus-aligned series.
"""
function read_load_series(net::BalancedNetwork, pd_path::AbstractString,
                          qd_path::AbstractString; T::Type{<:Real}=Float64)
    pd_mw = _read_load_file(pd_path)
    qd_mw = _read_load_file(qd_path)
    LoadSeries(net, pd_mw, qd_mw; T=T)
end

function _read_load_file(path::AbstractString)
    isfile(path) ||
        throw(ArgumentError("LoadSeries: load file not found: $path"))
    rows = Vector{Vector{Float64}}()
    ncol = -1
    for (lineno, line) in enumerate(eachline(path))
        fields = split(line)
        isempty(fields) && continue
        vals = Float64[parse(Float64, f) for f in fields]
        ncol == -1 && (ncol = length(vals))
        length(vals) == ncol ||
            throw(DimensionMismatch(
                "LoadSeries: $path row $lineno has $(length(vals)) values, " *
                "expected $ncol"))
        push!(rows, vals)
    end
    isempty(rows) &&
        throw(ArgumentError("LoadSeries: $path has no load rows"))
    return permutedims(reduce(hcat, rows))
end
