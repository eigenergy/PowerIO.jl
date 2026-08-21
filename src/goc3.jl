"""
    parse_goc3_json(path)
    parse_goc3_json(io)
    parse_goc3_json(data)

Parse a full ARPA-E GO Challenge 3 JSON input document into the lookup tables
used by SCOPF clients. The returned named tuple includes the original string
keyed JSON object as `raw`. To parse the static network into a `BalancedNetwork`,
use `parse_file(path; from="goc3-json")`.
"""
function parse_goc3_json(input)::NamedTuple
    data = if input isa AbstractDict
        input
    elseif input isa IO
        JSON3.read(read(input, String), Dict{String,Any})
    else
        JSON3.read(read(String(input), String), Dict{String,Any})
    end
    return _goc3_json_tables(data)
end

function _goc3_json_tables(data::AbstractDict)::NamedTuple
    network = _goc3_required_object(data, "network")
    time_series = _goc3_required_object(data, "time_series_input")
    general = _goc3_required_object(time_series, "general")

    dt = _goc3_required(general, "interval_duration")
    periods = 1:_goc3_required(general, "time_periods")
    length(dt) == length(periods) ||
        error("PowerIO.parse_goc3_json: interval_duration length does not match time_periods")

    bus_items = _goc3_required_section(network, "bus")
    bus_lookup = _goc3_lookup(bus_items)
    shunt_lookup = _goc3_lookup(_goc3_section(network, "shunt"))
    ac_line_lookup = _goc3_lookup(_goc3_section(network, "ac_line"))
    twt_lookup = _goc3_lookup(_goc3_section(network, "two_winding_transformer"))
    dc_line_lookup = _goc3_lookup(_goc3_section(network, "dc_line"))

    sdd_lookup = _goc3_lookup(_goc3_required_section(network, "simple_dispatchable_device"))
    sdd_ts_lookup =
        _goc3_lookup(_goc3_required_section(time_series, "simple_dispatchable_device"))

    azr_key = "active_zonal_reserve"
    rzr_key = "reactive_zonal_reserve"
    azr_lookup = _goc3_lookup(_goc3_section(network, azr_key))
    azr_ts_lookup = _goc3_lookup(_goc3_section(time_series, azr_key))
    rzr_lookup = _goc3_lookup(_goc3_section(network, rzr_key))
    rzr_ts_lookup = _goc3_lookup(_goc3_section(time_series, rzr_key))

    return (
        raw = data,
        dt = dt,
        periods = periods,
        bus_lookup = bus_lookup,
        bus_id_by_uid = _goc3_bus_id_by_uid(bus_items),
        bus_ids = _goc3_ids(bus_lookup),
        shunt_lookup = shunt_lookup,
        shunt_ids = _goc3_ids(shunt_lookup),
        ac_line_lookup = ac_line_lookup,
        ac_line_ids = _goc3_ids(ac_line_lookup),
        twt_lookup = twt_lookup,
        twt_ids = _goc3_ids(twt_lookup),
        dc_line_lookup = dc_line_lookup,
        dc_line_ids = _goc3_ids(dc_line_lookup),
        sdd_lookup = sdd_lookup,
        sdd_ts_lookup = sdd_ts_lookup,
        sdd_ids = _goc3_ids(sdd_lookup),
        sdd_ids_producer = sort([
            uid for (uid, item) in sdd_lookup if get(item, "device_type", nothing) == "producer"
        ]),
        sdd_ids_consumer = sort([
            uid for (uid, item) in sdd_lookup if get(item, "device_type", nothing) == "consumer"
        ]),
        violation_cost = _goc3_required_object(network, "violation_cost"),
        azr_lookup = azr_lookup,
        azr_ts_lookup = azr_ts_lookup,
        azr_ids = _goc3_ids(azr_lookup),
        rzr_lookup = rzr_lookup,
        rzr_ts_lookup = rzr_ts_lookup,
        rzr_ids = _goc3_ids(rzr_lookup),
    )
end

function _goc3_required(obj::AbstractDict, key::AbstractString)
    haskey(obj, key) || error("PowerIO.parse_goc3_json: missing `$key`")
    return obj[key]
end

function _goc3_required_object(obj::AbstractDict, key::AbstractString)
    value = _goc3_required(obj, key)
    value isa AbstractDict ||
        error("PowerIO.parse_goc3_json: `$key` must be an object")
    return value
end

function _goc3_required_section(obj::AbstractDict, key::AbstractString)
    value = _goc3_required(obj, key)
    value isa AbstractVector ||
        error("PowerIO.parse_goc3_json: `$key` must be an array")
    return value
end

function _goc3_section(obj::AbstractDict, key::AbstractString)
    value = get(obj, key, Any[])
    value isa AbstractVector ||
        error("PowerIO.parse_goc3_json: `$key` must be an array")
    return value
end

function _goc3_lookup(items)
    lookup = Dict{String,Any}()
    for item in items
        item isa AbstractDict ||
            error("PowerIO.parse_goc3_json: section item must be an object")
        uid = get(item, "uid", nothing)
        uid isa AbstractString ||
            error("PowerIO.parse_goc3_json: section item missing string `uid`")
        haskey(lookup, uid) &&
            error("PowerIO.parse_goc3_json: duplicate uid `$uid`")
        lookup[uid] = item
    end
    return lookup
end

_goc3_ids(lookup::AbstractDict) = sort(collect(keys(lookup)))

function _goc3_bus_id_by_uid(items)
    uids = String[]
    for item in items
        item isa AbstractDict ||
            error("PowerIO.parse_goc3_json: bus section item must be an object")
        uid = get(item, "uid", nothing)
        uid isa AbstractString ||
            error("PowerIO.parse_goc3_json: bus section item missing string `uid`")
        push!(uids, uid)
    end

    suffixes = Union{Nothing,Int}[_goc3_official_bus_suffix(uid) for uid in uids]
    use_suffixes = all(!isnothing, suffixes) &&
        length(unique(Int.(suffixes))) == length(suffixes)
    ids = use_suffixes ? Int.(suffixes) .+ 1 : collect(1:length(uids))
    return Dict(uid => id for (uid, id) in zip(uids, ids))
end

function _goc3_official_bus_suffix(uid::AbstractString)
    m = match(r"^bus_(\d+)$", uid)
    return m === nothing ? nothing : parse(Int, m.captures[1])
end

"""
    goc3_status_flags(on_status, initial_on_status)

Return `(on_status, su_status, sd_status)` vectors using the GO Challenge 3
unit commitment transition convention used by ExaModelsPower.
"""
function goc3_status_flags(on_status, initial_on_status)
    n = length(on_status)
    su_status = zeros(Int, n)
    sd_status = zeros(Int, n)
    on = Int.(on_status)
    initial = Int(initial_on_status)

    if n > 0
        if initial == 0 && on[1] == 1
            su_status[1] = 1
        elseif initial == 1 && on[1] == 0
            sd_status[1] = 1
        end
    end

    for i in 1:(n - 1)
        if on[i] == 0 && on[i + 1] == 1
            su_status[i + 1] = 1
        end
        if on[i] == 1 && on[i + 1] == 0
            sd_status[i + 1] = 1
        end
    end

    return (on_status = on, su_status = su_status, sd_status = sd_status)
end

"""
    goc3_add_status_flags!(uc_data, lookup)

Mutate UC output rows by adding `su_status` and `sd_status` from each row's
`on_status` and the matching input table row's `initial_status.on_status`.
"""
function goc3_add_status_flags!(uc_data, lookup)
    return _add_status_flags!(uc_data, uid -> lookup[uid]["initial_status"]["on_status"])
end

# The typed sibling: `rows` are [`ScopfInstance`](@ref) rows carrying `u_0`
# (device, AC line, or transformer rows), so no raw lookup is read.
function goc3_add_status_flags!(uc_data, rows::AbstractVector{<:NamedTuple})
    initial = Dict{String,Int}(String(r.uid) => r.u_0 for r in rows)
    return _add_status_flags!(uc_data, uid -> initial[uid])
end

function _add_status_flags!(uc_data, initial_for)
    for row in uc_data
        flags = goc3_status_flags(row["on_status"], initial_for(String(row["uid"])))
        row["on_status"] = flags.on_status
        row["su_status"] = flags.su_status
        row["sd_status"] = flags.sd_status
    end
    return uc_data
end

# ---------------------------------------------------------------------------
# GO Challenge 3 indexing helpers
#
# These helpers expose document-order bus and interval calculations used by
# security-constrained OPF clients. The typed SCOPF rows below come from the
# Rust instance document. A client adds any model-specific stacked variable
# numbering; nothing here depends on a unit commitment solution or model state.
# ---------------------------------------------------------------------------

"""
    goc3_bus_id(data, uid) -> Int

Map a GOC3 bus `uid` to its 1-based row index in the parsed bus table, using the
`bus_id_by_uid` lookup built by [`parse_goc3_json`](@ref). The result indexes
`data.bus_lookup` and the per-bus vectors the SCOPF index-set builders return.
"""
goc3_bus_id(data, uid::AbstractString) = data.bus_id_by_uid[String(uid)]


"""
    goc3_interval_bounds(dt, t)

Return `(a_start, a_mid, a_end)` for interval `t` given interval durations `dt`.
"""
function goc3_interval_bounds(dt, t)
    a_end = sum(dt[1:t])
    a_start = a_end - dt[t]
    a_mid = (a_start + a_end) / 2
    return a_start, a_mid, a_end
end

# ---------------------------------------------------------------------------
# Typed rows over the Rust instance document (`parse_scopf` /
# `pio_scopf_to_json_with_index_base`). One GOC3 SCOPF implementation builds
# the index sets —
# the Rust core's, with document-order enumeration behind every ordinal — and
# this section only types its rows.
# ---------------------------------------------------------------------------

# `nothing` at a Float64 position is NaN: the parameters of an undeclared
# reactive capability mode and the absent violation prices, exactly the NaN
# convention the rows document.
_scopf_field(::Type{Float64}, v) = v === nothing ? NaN : Float64(v)
_scopf_field(::Type{Int}, v) = Int(v)
_scopf_field(::Type{String}, v) = String(v)
_scopf_field(::Type{Vector{Float64}}, v) = Float64[_scopf_field(Float64, x) for x in v]
_scopf_field(::Type{Vector{Vector{Float64}}}, v) =
    Vector{Float64}[_scopf_field(Vector{Float64}, x) for x in v]

# One typed row off a document object, by declared field name. `Val` unrolls
# the tuple so every `fieldtype` resolves at compile time and the row stays
# concrete (the same reason the row types are declared at all).
@inline function _scopf_row(::Type{NT}, obj) where {NT<:NamedTuple}
    names = fieldnames(NT)
    return NT(ntuple(
        i -> _scopf_field(fieldtype(NT, i), getproperty(obj, names[i])),
        Val(length(names)),
    ))
end
_scopf_rows(::Type{NT}, objs) where {NT<:NamedTuple} = NT[_scopf_row(NT, o) for o in objs]
_scopf_nested(::Type{NT}, groups) where {NT<:NamedTuple} =
    Vector{NT}[_scopf_rows(NT, g) for g in groups]

# The row layouts, matching the document (and the Rust structs behind it)
# field for field. `j_dev` is the device's position within its own class,
# `j_sdd` its position in the canonical stacking (producers then consumers),
# both document order; `u_0` is the document's `initial_status.on_status`.
const _ScopfBusRow = @NamedTuple{i::Int, uid::String, v_min::Float64, v_max::Float64}
const _ScopfShuntRow = @NamedTuple{j_sh::Int, uid::String, bus::Int, g_sh::Float64, b_sh::Float64}
const _ScopfAclRow = @NamedTuple{j_ln::Int, uid::String, to_bus::Int, fr_bus::Int, c_su::Float64, c_sd::Float64, u_0::Int, s_max::Float64, g_sr::Float64, b_sr::Float64, b_ch::Float64, g_fr::Float64, g_to::Float64, b_fr::Float64, b_to::Float64}
const _ScopfAcxRow = @NamedTuple{j_xf::Int, uid::String, to_bus::Int, fr_bus::Int, c_su::Float64, c_sd::Float64, u_0::Int, s_max::Float64, g_sr::Float64, b_sr::Float64, b_ch::Float64, g_fr::Float64, g_to::Float64, b_fr::Float64, b_to::Float64}
const _ScopfDcRow = @NamedTuple{j_dc::Int, uid::String, pdc_max::Float64, qdc_fr_min::Float64, qdc_to_min::Float64, qdc_fr_max::Float64, qdc_to_max::Float64, to_bus::Int, fr_bus::Int}
const _ScopfVpdRow = @NamedTuple{j_xf::Int, phi_min::Float64, phi_max::Float64}
const _ScopfFpdRow = @NamedTuple{j_xf::Int, phi_o::Float64}
const _ScopfVwrRow = @NamedTuple{j_xf::Int, tau_min::Float64, tau_max::Float64}
const _ScopfFwrRow = @NamedTuple{j_xf::Int, tau_o::Float64}
const _ScopfSddRow = @NamedTuple{bus::Int, uid::String, j_dev::Int, j_sdd::Int, c_on::Float64, c_su::Float64, c_sd::Float64, p_ru::Float64, p_rd::Float64, p_ru_su::Float64, p_rd_sd::Float64, c_rgu::Vector{Float64}, c_rgd::Vector{Float64}, c_scr::Vector{Float64}, c_nsc::Vector{Float64}, c_rru_on::Vector{Float64}, c_rru_off::Vector{Float64}, c_rrd_on::Vector{Float64}, c_rrd_off::Vector{Float64}, c_qru::Vector{Float64}, c_qrd::Vector{Float64}, p_rgu_max::Float64, p_rgd_max::Float64, p_scr_max::Float64, p_nsc_max::Float64, p_rru_on_max::Float64, p_rru_off_max::Float64, p_rrd_on_max::Float64, p_rrd_off_max::Float64, p_0::Float64, q_0::Float64, u_0::Int, p_max::Vector{Float64}, p_min::Vector{Float64}, q_max::Vector{Float64}, q_min::Vector{Float64}, sus::Vector{Vector{Float64}}, q_bound_cap::Int, q_linear_cap::Int, beta_ub::Float64, beta_lb::Float64, q_0_ub::Float64, q_0_lb::Float64, beta::Float64, q_p0::Float64}
const _ScopfActiveReserveRow = @NamedTuple{n_p::Int, uid::String, c_rgu::Float64, c_rgd::Float64, c_scr::Float64, c_nsc::Float64, c_rru::Float64, c_rrd::Float64, σ_rgu::Float64, σ_rgd::Float64, σ_scr::Float64, σ_nsc::Float64, p_rru_min::Vector{Float64}, p_rrd_min::Vector{Float64}}
const _ScopfReactiveReserveRow = @NamedTuple{n_q::Int, uid::String, c_qru::Float64, c_qrd::Float64, q_qru_min::Vector{Float64}, q_qrd_min::Vector{Float64}}
const _ScopfActiveReserveSetRow = @NamedTuple{i::Int, n_p::Int, uid::String, j_dev::Int, j_sdd::Int}
const _ScopfReactiveReserveSetRow = @NamedTuple{i::Int, n_q::Int, uid::String, j_dev::Int, j_sdd::Int}
const _ScopfLengths = @NamedTuple{L_J_xf::Int, L_J_ln::Int, L_J_ac::Int, L_J_dc::Int, L_J_br::Int, L_J_cs::Int, L_J_pr::Int, L_J_cspr::Int, L_J_sh::Int, I::Int, L_T::Int, L_N_p::Int, L_N_q::Int, K::Int}
const _ScopfPriceBlockRow = @NamedTuple{flat_k::Int, uid::String, t::Int, m::Int, c_en::Float64, p_max::Float64}
const _ScopfLnSurvivorRow = @NamedTuple{ctg::Int, j_ln::Int, uid::String, to_bus::Int, fr_bus::Int, b_sr::Float64, s_max_ctg::Float64}
const _ScopfXfSurvivorRow = @NamedTuple{ctg::Int, j_xf::Int, uid::String, to_bus::Int, fr_bus::Int, b_sr::Float64, s_max_ctg::Float64}
const _ScopfDcFlowRow = @NamedTuple{flat_jtk_dc::Int, ctg::Int, j_dc::Int, to_bus::Int, fr_bus::Int, t::Int, dt::Float64}
const _ScopfWinMaxPrRow = @NamedTuple{w_en_max_pr_ind::Int, uid::String, a_en_max_start::Float64, a_en_max_end::Float64, e_max::Float64}
const _ScopfWinMaxCsRow = @NamedTuple{w_en_max_cs_ind::Int, uid::String, a_en_max_start::Float64, a_en_max_end::Float64, e_max::Float64}
const _ScopfWinMinPrRow = @NamedTuple{w_en_min_pr_ind::Int, uid::String, a_en_min_start::Float64, a_en_min_end::Float64, e_min::Float64}
const _ScopfWinMinCsRow = @NamedTuple{w_en_min_cs_ind::Int, uid::String, a_en_min_start::Float64, a_en_min_end::Float64, e_min::Float64}
const _ScopfWinTMaxPrRow = @NamedTuple{w_en_max_pr_ind::Int, uid::String, t::Int, dt::Float64}
const _ScopfWinTMaxCsRow = @NamedTuple{w_en_max_cs_ind::Int, uid::String, t::Int, dt::Float64}
const _ScopfWinTMinPrRow = @NamedTuple{w_en_min_pr_ind::Int, uid::String, t::Int, dt::Float64}
const _ScopfWinTMinCsRow = @NamedTuple{w_en_min_cs_ind::Int, uid::String, t::Int, dt::Float64}

"""
    DeviceClassLayout

How the two device classes sit in the document's
`simple_dispatchable_device` section: `kind` is `:contiguous` (each class one
unbroken run; `producers_first` says which starts first) or `:interleaved`
(`producers_first` is `nothing` — no per-class offset scheme holds). The
ordinals on the rows (`j_dev`, `j_sdd`) are sound either way; this type only
reports the document's shape.
"""
struct DeviceClassLayout
    kind::Symbol
    producers_first::Union{Bool,Nothing}
end

function _scopf_layout(obj)
    kind = Symbol(obj.kind)
    return DeviceClassLayout(
        kind,
        kind === :contiguous ? Bool(obj.producers_first) : nothing,
    )
end

function _scopf_instance_tables(doc)
    inst = doc.instance
    static = inst.static
    return (
        static = (
            bus = _scopf_rows(_ScopfBusRow, static.bus),
            shunt = _scopf_rows(_ScopfShuntRow, static.shunt),
            acl_branch = _scopf_rows(_ScopfAclRow, static.acl_branch),
            acx_branch = _scopf_rows(_ScopfAcxRow, static.acx_branch),
            vpd = _scopf_rows(_ScopfVpdRow, static.vpd),
            fpd = _scopf_rows(_ScopfFpdRow, static.fpd),
            vwr = _scopf_rows(_ScopfVwrRow, static.vwr),
            fwr = _scopf_rows(_ScopfFwrRow, static.fwr),
            dc_branch = _scopf_rows(_ScopfDcRow, static.dc_branch),
            prod = _scopf_rows(_ScopfSddRow, static.prod),
            cons = _scopf_rows(_ScopfSddRow, static.cons),
            active_reserve = _scopf_rows(_ScopfActiveReserveRow, static.active_reserve),
            reactive_reserve = _scopf_rows(_ScopfReactiveReserveRow, static.reactive_reserve),
            active_reserve_set_pr = _scopf_rows(_ScopfActiveReserveSetRow, static.active_reserve_set_pr),
            active_reserve_set_cs = _scopf_rows(_ScopfActiveReserveSetRow, static.active_reserve_set_cs),
            reactive_reserve_set_pr = _scopf_rows(_ScopfReactiveReserveSetRow, static.reactive_reserve_set_pr),
            reactive_reserve_set_cs = _scopf_rows(_ScopfReactiveReserveSetRow, static.reactive_reserve_set_cs),
        ),
        lengths = _scopf_row(_ScopfLengths, inst.lengths),
        energy_windows = (
            W_en_max_pr = _scopf_rows(_ScopfWinMaxPrRow, inst.energy_windows.W_en_max_pr),
            W_en_max_cs = _scopf_rows(_ScopfWinMaxCsRow, inst.energy_windows.W_en_max_cs),
            W_en_min_pr = _scopf_rows(_ScopfWinMinPrRow, inst.energy_windows.W_en_min_pr),
            W_en_min_cs = _scopf_rows(_ScopfWinMinCsRow, inst.energy_windows.W_en_min_cs),
            T_w_en_max_pr = _scopf_rows(_ScopfWinTMaxPrRow, inst.energy_windows.T_w_en_max_pr),
            T_w_en_max_cs = _scopf_rows(_ScopfWinTMaxCsRow, inst.energy_windows.T_w_en_max_cs),
            T_w_en_min_pr = _scopf_rows(_ScopfWinTMinPrRow, inst.energy_windows.T_w_en_min_pr),
            T_w_en_min_cs = _scopf_rows(_ScopfWinTMinCsRow, inst.energy_windows.T_w_en_min_cs),
        ),
        price_blocks = (
            producer = _scopf_rows(_ScopfPriceBlockRow, inst.price_blocks.producer),
            consumer = _scopf_rows(_ScopfPriceBlockRow, inst.price_blocks.consumer),
        ),
        ac_contingency_survivors = (
            ln = _scopf_nested(_ScopfLnSurvivorRow, inst.ac_contingency_survivors.ln),
            xf = _scopf_nested(_ScopfXfSurvivorRow, inst.ac_contingency_survivors.xf),
        ),
        dc_contingency_flows = _scopf_rows(_ScopfDcFlowRow, inst.dc_contingency_flows),
        violation_cost = (
            p_bus = _scopf_field(Float64, inst.violation_cost.p_bus),
            q_bus = _scopf_field(Float64, inst.violation_cost.q_bus),
            s = _scopf_field(Float64, inst.violation_cost.s),
            e = _scopf_field(Float64, inst.violation_cost.e),
        ),
        device_class_layout = _scopf_layout(inst.device_class_layout),
        dt = _scopf_field(Vector{Float64}, inst.dt),
    )
end

"""
    ScopfInstance

A derived, format-neutral security-constrained OPF instance: the typed-row view of the
Rust core's `ScopfInstance` (`powerio-prob`, over [`parse_scopf`](@ref)), and the SCOPF
analog of the DC-OPF `OpfInstance` (`powerio-matrix`). Every field is keyed by `uid` and
by per-class document-order ordinals (`j_ln`/`j_xf`/`j_dc`/`j_sh`/`n_p`/`n_q`, and on the
device rows `j_dev`/`j_sdd`), with no model-specific stacked variable index. The ordinals
come from enumeration, never from a uid spelling, so they are sound on every document,
including GOCompetition's own validation case whose uids are names. GOC3 is the input
format, not this type: like `OpfInstance`, it is a projection a client reads to build a
model, not a stored representation of a format.

Fields:
- `static`: buses, shunts, AC/DC branches, transformer control sets, producers,
  consumers, zonal reserves, and device-zone membership sets. Producer and consumer
  rows carry the reactive capability block: the mutually exclusive `q_bound_cap` and
  `q_linear_cap` flags, and the `beta_ub`/`beta_lb`/`q_0_ub`/`q_0_lb` or `beta`/`q_p0`
  parameters of whichever is set. A device may set neither, in which case every
  parameter is `NaN`; read the flags before the parameters. Those rows also carry the
  commitment ramp limits and the initial operating point under short names: `p_ru` and
  `p_rd` are the document's `p_ramp_up_ub` and `p_ramp_down_ub`, `p_ru_su` and `p_rd_sd`
  its `p_startup_ramp_ub` and `p_shutdown_ramp_ub`, `p_0` and `q_0` its `initial_status`
  `p` and `q`, and `p_max`/`p_min`/`q_max`/`q_min` the per-period `p_ub`/`p_lb`/`q_ub`/
  `q_lb` series. The rows also carry `u_0`, the document's
  `initial_status.on_status` (as do the AC line and transformer rows), and the
  ordinals `j_dev` (position within the row's own class) and `j_sdd` (position in
  the canonical stacking: producers then consumers, document order within each).
  A client building startup and shutdown power trajectories reads these rows
  instead of `sdd_lookup` and `sdd_ts_lookup`.
- `lengths`: the per-class set sizes, including the contingency count `K`.
- `energy_windows`: producer/consumer min and max energy windows and period memberships.
- `price_blocks`: `(producer, consumer)`, one row per (device, period, cost block).
- `ac_contingency_survivors`: `(ln, xf)`, per-contingency surviving AC lines/transformers.
- `dc_contingency_flows`: the flattened surviving-DC-line set.
- `violation_cost`: `(p_bus, q_bus, s, e)`, the case's four violation prices.
- `device_class_layout`: how the two device classes sit in the document's device
  section, a [`DeviceClassLayout`](@ref). The ordinals on the rows are sound either
  way; this only reports the document's shape.
- `dt`: the interval durations, so a model needs no raw-document read for its time
  axis. `lengths.L_T` is its length.
"""
struct ScopfInstance{S,L,E,P,A,D,V}
    static::S
    lengths::L
    energy_windows::E
    price_blocks::P
    ac_contingency_survivors::A
    dc_contingency_flows::D
    violation_cost::V
    device_class_layout::DeviceClassLayout
    dt::Vector{Float64}
end

# The seven type parameters make the default show unreadable. Report the case
# sizes a reader actually wants off `lengths`.
function Base.show(io::IO, s::ScopfInstance)
    n = s.lengths
    print(io, "ScopfInstance(", n.I, " buses, ", n.L_T, " periods, ", n.K,
          " contingencies, ", n.L_J_pr, " producers, ", n.L_J_cs, " consumers, ",
          n.L_J_ac, " ac branches, ", n.L_J_dc, " dc lines, ", n.L_J_sh, " shunts)")
end

"""
    goc3_scopf_data(text) -> ScopfInstance

Build the security-constrained OPF instance from GOC3 document `text` in one call.
The Rust core parses and projects the instance (`pio_scopf_parse_str`, the same
projection [`parse_scopf`](@ref) serializes; needs the `prob` feature, on in every
powerio v0.9.0 release binary) and this function types its rows. Pure
function of the text: no unit commitment solution and no model-specific variable
numbering. A client reads the [`ScopfInstance`](@ref) fields and attaches its own
stacked variable indices and UC status (see [`goc3_add_status_flags!`](@ref)); the
device ordinals `j_dev`/`j_sdd` and the layout report make every index a field read.

`text` is the document itself, never a path: string entry points do not touch the
filesystem. Read the file and pass its contents, or use `IOBuffer`/`read` at the
call site.

The Rust projection is the sole implementation and enumerates document order
everywhere. This Julia view requests index base 1, so each ordinal indexes its
corresponding Julia vector directly. Extending the general IR to carry SCOPF
inputs stays tracked in eigenergy/powerio#235.
"""
function goc3_scopf_data(text::AbstractString)
    # Request Julia-native ordinals from the core. Do not mirror the core's
    # exhaustive ordinal-field registry or shift fields in this binding.
    tables = _scopf_instance_tables(parse_scopf(text; index_base=1))
    return ScopfInstance(
        tables.static,
        tables.lengths,
        tables.energy_windows,
        tables.price_blocks,
        tables.ac_contingency_survivors,
        tables.dc_contingency_flows,
        tables.violation_cost,
        tables.device_class_layout,
        tables.dt,
    )
end
goc3_scopf_data(io::IO) = goc3_scopf_data(read(io, String))
