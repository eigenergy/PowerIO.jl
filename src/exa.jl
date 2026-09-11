# ExaModelsPower bridge: the `PowerData` row layout its model builders read,
# assembled from the element tables, and `LoadSeries` for multiperiod loads.

# A bound may be infinite (a source format spells an absent limit as Inf); any
# other field must be finite.
function _bound(x::Real, ::Type{T}, element::AbstractString, field::Symbol) where {T<:Real}
    isnan(x) && throw(ArgumentError("PowerIO.to_powerdata: $element has NaN $field"))
    return T(x)
end
function _finite(x::Real, ::Type{T}, element::AbstractString, field::Symbol) where {T<:Real}
    isfinite(x) || throw(ArgumentError("PowerIO.to_powerdata: $element has non-finite $field ($x)"))
    return T(x)
end

# Quadratic cost coefficients `(c2, c1, c0)` on the per unit power axis from a
# MATPOWER polynomial in MW.
function _quadratic_cost_coeffs(coeffs::Vector{T}, base::T) where {T<:Real}
    scaled = copy(coeffs)
    k = length(scaled)
    for i in eachindex(scaled)
        scaled[i] *= base^(k - i)
    end
    while length(scaled) > 3 && iszero(first(scaled))
        popfirst!(scaled)
    end
    length(scaled) > 3 &&
        throw(ArgumentError("PowerIO.to_powerdata: polynomial generator cost cannot fit a quadratic cost"))
    vals = [zero(T), zero(T), zero(T)]
    offset = 3 - length(scaled)
    for (i, c) in enumerate(scaled)
        vals[offset + i] = c
    end
    return vals
end

# `(model_poly, startup, shutdown, ncost, (c2, c1, c0), model)`. `model` is 0
# for a generator without a cost record and `cost.model` verbatim otherwise,
# so a consumer can tell a piecewise linear cost (1) from a polynomial one (2)
# and from an unrecognized model without reading `net.generators` again.
function _cost_tuple(g::Generator, ::Type{T}, base::T; validate::Bool=true) where {T<:Real}
    cost = g.cost
    cost === nothing && return (false, zero(T), zero(T), 0, (zero(T), zero(T), zero(T)), 0)
    if !validate
        # An out of service generator is reported with its status and is never
        # solved, so its cost record is copied without the checks a dispatched
        # row must pass.
        return (cost.model == 2, T(cost.startup), T(cost.shutdown), cost.model == 2 ? 3 : cost.ncost,
                (zero(T), zero(T), zero(T)), cost.model)
    end
    coeffs = T[_finite(c, T, "generator cost", :coefficients) for c in cost.coefficients]
    startup = _finite(cost.startup, T, "generator cost", :startup)
    shutdown = _finite(cost.shutdown, T, "generator cost", :shutdown)
    if cost.model == 2
        limit = min(cost.ncost, length(coeffs))
        vals = _quadratic_cost_coeffs(limit == 0 ? T[] : coeffs[1:limit], base)
        return (true, startup, shutdown, 3, (vals[1], vals[2], vals[3]), cost.model)
    end
    limit = cost.model == 1 ? min(2 * cost.ncost, length(coeffs)) : length(coeffs)
    vals = [zero(T), zero(T), zero(T)]
    for i in 1:min(3, limit)
        vals[i] = coeffs[i]
    end
    return (false, startup, shutdown, cost.ncost, (vals[1], vals[2], vals[3]), cost.model)
end

# A field of a row the caller will filter out by `status`: copied as stated,
# never validated, so one non-finite value in an unused row cannot refuse the
# conversion. `strict=false` extends the same treatment to in-service rows.
_stated(x::Real, ::Type{T}) where {T<:Real} = T(x)
_field(x::Real, ::Type{T}, element::AbstractString, field::Symbol, checked::Bool) where {T<:Real} =
    checked ? _finite(x, T, element, field) : _stated(x, T)
_bound_field(x::Real, ::Type{T}, element::AbstractString, field::Symbol, checked::Bool) where {T<:Real} =
    checked ? _bound(x, T, element, field) : _stated(x, T)

# The eight admittance coefficients ExaModelsPower reads per branch:
# `c1 + im*c2 = y_tf`, `c3 + im*c4 = y_ft`, `c5 + im*c6 = y_ff`, `c7 + im*c8 = y_tt`
# in MATPOWER's `makeYbus` notation, the same values `calc_branch_admittances`
# returns. A zero impedance branch reaching here is stated as an open circuit
# (the series admittance zero, the charging kept), the `zero_impedance=:open`
# path; `zero_impedance=:error` refuses it at the call site, with the branch
# and its buses named.
function _branch_coeffs(r::T, x::T, b_fr::T, b_to::T, g_fr::T, g_to::T, tap::T, shift::T) where {T<:Real}
    y = if hypot(r, x) < _MIN_DIVISIBLE_MAGNITUDE
        zero(Complex{T})
    else
        inv(complex(r, x))
    end
    isfinite(real(y)) && isfinite(imag(y)) || (y = zero(Complex{T}))
    g = real(y)
    b = imag(y)
    tr = tap * cos(shift)
    ti = tap * sin(shift)
    ttm = tr^2 + ti^2
    return ((-g * tr - b * ti) / ttm, (-b * tr + g * ti) / ttm,
            (-g * tr + b * ti) / ttm, (-b * tr - g * ti) / ttm,
            (g + g_fr) / ttm, (b + b_fr) / ttm, g + g_to, b + b_to)
end

_bus_type_code(bus_type::AbstractString) =
    bus_type == "PQ" ? 1 : bus_type == "PV" ? 2 : bus_type == "REF" ? 3 : 4

"""
    to_powerdata(net; T=Float64, strict=true, zero_impedance=:error) -> NamedTuple
    to_powerdata(m::PioModule{BalancedNetwork}; kwargs...) -> NamedTuple
    to_powerdata(path; format=nothing, kwargs...) -> NamedTuple

The network in ExaPowerIO's `PowerData` layout: `version`, `baseMVA`, `bus`,
`gen`, `branch`, `arc`, and `storage`, with the row fields ExaModelsPower reads.
Powers are per unit on `baseMVA`, angles are radians (`bus.va` included),
`bus_i` keeps the source bus id, and branch and generator bus references are
1-based positions in `bus`. Bus types are reconciled with the generator table:
a bus with an in-service generator is at least PV, a bus without one is PQ, and
when no bus is the reference the bus with the largest generator becomes it.

Every row is emitted with its `status`; the caller selects on it. Validation
runs only on rows that are in service: a field may be `Inf` only where a source
format spells an absent limit that way (generator and storage power limits,
branch ratings, and angle difference bounds), every other non-finite value is
refused with the element and field named, and a polynomial cost that cannot
fit a quadratic is refused. An out of service row is copied as stated, its
cost coefficients zero. `strict=false` copies in-service rows as stated too.

Each generator row carries `model`: 0 without a cost record, otherwise
`cost.model` verbatim (1 piecewise linear, 2 polynomial), beside `model_poly`.

Each branch row carries the eight admittance coefficients ExaModelsPower reads:
`c1 + im*c2 = y_tf`, `c3 + im*c4 = y_ft`, `c5 + im*c6 = y_ff`, and
`c7 + im*c8 = y_tt` in MATPOWER's `makeYbus` notation; see
[`calc_branch_admittances`](@ref). An in-service branch with zero series
impedance is a `PowerIOError` with code `BUILD.OPERATOR.ZERO_IMPEDANCE`
(`zero_impedance=:error`, the convention of the DC calculations and
[`calc_admittance_matrix`](@ref)); `zero_impedance=:open` states it as an open
circuit instead, `c1..c4` zero and `c5..c8` carrying the charging alone.
"""
function to_powerdata(net::BalancedNetwork; T::Type{<:Real}=Float64, strict::Bool=true,
                      zero_impedance::Symbol=:error)
    zero_impedance in (:error, :open) ||
        throw(ArgumentError("PowerIO.to_powerdata: zero_impedance must be :error or :open, got $(repr(zero_impedance))"))
    base = _finite(net.base_mva, T, "network", :base_mva)
    buses = collect(net.buses)
    bus_ids = [b.id for b in buses]
    index = Dict(id => i for (i, id) in enumerate(bus_ids))
    n = length(buses)

    pd = zeros(T, n); qd = zeros(T, n); gs = zeros(T, n); bs = zeros(T, n)
    for (k, l) in enumerate(net.loads)
        l.in_service || continue
        i = index[l.bus_id]
        pd[i] += _finite(l.p_mw, T, "load $k", :p_mw) / base
        qd[i] += _finite(l.q_mvar, T, "load $k", :q_mvar) / base
    end
    for (k, s) in enumerate(net.shunts)
        s.in_service || continue
        i = index[s.bus_id]
        gs[i] += _finite(s.conductance_mw, T, "shunt $k", :conductance_mw) / base
        bs[i] += _finite(s.susceptance_mvar, T, "shunt $k", :susceptance_mvar) / base
    end

    bus_rows = [let label = "bus $(b.id)", checked = strict
        (; i, bus_i = b.id, type = _bus_type_code(b.bus_type), pd = pd[i], qd = qd[i], gs = gs[i], bs = bs[i],
           area = b.area, vm = _field(b.vm_pu, T, label, :vm, checked),
           va = deg2rad(_field(b.va_degrees, T, label, :va, checked)),
           baseKV = _field(b.base_kv, T, label, :base_kv, checked), zone = b.zone,
           vmax = _field(b.vmax_pu, T, label, :vmax, checked), vmin = _field(b.vmin_pu, T, label, :vmin, checked))
    end for (i, b) in enumerate(buses)]

    gens = collect(net.generators)
    gen_rows = [let label = "generator $i", checked = strict && g.in_service,
                    (model_poly, startup, shutdown, ncost, c, model) = _cost_tuple(g, T, base; validate=checked)
        (; i, bus = index[g.bus_id],
           pg = _field(g.active_power_mw, T, label, :pg, checked) / base,
           qg = _field(g.reactive_power_mvar, T, label, :qg, checked) / base,
           qmax = _bound_field(g.reactive_power_max_mvar, T, label, :qmax, checked) / base,
           qmin = _bound_field(g.reactive_power_min_mvar, T, label, :qmin, checked) / base,
           vg = _field(g.voltage_setpoint_pu, T, label, :vg, checked),
           mbase = _field(g.machine_base_mva, T, label, :mbase, checked),
           status = Int(g.in_service),
           pmax = _bound_field(g.active_power_max_mw, T, label, :pmax, checked) / base,
           pmin = _bound_field(g.active_power_min_mw, T, label, :pmin, checked) / base,
           model_poly, startup, shutdown, n = ncost, c, model)
    end for (i, g) in enumerate(gens)]

    has_gen = falses(n)
    biggest_bus = 0
    biggest_pmax = typemin(T)
    for g in gens
        g.in_service || continue
        i = index[g.bus_id]
        has_gen[i] = true
        pmax = T(g.active_power_max_mw) / base
        if pmax > biggest_pmax
            biggest_pmax = pmax
            biggest_bus = i
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
    if !any(row.type == 3 for row in bus_rows) && biggest_bus > 0
        bus_rows[biggest_bus] = merge(bus_rows[biggest_bus], (; type = 3))
    end

    branches = collect(net.branches)
    m = length(branches)
    branch_rows = [let label = "branch $i", checked = strict && br.in_service
        f = index[br.from_bus_id]
        t = index[br.to_bus_id]
        tap = _field(br.effective_tap_ratio, T, label, :tap, checked)
        shift = deg2rad(_field(br.phase_shift_degrees, T, label, :shift, checked))
        r = _field(br.resistance_pu, T, label, :br_r, checked)
        x = _field(br.reactance_pu, T, label, :br_x, checked)
        b_fr = _field(br.from_susceptance_pu, T, label, :b_fr, checked)
        b_to = _field(br.to_susceptance_pu, T, label, :b_to, checked)
        g_fr = _field(br.from_conductance_pu, T, label, :g_fr, checked)
        g_to = _field(br.to_conductance_pu, T, label, :g_to, checked)
        if br.in_service && zero_impedance === :error && hypot(r, x) < _MIN_DIVISIBLE_MAGNITUDE
            throw(_zero_impedance_error(i, br.from_bus_id, br.to_bus_id))
        end
        c1, c2, c3, c4, c5, c6, c7, c8 = _branch_coeffs(r, x, b_fr, b_to, g_fr, g_to, tap, shift)
        (; i, f_bus = f, t_bus = t, br_r = r, br_x = x, b_fr, b_to, g_fr, g_to,
           rate_a = _bound_field(br.rate_a_mva, T, label, :rate_a, checked) / base,
           rate_b = _bound_field(br.rate_b_mva, T, label, :rate_b, checked) / base,
           rate_c = _bound_field(br.rate_c_mva, T, label, :rate_c, checked) / base,
           tap, shift, status = Int(br.in_service),
           angmin = deg2rad(_bound_field(br.angle_min_degrees, T, label, :angmin, checked)),
           angmax = deg2rad(_bound_field(br.angle_max_degrees, T, label, :angmax, checked)),
           f_idx = i, t_idx = i + m, c1, c2, c3, c4, c5, c6, c7, c8)
    end for (i, br) in enumerate(branches)]

    arc_rows = vcat([(; i, bus = br.f_bus, rate_a = br.rate_a) for (i, br) in enumerate(branch_rows)],
                    [(; i = i + m, bus = br.t_bus, rate_a = br.rate_a) for (i, br) in enumerate(branch_rows)])

    storage_rows = [let label = "storage $i", checked = strict && st.in_service
        (; i, storage_bus = st.bus_id,
           Pexts = _field(st.active_power_mw, T, label, :active_power_mw, checked),
           Qexts = _field(st.reactive_power_mvar, T, label, :reactive_power_mvar, checked),
           energy = _field(st.energy_mwh, T, label, :energy_mwh, checked) / base,
           energy_rating = _field(st.energy_rating_mwh, T, label, :energy_rating_mwh, checked) / base,
           charge_rating = _field(st.charge_rating_mw, T, label, :charge_rating_mw, checked) / base,
           discharge_rating = _field(st.discharge_rating_mw, T, label, :discharge_rating_mw, checked) / base,
           charge_efficiency = _field(st.charge_efficiency, T, label, :charge_efficiency, checked),
           discharge_efficiency = _field(st.discharge_efficiency, T, label, :discharge_efficiency, checked),
           thermal_rating = _field(st.thermal_rating_mva, T, label, :thermal_rating_mva, checked) / base,
           qmin = _bound_field(st.reactive_power_min_mvar, T, label, :qmin, checked) / base,
           qmax = _bound_field(st.reactive_power_max_mvar, T, label, :qmax, checked) / base,
           Zr = _field(st.resistance_pu, T, label, :resistance_pu, checked),
           Zim = _field(st.reactance_pu, T, label, :reactance_pu, checked),
           p_loss = _field(st.active_power_loss_mw, T, label, :active_power_loss_mw, checked),
           q_loss = _field(st.reactive_power_loss_mvar, T, label, :reactive_power_loss_mvar, checked),
           status = Int(st.in_service))
    end for (i, st) in enumerate(net.storage)]

    return (; version = "2", baseMVA = base, bus = bus_rows, gen = gen_rows, branch = branch_rows,
            arc = arc_rows, storage = storage_rows)
end

to_powerdata(m::PioModule{BalancedNetwork}; kwargs...) = to_powerdata(m.value; kwargs...)
function to_powerdata(path::AbstractString; format::Union{AbstractString,Nothing}=nothing, kwargs...)
    m = parse(path; format)
    m isa PioModule{BalancedNetwork} ||
        throw(ArgumentError("PowerIO.to_powerdata: $path holds a $(typeof(m.value)), not a BalancedNetwork"))
    return to_powerdata(m.value; kwargs...)
end

"""
    to_ac_power_data(net; T=Float64) -> NamedTuple
    to_ac_power_data(m::PioModule{BalancedNetwork}; T=Float64) -> NamedTuple
    to_ac_power_data(path; format=nothing, T=Float64) -> NamedTuple

The layout ExaModelsPower's `build_polar_opf`, `build_rect_opf`, and
`build_dcopf` consume: the [`to_powerdata`](@ref) tables plus the bound and
initial value vectors they read (`ref_buses`, `vmax`, `vmin`, `pmax`, `pmin`,
`qmax`, `qmin`, `angmax`, `angmin`, `rate_a`, `vm0`, `va0`, `pg0`, `qg0`, and
the storage ratings).
"""
function to_ac_power_data(net::BalancedNetwork; T::Type{<:Real}=Float64)
    pd = to_powerdata(net; T)
    return (;
        baseMVA = [pd.baseMVA], bus = pd.bus, gen = pd.gen, arc = pd.arc, branch = pd.branch,
        storage = pd.storage,
        ref_buses = [i for i in eachindex(pd.bus) if pd.bus[i].type == 3],
        vmax = [b.vmax for b in pd.bus], vmin = [b.vmin for b in pd.bus],
        pmax = [g.pmax for g in pd.gen], pmin = [g.pmin for g in pd.gen],
        qmax = [g.qmax for g in pd.gen], qmin = [g.qmin for g in pd.gen],
        angmax = [br.angmax for br in pd.branch], angmin = [br.angmin for br in pd.branch],
        rate_a = [a.rate_a for a in pd.arc],
        vm0 = [b.vm for b in pd.bus], va0 = [b.va for b in pd.bus],
        pg0 = [g.pg for g in pd.gen], qg0 = [g.qg for g in pd.gen],
        pdmax = T[s.charge_rating for s in pd.storage], pcmax = T[s.discharge_rating for s in pd.storage],
        srating = T[s.thermal_rating for s in pd.storage], emax = T[s.energy_rating for s in pd.storage],
    )
end

to_ac_power_data(m::PioModule{BalancedNetwork}; kwargs...) = to_ac_power_data(m.value; kwargs...)
function to_ac_power_data(path::AbstractString; format::Union{AbstractString,Nothing}=nothing, kwargs...)
    m = parse(path; format)
    m isa PioModule{BalancedNetwork} ||
        throw(ArgumentError("PowerIO.to_ac_power_data: $path holds a $(typeof(m.value)), not a BalancedNetwork"))
    return to_ac_power_data(m.value; kwargs...)
end

# --- LoadSeries ------------------------------------------------------------------

"""
    LoadSeries{T}

Dense per bus loads over several periods for ExaModelsPower's multiperiod OPF.
`pd` and `qd` are `n_buses` by `n_periods` matrices per unit on `base_mva`,
ordered like the network's bus table; `bus_ids[k]` is the source id of row `k`.

```julia
PowerIO.LoadSeries(net, pd_mw, qd_mw)           # rows are buses in network order, MW
PowerIO.LoadSeries(net, curve)                  # scale the base case loads per period
PowerIO.LoadSeries(net, pd_by_id, qd_by_id)     # Dict(bus_id => per period MW vector)
PowerIO.read_load_series(net, pd_path, qd_path) # the matrix form, from two files
```
"""
struct LoadSeries{T}
    pd::Matrix{T}
    qd::Matrix{T}
    bus_ids::Vector{Int}
    base_mva::T
end

"""
    n_periods(series::LoadSeries) -> Int

Number of periods in a [`LoadSeries`](@ref).
"""
n_periods(s::LoadSeries) = size(s.pd, 2)

"""
    demands_mw(series::LoadSeries) -> (; pd, qd)

The demand matrices in MW: `series.pd .* series.base_mva` and the same for `qd`.
"""
demands_mw(s::LoadSeries) = (; pd = s.pd .* s.base_mva, qd = s.qd .* s.base_mva)

Base.show(io::IO, s::LoadSeries{T}) where {T} =
    print(io, "LoadSeries{", T, "}: ", size(s.pd, 1), " buses, ", n_periods(s), " periods")

# Base MVA, bus ids, and per bus in-service demand in MW.
function _load_alignment(net::BalancedNetwork, ::Type{T}) where {T<:Real}
    base = _finite(net.base_mva, T, "network", :base_mva)
    bus_ids = [b.id for b in net.buses]
    index = Dict(id => i for (i, id) in enumerate(bus_ids))
    base_pd = zeros(T, length(bus_ids))
    base_qd = zeros(T, length(bus_ids))
    for (k, l) in enumerate(net.loads)
        l.in_service || continue
        i = index[l.bus_id]
        base_pd[i] += _finite(l.p_mw, T, "load $k", :p_mw)
        base_qd[i] += _finite(l.q_mvar, T, "load $k", :q_mvar)
    end
    return base, bus_ids, base_pd, base_qd
end

function _check_load_matrix(pd_mw::AbstractMatrix, qd_mw::AbstractMatrix, nbus::Int)
    size(pd_mw) == size(qd_mw) ||
        throw(DimensionMismatch("LoadSeries: Pd is $(size(pd_mw)) but Qd is $(size(qd_mw))"))
    size(pd_mw, 1) == nbus ||
        throw(DimensionMismatch("LoadSeries: load matrix has $(size(pd_mw, 1)) rows but the network has " *
                                "$nbus buses (rows must be buses in the network's order)"))
    return nothing
end

function _perunit(x_mw::AbstractMatrix, base::T) where {T<:Real}
    out = Matrix{T}(undef, size(x_mw))
    @inbounds for j in axes(x_mw, 2), i in axes(x_mw, 1)
        v = T(x_mw[i, j]) / base
        isfinite(v) || throw(ArgumentError("LoadSeries: non-finite load at bus row $i, period $j"))
        out[i, j] = v
    end
    return out
end

"""
    LoadSeries(net::BalancedNetwork, pd_mw::AbstractMatrix, qd_mw::AbstractMatrix; T=Float64)

Build a series from load matrices in MW, `n_buses` by `n_periods`, whose rows
are the buses in `net`'s order.
"""
function LoadSeries(net::BalancedNetwork, pd_mw::AbstractMatrix, qd_mw::AbstractMatrix; T::Type{<:Real}=Float64)
    base, bus_ids, _, _ = _load_alignment(net, T)
    _check_load_matrix(pd_mw, qd_mw, length(bus_ids))
    return LoadSeries{T}(_perunit(pd_mw, base), _perunit(qd_mw, base), bus_ids, base)
end

"""
    LoadSeries(net::BalancedNetwork, curve::AbstractVector; T=Float64)

Build a series by scaling the base case bus loads by `curve[t]` in each period.
Bus shunts are not scaled.
"""
function LoadSeries(net::BalancedNetwork, curve::AbstractVector; T::Type{<:Real}=Float64)
    isempty(curve) && throw(ArgumentError("LoadSeries: curve must have at least one period"))
    base, bus_ids, base_pd, base_qd = _load_alignment(net, T)
    c = T[T(x) for x in curve]
    all(isfinite, c) || throw(ArgumentError("LoadSeries: curve has a non-finite multiplier"))
    return LoadSeries{T}(base_pd * transpose(c) ./ base, base_qd * transpose(c) ./ base, bus_ids, base)
end

"""
    LoadSeries(net::BalancedNetwork, pd_by_id::AbstractDict, qd_by_id::AbstractDict; T=Float64)

Build a series from id keyed load tables: each dictionary maps a source bus id
to its per period MW vector. Every bus in `net` must have an entry and all
vectors must share one length.
"""
function LoadSeries(net::BalancedNetwork, pd_by_id::AbstractDict, qd_by_id::AbstractDict; T::Type{<:Real}=Float64)
    base, bus_ids, _, _ = _load_alignment(net, T)
    pd = _matrix_from_id_table(pd_by_id, bus_ids, :Pd, T)
    qd = _matrix_from_id_table(qd_by_id, bus_ids, :Qd, T)
    _check_load_matrix(pd, qd, length(bus_ids))
    return LoadSeries{T}(_perunit(pd, base), _perunit(qd, base), bus_ids, base)
end

function _matrix_from_id_table(by_id::AbstractDict, bus_ids::Vector{Int}, which::Symbol, ::Type{T}) where {T<:Real}
    isempty(bus_ids) &&
        throw(ArgumentError("LoadSeries: cannot build $which from an id table for a network with no buses"))
    nper = -1
    for id in bus_ids
        haskey(by_id, id) || throw(ArgumentError("LoadSeries: $which has no entry for bus $id"))
        len = length(by_id[id])
        nper == -1 && (nper = len)
        len == nper || throw(DimensionMismatch("LoadSeries: $which vectors have unequal lengths ($nper vs $len)"))
    end
    out = Matrix{T}(undef, length(bus_ids), nper)
    for (k, id) in enumerate(bus_ids)
        out[k, :] .= by_id[id]
    end
    return out
end

"""
    read_load_series(net::BalancedNetwork, pd_path, qd_path; T=Float64)

Read two whitespace delimited MW load matrices (rows are buses in `net`'s
order, columns are periods) into a [`LoadSeries`](@ref). The files hold MW; the
series holds per unit; [`demands_mw`](@ref) converts back.
"""
function read_load_series(net::BalancedNetwork, pd_path::AbstractString, qd_path::AbstractString;
                          T::Type{<:Real}=Float64)
    return LoadSeries(net, _read_load_file(pd_path), _read_load_file(qd_path); T)
end

function _read_load_file(path::AbstractString)
    isfile(path) || throw(ArgumentError("LoadSeries: load file not found: $path"))
    rows = Vector{Vector{Float64}}()
    ncol = -1
    for (lineno, line) in enumerate(eachline(path))
        fields = split(line)
        isempty(fields) && continue
        vals = Float64[Base.parse(Float64, f) for f in fields]
        ncol == -1 && (ncol = length(vals))
        length(vals) == ncol ||
            throw(DimensionMismatch("LoadSeries: $path row $lineno has $(length(vals)) values, expected $ncol"))
        push!(rows, vals)
    end
    isempty(rows) && throw(ArgumentError("LoadSeries: $path has no load rows"))
    return permutedims(reduce(hcat, rows))
end
