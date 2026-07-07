function _powerdata_real(x, ::Type{T}, element::AbstractString,
                         field::Symbol) where {T<:Real}
    x === nothing &&
        throw(ArgumentError("PowerIO.to_powerdata: $element has missing field `$field`"))
    y = try
        T(x)
    catch err
        msg = sprint(showerror, err)
        throw(ArgumentError("PowerIO.to_powerdata: $element has invalid field `$field`: $msg"))
    end
    isfinite(y) ||
        throw(ArgumentError("PowerIO.to_powerdata: $element has non-finite field `$field`"))
    return y
end

function _quadratic_cost_coeffs(coeffs::Vector{T}, base::T,
                                normalized::Bool) where {T<:Real}
    scaled = copy(coeffs)
    if !normalized
        k = length(scaled)
        for i in eachindex(scaled)
            scaled[i] *= base^(k - i)
        end
    end
    while length(scaled) > 3 && iszero(first(scaled))
        popfirst!(scaled)
    end
    length(scaled) > 3 &&
        throw(ArgumentError("PowerIO.to_powerdata: polynomial generator cost cannot fit PowerData quadratic cost"))

    vals = [zero(T), zero(T), zero(T)]
    offset = 3 - length(scaled)
    for (i, c) in enumerate(scaled)
        vals[offset + i] = c
    end
    return vals
end

function _cost_tuple(g, ::Type{T}, base::T; normalized::Bool=false) where {T<:Real}
    cost = _get(g, :cost, nothing)
    cost === nothing && return (false, zero(T), zero(T), 0, (zero(T), zero(T), zero(T)))
    coeffs = [_powerdata_real(c, T, "generator cost", :coeffs)
              for c in collect(cost.coeffs)]
    model = Int(cost.model)
    n = Int(cost.ncost)
    if model == 2
        limit = min(n, length(coeffs))
        trimmed = limit == 0 ? T[] : coeffs[1:limit]
        vals = _quadratic_cost_coeffs(trimmed, base, normalized)
        return (true,
                _powerdata_real(cost.startup, T, "generator cost", :startup),
                _powerdata_real(cost.shutdown, T, "generator cost", :shutdown),
                3, (vals[1], vals[2], vals[3]))
    else
        limit = model == 1 ? min(2 * n, length(coeffs)) : length(coeffs)
        trimmed = limit == 0 ? T[] : coeffs[1:limit]
        vals = [zero(T), zero(T), zero(T)]
        for i in 1:min(3, length(trimmed))
            vals[i] = trimmed[i]
        end
    end
    return (model == 2,
            _powerdata_real(cost.startup, T, "generator cost", :startup),
            _powerdata_real(cost.shutdown, T, "generator cost", :shutdown),
            n, (vals[1], vals[2], vals[3]))
end

function _branch_coeffs(r::T, x::T, b_fr::T, b_to::T, g_fr::T, g_to::T,
                        tap::T, shift::T) where {T<:Real}
    y = iszero(r) && iszero(x) ? zero(Complex{T}) : inv(complex(r, x))
    isfinite(real(y)) && isfinite(imag(y)) || (y = zero(Complex{T}))
    g = real(y)
    b = imag(y)
    tap_eff = isapprox(tap, zero(T)) ? one(T) : tap
    tr = tap_eff * cos(shift)
    ti = tap_eff * sin(shift)
    ttm = tr^2 + ti^2
    return (
        (-g * tr - b * ti) / ttm,
        (-b * tr + g * ti) / ttm,
        (-g * tr + b * ti) / ttm,
        (-b * tr - g * ti) / ttm,
        (g + g_fr) / ttm,
        (b + b_fr) / ttm,
        g + g_to,
        b + b_to,
    )
end

function _to_powerdata_normalized(net::BalancedNetwork, ::Type{T}) where {T<:Real}
    base = _powerdata_real(base_mva(net), T, "network", :base_mva)
    raw_buses = collect(buses(net))
    kept_ids = [Int(b.id) for b in raw_buses]
    id_to_idx = Dict(id => i for (i, id) in enumerate(kept_ids))

    pd = zeros(T, length(kept_ids))
    qd = zeros(T, length(kept_ids))
    for (row, l) in enumerate(loads(net))
        idx = get(id_to_idx, Int(l.bus), 0)
        idx == 0 && continue
        pd[idx] += _powerdata_real(l.p, T, "load $row", :p)
        qd[idx] += _powerdata_real(l.q, T, "load $row", :q)
    end
    gs = zeros(T, length(kept_ids))
    bs = zeros(T, length(kept_ids))
    for (row, s) in enumerate(shunts(net))
        idx = get(id_to_idx, Int(s.bus), 0)
        idx == 0 && continue
        gs[idx] += _powerdata_real(s.g, T, "shunt $row", :g)
        bs[idx] += _powerdata_real(s.b, T, "shunt $row", :b)
    end

    # Each vector is built with `map`/a comprehension rather than a `NamedTuple[]`
    # accumulator so its element type is the concrete row type, not the abstract
    # `NamedTuple`. ExaModelsPower moves these rows to the GPU, and `CuArray`
    # rejects an abstract element type.
    bus_rows = map(enumerate(raw_buses)) do (i, b)
        id = Int(b.id)
        (;
            i,
            bus_i = id,
            type = bus_type_code(String(b.kind)),
            pd = pd[i],
            qd = qd[i],
            gs = gs[i],
            bs = bs[i],
            area = Int(b.area),
            vm = _powerdata_real(b.vm, T, "bus $id", :vm),
            va = _powerdata_real(b.va, T, "bus $id", :va),
            baseKV = _powerdata_real(b.base_kv, T, "bus $id", :base_kv),
            zone = Int(b.zone),
            vmax = _powerdata_real(b.vmax, T, "bus $id", :vmax),
            vmin = _powerdata_real(b.vmin, T, "bus $id", :vmin),
        )
    end

    kept_gens = [g for g in generators(net) if get(id_to_idx, Int(g.bus), 0) != 0]
    gen_rows = map(enumerate(kept_gens)) do (i, g)
        model_poly, startup, shutdown, ncost, c =
            _cost_tuple(g, T, base; normalized=true)
        (;
            i,
            bus = id_to_idx[Int(g.bus)],
            pg = _powerdata_real(g.pg, T, "generator $i", :pg),
            qg = _powerdata_real(g.qg, T, "generator $i", :qg),
            qmax = _powerdata_real(g.qmax, T, "generator $i", :qmax),
            qmin = _powerdata_real(g.qmin, T, "generator $i", :qmin),
            vg = _powerdata_real(g.vg, T, "generator $i", :vg),
            mbase = _powerdata_real(g.mbase, T, "generator $i", :mbase),
            status = Int(Bool(_get(g, :in_service, true))),
            pmax = _powerdata_real(g.pmax, T, "generator $i", :pmax),
            pmin = _powerdata_real(g.pmin, T, "generator $i", :pmin),
            model_poly,
            startup,
            shutdown,
            n = ncost,
            c,
        )
    end

    kept_branches = [br for br in branches(net)
                     if get(id_to_idx, Int(br.from), 0) != 0 &&
                        get(id_to_idx, Int(br.to), 0) != 0]
    m = length(kept_branches)
    branch_rows = map(enumerate(kept_branches)) do (i, br)
        label = "branch $i"
        f = id_to_idx[Int(br.from)]
        t = id_to_idx[Int(br.to)]
        tap_raw = _powerdata_real(br.tap, T, label, :tap)
        tap = isapprox(tap_raw, zero(T)) ? one(T) : tap_raw
        shift = _powerdata_real(br.shift, T, label, :shift)
        b = _powerdata_real(br.b, T, label, :b)
        b_fr = b / T(2)
        b_to = b / T(2)
        g_fr = zero(T)
        g_to = zero(T)
        r = _powerdata_real(br.r, T, label, :br_r)
        x = _powerdata_real(br.x, T, label, :br_x)
        c1, c2, c3, c4, c5, c6, c7, c8 =
            _branch_coeffs(r, x, b_fr, b_to, g_fr, g_to, tap, shift)
        (;
            i,
            f_bus = f,
            t_bus = t,
            br_r = r,
            br_x = x,
            b_fr,
            b_to,
            g_fr,
            g_to,
            rate_a = _powerdata_real(br.rate_a, T, label, :rate_a),
            rate_b = _powerdata_real(br.rate_b, T, label, :rate_b),
            rate_c = _powerdata_real(br.rate_c, T, label, :rate_c),
            tap,
            shift,
            status = Int(Bool(_get(br, :in_service, true))),
            angmin = _powerdata_real(br.angmin, T, label, :angmin),
            angmax = _powerdata_real(br.angmax, T, label, :angmax),
            f_idx = i,
            t_idx = i + m,
            c1, c2, c3, c4, c5, c6, c7, c8,
        )
    end
    arc_rows = vcat(
        [(; i, bus = br.f_bus, rate_a = br.rate_a) for (i, br) in enumerate(branch_rows)],
        [(; i = i + m, bus = br.t_bus, rate_a = br.rate_a) for (i, br) in enumerate(branch_rows)],
    )

    storage_rows = [(;
        i = row,
        storage_bus = Int(st.bus),
        Pexts = _powerdata_real(st.ps, T, "storage $row", :ps),
        Qexts = _powerdata_real(st.qs, T, "storage $row", :qs),
        energy = _powerdata_real(st.energy, T, "storage $row", :energy),
        energy_rating = _powerdata_real(st.energy_rating, T, "storage $row", :energy_rating),
        charge_rating = _powerdata_real(st.charge_rating, T, "storage $row", :charge_rating),
        discharge_rating = _powerdata_real(st.discharge_rating, T, "storage $row", :discharge_rating),
        charge_efficiency = _powerdata_real(st.charge_efficiency, T, "storage $row", :charge_efficiency),
        discharge_efficiency = _powerdata_real(st.discharge_efficiency, T, "storage $row", :discharge_efficiency),
        thermal_rating = _powerdata_real(st.thermal_rating, T, "storage $row", :thermal_rating),
        qmin = _powerdata_real(st.qmin, T, "storage $row", :qmin),
        qmax = _powerdata_real(st.qmax, T, "storage $row", :qmax),
        Zr = _powerdata_real(st.r, T, "storage $row", :r),
        Zim = _powerdata_real(st.x, T, "storage $row", :x),
        p_loss = _powerdata_real(st.p_loss, T, "storage $row", :p_loss),
        q_loss = _powerdata_real(st.q_loss, T, "storage $row", :q_loss),
        status = Int(Bool(_get(st, :in_service, true))),
    ) for (row, st) in enumerate(storage(net))]

    return (;
        version = "2",
        baseMVA = base,
        bus = bus_rows,
        gen = gen_rows,
        branch = branch_rows,
        arc = arc_rows,
        storage = storage_rows,
    )
end

"""
    to_powerdata(net; filtered=true, T=Float64) -> NamedTuple
    to_powerdata(path; from=nothing, filtered=true, T=Float64) -> NamedTuple

Return a NamedTuple in ExaPowerIO's `PowerData` layout: `version`, `baseMVA`, `bus`,
`gen`, `branch`, `arc`, and `storage`. Rows use the field names ExaModelsPower
reads. With the default `filtered=true`, values are derived from
[`to_normalized`](@ref): `bus_i` preserves the source bus id, powers are per unit,
branch angle fields are radians, and branch/generator bus references are indices
into the bus vector.
"""
function to_powerdata(net::BalancedNetwork; filtered::Bool=true, T::Type{<:Real}=Float64)
    if filtered
        norm = source_format(net) == "Normalized" ? net : to_normalized(net)
        return _to_powerdata_normalized(norm, T)
    end

    base = T(base_mva(net))
    raw_buses = collect(buses(net))
    keep_bus = Dict{Int,Bool}()
    for b in raw_buses
        keep_bus[Int(b.id)] = !filtered || String(b.kind) != "ISOLATED"
    end
    kept_ids = [Int(b.id) for b in raw_buses if keep_bus[Int(b.id)]]
    id_to_idx = Dict(id => i for (i, id) in enumerate(kept_ids))

    pd = zeros(T, length(kept_ids))
    qd = zeros(T, length(kept_ids))
    for l in loads(net)
        idx = get(id_to_idx, Int(l.bus), 0)
        idx == 0 && continue
        if !filtered || Bool(_get(l, :in_service, true))
            pd[idx] += T(l.p) / base
            qd[idx] += T(l.q) / base
        end
    end
    gs = zeros(T, length(kept_ids))
    bs = zeros(T, length(kept_ids))
    for s in shunts(net)
        idx = get(id_to_idx, Int(s.bus), 0)
        idx == 0 && continue
        if !filtered || Bool(_get(s, :in_service, true))
            gs[idx] += T(s.g) / base
            bs[idx] += T(s.b) / base
        end
    end

    bus_rows = NamedTuple[]
    for b in raw_buses
        id = Int(b.id)
        keep_bus[id] || continue
        i = id_to_idx[id]
        push!(bus_rows, (;
            i,
            bus_i = id,
            type = bus_type_code(String(b.kind)),
            pd = pd[i],
            qd = qd[i],
            gs = gs[i],
            bs = bs[i],
            area = Int(b.area),
            vm = T(b.vm),
            va = T(b.va),
            baseKV = T(b.base_kv),
            zone = Int(b.zone),
            vmax = T(b.vmax),
            vmin = T(b.vmin),
        ))
    end

    gen_rows = NamedTuple[]
    has_gen = falses(length(bus_rows))
    biggest_gen_bus = 0
    biggest_gen_pmax = typemin(T)
    for (row, g) in enumerate(generators(net))
        idx = get(id_to_idx, Int(g.bus), 0)
        idx == 0 && continue
        status = Bool(g.in_service)
        filtered && !status && continue
        model_poly, startup, shutdown, ncost, c =
            _cost_tuple(g, T, base; normalized=false)
        pmax = T(g.pmax) / base
        push!(gen_rows, (;
            i = length(gen_rows) + 1,
            bus = idx,
            pg = T(g.pg) / base,
            qg = T(g.qg) / base,
            qmax = T(g.qmax) / base,
            qmin = T(g.qmin) / base,
            vg = T(g.vg),
            mbase = T(g.mbase),
            status = Int(status),
            pmax,
            pmin = T(g.pmin) / base,
            model_poly,
            startup,
            shutdown,
            n = ncost,
            c,
        ))
        if status
            has_gen[idx] = true
            if pmax > biggest_gen_pmax
                biggest_gen_pmax = pmax
                biggest_gen_bus = idx
            end
        end
    end

    for i in eachindex(bus_rows)
        typ = bus_rows[i].type
        if has_gen[i] && typ == 1
            bus_rows[i] = merge(bus_rows[i], (; type = 2))
        elseif !has_gen[i] && (typ == 2 || typ == 3)
            bus_rows[i] = merge(bus_rows[i], (; type = 1))
        end
    end
    if !any(row.type == 3 for row in bus_rows) && biggest_gen_bus > 0
        bus_rows[biggest_gen_bus] = merge(bus_rows[biggest_gen_bus], (; type = 3))
    end

    kept_branches = Any[]
    for br in branches(net)
        f = get(id_to_idx, Int(br.from), 0)
        t = get(id_to_idx, Int(br.to), 0)
        (f == 0 || t == 0) && continue
        status = Bool(br.in_service)
        filtered && !status && continue
        push!(kept_branches, br)
    end
    m = length(kept_branches)
    branch_rows = NamedTuple[]
    for (i, br) in enumerate(kept_branches)
        f = id_to_idx[Int(br.from)]
        t = id_to_idx[Int(br.to)]
        label = "branch $i"
        tap_raw = _powerdata_real(br.tap, T, label, :tap)
        tap = isapprox(tap_raw, zero(T)) ? one(T) : tap_raw
        shift = _powerdata_real(br.shift, T, label, :shift) / T(180) * T(pi)
        b = _powerdata_real(br.b, T, label, :b)
        b_fr = b / T(2)
        b_to = b / T(2)
        g_fr = zero(T)
        g_to = zero(T)
        r = _powerdata_real(br.r, T, label, :br_r)
        x = _powerdata_real(br.x, T, label, :br_x)
        c1, c2, c3, c4, c5, c6, c7, c8 =
            _branch_coeffs(r, x, b_fr, b_to, g_fr, g_to, tap, shift)
        push!(branch_rows, (;
            i,
            f_bus = f,
            t_bus = t,
            br_r = r,
            br_x = x,
            b_fr,
            b_to,
            g_fr,
            g_to,
            rate_a = _powerdata_real(br.rate_a, T, label, :rate_a) / base,
            rate_b = _powerdata_real(br.rate_b, T, label, :rate_b) / base,
            rate_c = _powerdata_real(br.rate_c, T, label, :rate_c) / base,
            tap,
            shift,
            status = Int(Bool(br.in_service)),
            angmin = _powerdata_real(br.angmin, T, label, :angmin) / T(180) * T(pi),
            angmax = _powerdata_real(br.angmax, T, label, :angmax) / T(180) * T(pi),
            f_idx = i,
            t_idx = i + m,
            c1, c2, c3, c4, c5, c6, c7, c8,
        ))
    end
    arc_rows = NamedTuple[]
    for (i, br) in enumerate(branch_rows)
        push!(arc_rows, (; i, bus = br.f_bus, rate_a = br.rate_a))
    end
    for (i, br) in enumerate(branch_rows)
        push!(arc_rows, (; i = i + m, bus = br.t_bus, rate_a = br.rate_a))
    end

    storage_rows = [(;
        i = row,
        storage_bus = Int(st.bus),
        Pexts = T(st.ps),
        Qexts = T(st.qs),
        energy = T(st.energy) / base,
        energy_rating = T(st.energy_rating) / base,
        charge_rating = T(st.charge_rating) / base,
        discharge_rating = T(st.discharge_rating) / base,
        charge_efficiency = T(st.charge_efficiency),
        discharge_efficiency = T(st.discharge_efficiency),
        thermal_rating = T(st.thermal_rating) / base,
        qmin = T(st.qmin) / base,
        qmax = T(st.qmax) / base,
        Zr = T(st.r),
        Zim = T(st.x),
        p_loss = T(st.p_loss),
        q_loss = T(st.q_loss),
        status = Int(Bool(st.in_service)),
    ) for (row, st) in enumerate(storage(net))]

    return (;
        version = "2",
        baseMVA = base,
        bus = bus_rows,
        gen = gen_rows,
        branch = branch_rows,
        arc = arc_rows,
        storage = storage_rows,
    )
end

to_powerdata(path::AbstractString; from=nothing, filtered::Bool=true,
             T::Type{<:Real}=Float64) =
    to_powerdata(parse_file(path; from=from); filtered=filtered, T=T)

"""
    parse_ac_power_data(input; from=nothing, filtered=true, T=Float64) -> NamedTuple

Return the NamedTuple layout consumed by ExaModelsPower's `build_polar_opf`,
`build_rect_opf`, and `build_dcopf`. `input` may be a [`BalancedNetwork`](@ref) or a path.
"""
function parse_ac_power_data(input; from=nothing, filtered::Bool=true,
                             T::Type{<:Real}=Float64)
    pd = input isa BalancedNetwork ? to_powerdata(input; filtered=filtered, T=T) :
         to_powerdata(String(input); from=from, filtered=filtered, T=T)
    return (;
        baseMVA = [pd.baseMVA],
        bus = pd.bus,
        gen = pd.gen,
        arc = pd.arc,
        branch = pd.branch,
        storage = pd.storage,
        ref_buses = [i for i in 1:length(pd.bus) if pd.bus[i].type == 3],
        vmax = [b.vmax for b in pd.bus],
        vmin = [b.vmin for b in pd.bus],
        pmax = [g.pmax for g in pd.gen],
        pmin = [g.pmin for g in pd.gen],
        qmax = [g.qmax for g in pd.gen],
        qmin = [g.qmin for g in pd.gen],
        angmax = [br.angmax for br in pd.branch],
        angmin = [br.angmin for br in pd.branch],
        rate_a = [a.rate_a for a in pd.arc],
        vm0 = [b.vm for b in pd.bus],
        va0 = [b.va for b in pd.bus],
        pg0 = [g.pg for g in pd.gen],
        qg0 = [g.qg for g in pd.gen],
        pdmax = [s.charge_rating for s in pd.storage],
        pcmax = [s.discharge_rating for s in pd.storage],
        srating = [s.thermal_rating for s in pd.storage],
        emax = [s.energy_rating for s in pd.storage],
    )
end

# ---------------------------------------------------------------------------
# LoadSeries: dense per-period bus loads (multiperiod OPF convenience)
# ---------------------------------------------------------------------------

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
