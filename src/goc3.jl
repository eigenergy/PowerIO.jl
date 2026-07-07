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
    for row in uc_data
        uid = row["uid"]
        input = lookup[uid]
        initial = input["initial_status"]["on_status"]
        flags = goc3_status_flags(row["on_status"], initial)
        row["on_status"] = flags.on_status
        row["su_status"] = flags.su_status
        row["sd_status"] = flags.sd_status
    end
    return uc_data
end

# ---------------------------------------------------------------------------
# GO Challenge 3 static index-set construction (SCOPF)
#
# The functions below build the general topology and time-series index sets
# consumed by security-constrained OPF clients. Rows are keyed by `uid` and by
# per-class GOC3 orderings (position within the AC-line, transformer, DC-line,
# shunt, and reserve-zone lists). The stacked global variable numbering a
# specific optimization model lays on top of these (the `j`/`j_pr`/`j_cs`/
# `j_prcs`/`j_sh` offsets into one variable vector) is model-specific and is
# threaded on by the client, not here. Nothing below depends on a unit
# commitment solution or on model state.
# ---------------------------------------------------------------------------

"""
    goc3_bus_id(data, uid) -> Int

Map a GOC3 bus `uid` to its 1-based row index in the parsed bus table, using the
`bus_id_by_uid` lookup built by [`parse_goc3_json`](@ref). The result indexes
`data.bus_lookup` and the per-bus vectors the SCOPF index-set builders return.
"""
goc3_bus_id(data, uid::AbstractString) = data.bus_id_by_uid[String(uid)]

# Trailing integer of a GOC3 uid (e.g. "acl_07" -> 7). Used to build per-class
# GOC3 orderings without recomputing the match at each sort comparison.
_uidnum(uid) = parse(Int, match(r"\d+", String(uid)).match)
_uidnum_order(ids) = sort(String.(ids), by = _uidnum)
_float_vector(xs) = Float64.(xs)
_float_matrix(xss) = Vector{Float64}[_float_vector(xs) for xs in xss]
_float_cube(xsss) = Vector{Vector{Float64}}[_float_matrix(xss) for xss in xsss]
_typed_empty(rows, empty_rows) = isempty(rows) ? empty_rows : rows

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

"""
    goc3_static_data(data)

Build the static SCOPF index sets from a `parse_goc3_json` result. Returns
`(sc_data, lengths, cost_vector_pr, cost_vector_cs)` where `sc_data` is the
named tuple of buses, shunts, AC/DC branches, transformer control sets,
producers, consumers, zonal reserves, and device-zone membership sets. Pure
function of `data`; no unit commitment solution is used.
"""
function goc3_static_data(data)
    L_J_xf = length(data.twt_lookup)
    L_J_ln = length(data.ac_line_lookup)
    L_J_ac = L_J_ln + L_J_xf
    L_J_dc = length(data.dc_line_lookup)
    L_J_br =  L_J_ac + L_J_dc
    L_J_cs = length(data.sdd_ids_consumer)
    L_J_pr = length(data.sdd_ids_producer)
    L_J_cspr = L_J_cs + L_J_pr
    L_J_sh = length(data.shunt_lookup)
    L_N_p = length(data.azr_lookup)
    L_N_q = length(data.rzr_lookup)
    I  = length(data.bus_lookup)
    L_T = length(data.dt)

    lengths = (L_J_xf=L_J_xf, L_J_ln=L_J_ln, L_J_ac=L_J_ac, L_J_dc=L_J_dc, L_J_br=L_J_br, L_J_cs=L_J_cs,
    L_J_pr=L_J_pr, L_J_cspr = L_J_cspr, L_J_sh=L_J_sh, I=I, L_T=L_T, L_N_p, L_N_q)

    CostRow = @NamedTuple{bus::Int, uid::String, cost::Vector{Vector{Vector{Float64}}}}
    BusRow = @NamedTuple{i::Int, uid::String, v_min::Float64, v_max::Float64}
    EmptyShuntRow = @NamedTuple{uid::String, bus::Int, g_sh::Float64, b_sh::Float64}
    EmptyAclRow = @NamedTuple{j_ln::Int, uid::String, to_bus::Int, fr_bus::Int, c_su::Float64, c_sd::Float64, s_max::Float64, g_sr::Float64, b_sr::Float64, b_ch::Float64, g_fr::Float64, g_to::Float64, b_fr::Float64, b_to::Float64}
    EmptyAcxRow = @NamedTuple{j_xf::Int, uid::String, to_bus::Int, fr_bus::Int, c_su::Float64, c_sd::Float64, s_max::Float64, g_sr::Float64, b_sr::Float64, b_ch::Float64, g_fr::Float64, g_to::Float64, b_fr::Float64, b_to::Float64}
    EmptyDcRow = @NamedTuple{j_dc::Int, uid::String, pdc_max::Float64, qdc_fr_min::Float64, qdc_to_min::Float64, qdc_fr_max::Float64, qdc_to_max::Float64, to_bus::Int, fr_bus::Int}
    SddRow = @NamedTuple{bus::Int, uid::String, c_on::Float64, c_su::Float64, c_sd::Float64, p_ru::Float64, p_rd::Float64, p_ru_su::Float64, p_rd_sd::Float64, c_rgu::Vector{Float64}, c_rgd::Vector{Float64}, c_scr::Vector{Float64}, c_nsc::Vector{Float64}, c_rru_on::Vector{Float64}, c_rru_off::Vector{Float64}, c_rrd_on::Vector{Float64}, c_rrd_off::Vector{Float64}, c_qru::Vector{Float64}, c_qrd::Vector{Float64}, p_rgu_max::Float64, p_rgd_max::Float64, p_scr_max::Float64, p_nsc_max::Float64, p_rru_on_max::Float64, p_rru_off_max::Float64, p_rrd_on_max::Float64, p_rrd_off_max::Float64, p_0::Float64, q_0::Float64, p_max::Vector{Float64}, p_min::Vector{Float64}, q_max::Vector{Float64}, q_min::Vector{Float64}, sus::Vector{Vector{Float64}}}
    EmptyActiveReserveRow = @NamedTuple{n_p::Int, uid::String, c_rgu::Float64, c_rgd::Float64, c_scr::Float64, c_nsc::Float64, c_rru::Float64, c_rrd::Float64, σ_rgu::Float64, σ_rgd::Float64, σ_scr::Float64, σ_nsc::Float64, p_rru_min::Vector{Float64}, p_rrd_min::Vector{Float64}}
    EmptyReactiveReserveRow = @NamedTuple{n_q::Int, uid::String, c_qru::Float64, c_qrd::Float64, q_qru_min::Vector{Float64}, q_qrd_min::Vector{Float64}}
    ActiveReserveSetRow = @NamedTuple{i::Int, n_p::Int, uid::String}
    ReactiveReserveSetRow = @NamedTuple{i::Int, n_q::Int, uid::String}

    bus_order = sort(String.(data.bus_ids), by = uid -> goc3_bus_id(data, uid))
    sdd_order = _uidnum_order(data.sdd_ids)
    _by_uidnum(rows) = rows[sortperm([_uidnum(r.uid) for r in rows])]

    function cost_vector(device_type)
        return CostRow[
            let val = data.sdd_lookup[uid]
                (bus = goc3_bus_id(data, val["bus"]), uid = String(val["uid"]),
                 cost = _float_cube(data.sdd_ts_lookup[uid]["cost"]))
            end
            for uid in sdd_order if data.sdd_lookup[uid]["device_type"] == device_type
        ]
    end
    cost_vector_pr = cost_vector("producer")
    cost_vector_cs = cost_vector("consumer")

    # One transformer control set (variable/fixed phase or winding ratio). `pred`
    # selects the transformers; `extract` returns the set-specific fields. The
    # typed comprehension fixes the element type even when the set is empty.
    function twt_control_set(::Type{R}, pred, extract) where {R}
        rows = R[
            let val = data.twt_lookup[uid], j_xf = _uidnum(uid) + 1
                (; j_xf = j_xf, extract(val)...)
            end
            for uid in _uidnum_order(data.twt_ids) if pred(data.twt_lookup[uid])
        ]
        return sort(rows, by = x -> x.j_xf)
    end

    # One simple dispatchable device row. Producers and consumers share this
    # layout; the caller filters `sdd_lookup` by device_type.
    function sdd_row(key, val)
        ts_val = data.sdd_ts_lookup[key]
        bus = goc3_bus_id(data, val["bus"])
        uid = String(val["uid"])
        c_on = Float64(val["on_cost"])
        c_su = Float64(val["startup_cost"])
        c_sd = Float64(val["shutdown_cost"])
        p_ru = Float64(val["p_ramp_up_ub"])
        p_rd = Float64(val["p_ramp_down_ub"])
        p_ru_su = Float64(val["p_startup_ramp_ub"])
        p_rd_sd = Float64(val["p_shutdown_ramp_ub"])
        c_rgu = _float_vector(ts_val["p_reg_res_up_cost"])
        c_rgd = _float_vector(ts_val["p_reg_res_down_cost"])
        c_scr = _float_vector(ts_val["p_syn_res_cost"])
        c_nsc = _float_vector(ts_val["p_nsyn_res_cost"])
        c_rru_on = _float_vector(ts_val["p_ramp_res_up_online_cost"])
        c_rru_off = _float_vector(ts_val["p_ramp_res_up_offline_cost"])
        c_rrd_on = _float_vector(ts_val["p_ramp_res_down_online_cost"])
        c_rrd_off = _float_vector(ts_val["p_ramp_res_down_offline_cost"])
        c_qru = _float_vector(ts_val["q_res_up_cost"])
        c_qrd = _float_vector(ts_val["q_res_down_cost"])
        p_rgu_max = Float64(val["p_reg_res_up_ub"])
        p_rgd_max = Float64(val["p_reg_res_down_ub"])
        p_scr_max = Float64(val["p_syn_res_ub"])
        p_nsc_max = Float64(val["p_nsyn_res_ub"])
        p_rru_on_max = Float64(val["p_ramp_res_up_online_ub"])
        p_rru_off_max = Float64(val["p_ramp_res_up_offline_ub"])
        p_rrd_on_max = Float64(val["p_ramp_res_down_online_ub"])
        p_rrd_off_max = Float64(val["p_ramp_res_down_offline_ub"])
        p_0 = Float64(val["initial_status"]["p"])
        q_0 = Float64(val["initial_status"]["q"])
        p_max = _float_vector(ts_val["p_ub"])
        p_min = _float_vector(ts_val["p_lb"])
        q_max = _float_vector(ts_val["q_ub"])
        q_min = _float_vector(ts_val["q_lb"])
        sus = _float_matrix(val["startup_states"])
        return (bus=bus, uid = uid, c_on = c_on, c_su = c_su, c_sd = c_sd, p_ru = p_ru, p_rd = p_rd, p_ru_su = p_ru_su, p_rd_sd = p_rd_sd,
        c_rgu = c_rgu, c_rgd = c_rgd, c_scr = c_scr, c_nsc = c_nsc, c_rru_on = c_rru_on, c_rru_off = c_rru_off, c_rrd_on = c_rrd_on, c_rrd_off = c_rrd_off,
        c_qru = c_qru, c_qrd = c_qrd, p_rgu_max = p_rgu_max, p_rgd_max = p_rgd_max, p_scr_max = p_scr_max, p_nsc_max = p_nsc_max, p_rru_on_max = p_rru_on_max,
        p_rru_off_max=p_rru_off_max, p_rrd_on_max=p_rrd_on_max, p_rrd_off_max=p_rrd_off_max, p_0=p_0, q_0=q_0, p_max=p_max, p_min=p_min, q_max=q_max, q_min=q_min, sus=sus)
    end
    sdd_rows(device_type) =
        SddRow[sdd_row(uid, data.sdd_lookup[uid]) for uid in sdd_order if data.sdd_lookup[uid]["device_type"] == device_type]

    # Devices grouped by their bus uid, in lookup iteration order, so a zone's
    # member devices are found without rescanning every device per zone/bus pair.
    devices_by_bus = Dict{String,Vector{String}}()
    for uid in keys(data.sdd_lookup)
        val = data.sdd_lookup[uid]
        push!(get!(devices_by_bus, String(val["bus"]), String[]), uid)
    end
    # One reserve-zone membership set. `ids`/`uids_key` pick the zone list and the
    # bus field naming its zones; `mkrow` builds the class-specific row.
    function reserve_set(::Type{R}, ids, uids_key, device_type, mkrow) where {R}
        rows = R[]
        for uid in ids
            for bus in values(data.bus_lookup)
                if uid in bus[uids_key]
                    for dev_uid in get(devices_by_bus, String(bus["uid"]), String[])
                        device = data.sdd_lookup[dev_uid]
                        if device["device_type"] == device_type
                            push!(rows, mkrow(goc3_bus_id(data, bus["uid"]), _uidnum(uid), String(device["uid"])))
                        end
                    end
                end
            end
        end
        return rows
    end

    sc_data = (
        bus = sort(BusRow[
            let val = data.bus_lookup[uid]
                i = goc3_bus_id(data, val["uid"])
                uid = String(val["uid"])
                v_min = Float64(val["vm_lb"])
                v_max = Float64(val["vm_ub"])
                (i = i, uid = uid, v_min = v_min, v_max = v_max)
            end for uid in bus_order
        ], by = x -> x.i),

        shunt = _by_uidnum(_typed_empty([
            let val = data.shunt_lookup[uid]
                uid = String(val["uid"])
                bus = goc3_bus_id(data, val["bus"])
                g_sh = val["gs"]
                b_sh = val["bs"]
                (uid = uid, bus=bus, g_sh = g_sh, b_sh = b_sh)
            end for uid in keys(data.shunt_lookup)
        ], EmptyShuntRow[])),

        acl_branch = sort(
            # AC lines
            _typed_empty([
                let val = data.ac_line_lookup[uid]
                    j_ln = _uidnum(val["uid"])+1
                    uid = String(val["uid"])
                    to_bus = goc3_bus_id(data, val["to_bus"])
                    fr_bus = goc3_bus_id(data, val["fr_bus"])
                    c_su = Float64(val["connection_cost"])
                    c_sd = Float64(val["disconnection_cost"])
                    s_max = Float64(val["mva_ub_nom"])
                    r = Float64(val["r"])
                    x = Float64(val["x"])
                    g_sr = Float64(r / (x^2 + r^2))
                    b_sr = Float64(-x / (x^2 + r^2))
                    b_ch = Float64(val["b"])
                    if val["additional_shunt"] == 1
                        g_fr = Float64(val["g_fr"])
                        g_to = Float64(val["g_to"])
                        b_fr = Float64(val["b_fr"])
                        b_to = Float64(val["b_to"])
                    else
                        g_fr = 0.0
                        g_to = 0.0
                        b_fr = 0.0
                        b_to = 0.0
                    end
                    (j_ln = j_ln, uid = uid, to_bus = to_bus, fr_bus = fr_bus, c_su = c_su, c_sd = c_sd, s_max = s_max,
                    g_sr = g_sr, b_sr = b_sr, b_ch = b_ch, g_fr = g_fr, g_to = g_to, b_fr = b_fr, b_to = b_to)
                end for uid in keys(data.ac_line_lookup)
            ], EmptyAclRow[]), by = x -> x.j_ln),

            # Transformers
        acx_branch = sort(
            _typed_empty([
                let val = data.twt_lookup[uid]
                    j_xf = _uidnum(val["uid"])+1
                    uid = String(val["uid"])
                    to_bus = goc3_bus_id(data, val["to_bus"])
                    fr_bus = goc3_bus_id(data, val["fr_bus"])
                    c_su = val["connection_cost"]
                    c_sd = val["disconnection_cost"]
                    s_max = val["mva_ub_nom"]
                    r = val["r"]
                    x = val["x"]
                    g_sr = r / (x^2 + r^2)
                    b_sr = -x / (x^2 + r^2)
                    b_ch = val["b"]
                    if val["additional_shunt"] == 1
                        g_fr = val["g_fr"]
                        g_to = val["g_to"]
                        b_fr = val["b_fr"]
                        b_to = val["b_to"]
                    else
                        g_fr = 0
                        g_to = 0
                        b_fr = 0
                        b_to = 0
                    end
                    (j_xf=j_xf, uid = uid, to_bus = to_bus, fr_bus = fr_bus, c_su = c_su, c_sd = c_sd, s_max = s_max,
                    g_sr = g_sr, b_sr = b_sr, b_ch = b_ch, g_fr = g_fr, g_to = g_to, b_fr = b_fr, b_to = b_to)
                end for uid in keys(data.twt_lookup)
            ], EmptyAcxRow[])
        , by = x -> x.j_xf),
        #Variable phase difference
        vpd = twt_control_set(@NamedTuple{j_xf::Int64, phi_min::Float64, phi_max::Float64},
            val -> val["ta_lb"] < val["ta_ub"],
            val -> (phi_min = Float64(val["ta_lb"]), phi_max = Float64(val["ta_ub"]))),
        #Fixed phase difference
        fpd = twt_control_set(@NamedTuple{j_xf::Int64, phi_o::Float64},
            val -> val["ta_lb"] >= val["ta_ub"],
            val -> (phi_o = Float64(val["initial_status"]["ta"]),)),
        #Variable winding ratio
        vwr = twt_control_set(@NamedTuple{j_xf::Int64, tau_min::Float64, tau_max::Float64},
            val -> val["tm_lb"] < val["tm_ub"],
            val -> (tau_min = Float64(val["tm_lb"]), tau_max = Float64(val["tm_ub"]))),
        #Fixed winding ratio
        fwr = twt_control_set(@NamedTuple{j_xf::Int64, tau_o::Float64},
            val -> val["tm_lb"] >= val["tm_ub"],
            val -> (tau_o = Float64(val["initial_status"]["tm"]),)),

        dc_branch = sort(_typed_empty([
            let val = data.dc_line_lookup[uid]
                j_dc = _uidnum(val["uid"])+1
                uid = String(val["uid"])
                pdc_max = val["pdc_ub"]
                qdc_fr_min = val["qdc_fr_lb"]
                qdc_to_min = val["qdc_to_lb"]
                qdc_fr_max = val["qdc_fr_ub"]
                qdc_to_max = val["qdc_to_ub"]
                to_bus = goc3_bus_id(data, val["to_bus"])
                fr_bus = goc3_bus_id(data, val["fr_bus"])
                (j_dc = j_dc, uid=uid, pdc_max=pdc_max, qdc_fr_min=qdc_fr_min, qdc_to_min=qdc_to_min, qdc_fr_max=qdc_fr_max, qdc_to_max=qdc_to_max, to_bus=to_bus, fr_bus=fr_bus)
            end for uid in keys(data.dc_line_lookup)

        ], EmptyDcRow[]), by = x -> x.j_dc),

        prod = sdd_rows("producer"),

        #Consumers
        cons = sdd_rows("consumer"),
        active_reserve = sort(_typed_empty([
            let val = data.azr_lookup[key]
                ts_val = data.azr_ts_lookup[key]
                n_p = _uidnum(val["uid"]) + 1
                uid = String(val["uid"])
                c_rgu = val["REG_UP_vio_cost"]
                c_rgd = val["REG_DOWN_vio_cost"]
                c_scr = val["SYN_vio_cost"]
                c_nsc = val["NSYN_vio_cost"]
                c_rru = Float64(val["RAMPING_RESERVE_UP_vio_cost"])
                c_rrd = Float64(val["RAMPING_RESERVE_DOWN_vio_cost"])
                σ_rgu = Float64(val["REG_UP"])
                σ_rgd = Float64(val["REG_DOWN"])
                σ_scr = Float64(val["SYN"])
                σ_nsc = Float64(val["NSYN"])
                p_rru_min = _float_vector(ts_val["RAMPING_RESERVE_UP"])
                p_rrd_min = _float_vector(ts_val["RAMPING_RESERVE_DOWN"])
                (n_p=n_p, uid=uid, c_rgu=c_rgu, c_rgd=c_rgd, c_scr=c_scr, c_nsc=c_nsc, c_rru=c_rru, c_rrd=c_rrd, σ_rgu=σ_rgu, σ_rgd=σ_rgd, σ_scr=σ_scr,
                σ_nsc=σ_nsc, p_rru_min=p_rru_min, p_rrd_min=p_rrd_min)
            end for key in keys(data.azr_lookup)
        ], EmptyActiveReserveRow[]), by = x -> x.n_p),
        reactive_reserve = sort(_typed_empty([
            let val = data.rzr_lookup[key]
                ts_val = data.rzr_ts_lookup[key]
                n_q = _uidnum(val["uid"]) + 1
                uid = String(val["uid"])
                c_qru = val["REACT_UP_vio_cost"]
                c_qrd = val["REACT_DOWN_vio_cost"]
                q_qru_min = _float_vector(ts_val["REACT_UP"])
                q_qrd_min = _float_vector(ts_val["REACT_DOWN"])
                (n_q=n_q, uid=uid, c_qru=c_qru, c_qrd=c_qrd, q_qru_min=q_qru_min, q_qrd_min=q_qrd_min)
            end for key in keys(data.rzr_lookup)
        ], EmptyReactiveReserveRow[]), by = x -> x.n_q),

        active_reserve_set_pr = reserve_set(ActiveReserveSetRow, data.azr_ids, "active_reserve_uids", "producer",
            (i, num, dev_uid) -> (i = i, n_p = num + 1, uid = dev_uid)),

        active_reserve_set_cs = reserve_set(ActiveReserveSetRow, data.azr_ids, "active_reserve_uids", "consumer",
            (i, num, dev_uid) -> (i = i, n_p = num + 1, uid = dev_uid)),

        reactive_reserve_set_pr = reserve_set(ReactiveReserveSetRow, data.rzr_ids, "reactive_reserve_uids", "producer",
            (i, num, dev_uid) -> (i = i, n_q = num + 1, uid = dev_uid)),

        reactive_reserve_set_cs = reserve_set(ReactiveReserveSetRow, data.rzr_ids, "reactive_reserve_uids", "consumer",
            (i, num, dev_uid) -> (i = i, n_q = num + 1, uid = dev_uid)),

    )
    return sc_data, lengths, cost_vector_pr, cost_vector_cs
end

"""
    goc3_energy_windows(data)

Build the multi-interval energy requirement window sets and their per-period
membership sets, split by producer/consumer and by max/min. Returns a named
tuple with fields `W_en_max_pr`, `W_en_max_cs`, `W_en_min_pr`, `W_en_min_cs`,
`T_w_en_max_pr`, `T_w_en_max_cs`, `T_w_en_min_pr`, `T_w_en_min_cs`. Pure
function of `data`.
"""
function goc3_energy_windows(data)
    periods = data.periods
    dt = Float64.(data.dt)
    ε_time = 1e-6

    # Interval midpoints, precomputed once from the cumulative durations so the
    # per-window membership test indexes instead of re-summing dt[1:t] each time.
    cdt = cumsum(dt)
    a_mid = [let a_end = cdt[t]; (a_end - dt[t] + a_end) / 2 end for t in periods]

    # One energy-requirement window set. `req_key` picks the ub/lb window list and
    # `mkrow` names the set-specific fields; the running index follows the
    # simple dispatchable device lookup order.
    function windows(::Type{R}, device_type, req_key, mkrow) where {R}
        rows = R[]
        ind = 1
        for uid in keys(data.sdd_lookup)
            val = data.sdd_lookup[uid]
            if val["device_type"] == device_type
                for w in val[req_key]
                    push!(rows, mkrow(ind, val["uid"], w))
                    ind += 1
                end
            end
        end
        return rows
    end

    # Per-period membership of each window: a period belongs when its midpoint
    # falls within the window. Window indices match the `windows` numbering.
    function window_periods(::Type{R}, device_type, req_key, mkrow) where {R}
        rows = R[]
        ind = 0
        for uid in keys(data.sdd_lookup)
            val = data.sdd_lookup[uid]
            if val["device_type"] == device_type
                for w in val[req_key]
                    ind += 1
                    for t in periods
                        m = a_mid[t]
                        if w[1] + ε_time < m && m <= w[2] + ε_time
                            push!(rows, mkrow(ind, val["uid"], t, dt[t]))
                        end
                    end
                end
            end
        end
        return rows
    end

    W_en_max_pr = windows(@NamedTuple{w_en_max_pr_ind::Int, uid::String, a_en_max_start::Float64, a_en_max_end::Float64, e_max::Float64},
        "producer", "energy_req_ub",
        (ind, uid, w) -> (w_en_max_pr_ind = ind, uid = String(uid), a_en_max_start = Float64(w[1]), a_en_max_end = Float64(w[2]), e_max = Float64(w[3])))
    W_en_max_cs = windows(@NamedTuple{w_en_max_cs_ind::Int, uid::String, a_en_max_start::Float64, a_en_max_end::Float64, e_max::Float64},
        "consumer", "energy_req_ub",
        (ind, uid, w) -> (w_en_max_cs_ind = ind, uid = String(uid), a_en_max_start = Float64(w[1]), a_en_max_end = Float64(w[2]), e_max = Float64(w[3])))
    W_en_min_pr = windows(@NamedTuple{w_en_min_pr_ind::Int, uid::String, a_en_min_start::Float64, a_en_min_end::Float64, e_min::Float64},
        "producer", "energy_req_lb",
        (ind, uid, w) -> (w_en_min_pr_ind = ind, uid = String(uid), a_en_min_start = Float64(w[1]), a_en_min_end = Float64(w[2]), e_min = Float64(w[3])))
    W_en_min_cs = windows(@NamedTuple{w_en_min_cs_ind::Int, uid::String, a_en_min_start::Float64, a_en_min_end::Float64, e_min::Float64},
        "consumer", "energy_req_lb",
        (ind, uid, w) -> (w_en_min_cs_ind = ind, uid = String(uid), a_en_min_start = Float64(w[1]), a_en_min_end = Float64(w[2]), e_min = Float64(w[3])))

    T_w_en_max_pr = window_periods(@NamedTuple{w_en_max_pr_ind::Int, uid::String, t::Int, dt::Float64},
        "producer", "energy_req_ub",
        (ind, uid, t, dtt) -> (w_en_max_pr_ind = ind, uid = String(uid), t = t, dt = Float64(dtt)))
    T_w_en_max_cs = window_periods(@NamedTuple{w_en_max_cs_ind::Int, uid::String, t::Int, dt::Float64},
        "consumer", "energy_req_ub",
        (ind, uid, t, dtt) -> (w_en_max_cs_ind = ind, uid = String(uid), t = t, dt = Float64(dtt)))
    T_w_en_min_pr = window_periods(@NamedTuple{w_en_min_pr_ind::Int, uid::String, t::Int, dt::Float64},
        "producer", "energy_req_lb",
        (ind, uid, t, dtt) -> (w_en_min_pr_ind = ind, uid = String(uid), t = t, dt = Float64(dtt)))
    T_w_en_min_cs = window_periods(@NamedTuple{w_en_min_cs_ind::Int, uid::String, t::Int, dt::Float64},
        "consumer", "energy_req_lb",
        (ind, uid, t, dtt) -> (w_en_min_cs_ind = ind, uid = String(uid), t = t, dt = Float64(dtt)))

    return (
        W_en_max_pr = W_en_max_pr,
        W_en_max_cs = W_en_max_cs,
        W_en_min_pr = W_en_min_pr,
        W_en_min_cs = W_en_min_cs,
        T_w_en_max_pr = T_w_en_max_pr,
        T_w_en_max_cs = T_w_en_max_cs,
        T_w_en_min_pr = T_w_en_min_pr,
        T_w_en_min_cs = T_w_en_min_cs,
    )
end

"""
    goc3_price_blocks(cost_vector_pr, cost_vector_cs)

Flatten the per-device energy cost curves into `(p_jtm_flattened_pr,
p_jtm_flattened_cs)`, one row per (device, period, cost block). Pure function of
the cost vectors returned by `goc3_static_data`.
"""
function goc3_price_blocks(cost_vector_pr, cost_vector_cs)
    function flatten(cost_vector)
        rows = Vector{@NamedTuple{flat_k::Int, uid::String, t::Int, m::Int, c_en::Float64, p_max::Float64}}()
        flat_k = 1
        for pc in cost_vector
            uid = pc.uid
            for (t, cost_t) in enumerate(pc.cost)
                for (m, cost_tm) in enumerate(cost_t)
                    c_en, p_max = cost_tm
                    push!(rows, (flat_k=flat_k, uid=uid, t=t, m=m, c_en=c_en, p_max=p_max))
                    flat_k += 1
                end
            end
        end
        return rows
    end

    return flatten(cost_vector_pr), flatten(cost_vector_cs)
end

"""
    goc3_ac_contingency_survivors(data, lengths)

Enumerate, for each contingency, the AC lines and transformers that remain in
service (the branch is not among the contingency's outaged components). Returns
`(ln, xf)` where each is a vector, in contingency order, of the surviving-branch
rows for that contingency in lookup-iteration order. Rows carry the per-class
fields `(ctg, j_ln|j_xf, uid, to_bus, fr_bus, b_sr, s_max_ctg)`. The client
attaches the stacked `j`, `j_ac`, the `u_on` status, and expands over periods.
"""
function goc3_ac_contingency_survivors(data, lengths)
    contingencies = data.raw["reliability"]["contingency"]

    LnRow = @NamedTuple{ctg::Int, j_ln::Int, uid::String, to_bus::Int, fr_bus::Int, b_sr::Float64, s_max_ctg::Float64}
    XfRow = @NamedTuple{ctg::Int, j_xf::Int, uid::String, to_bus::Int, fr_bus::Int, b_sr::Float64, s_max_ctg::Float64}

    # Surviving branches per contingency: a branch survives when it is not one of
    # the contingency's outaged components. `lookup` and `mkrow` specialize the
    # AC-line and transformer variants; iteration order matches the lookup.
    function survivors(::Type{R}, lookup, mkrow) where {R}
        result = Vector{Vector{R}}()
        for ctg in contingencies
            ctg_idx = _uidnum(ctg["uid"]) + 1
            outaged = Set(String.(ctg["components"]))
            rows = Vector{R}()
            for val in values(lookup)
                if !(String(val["uid"]) in outaged)
                    r = Float64(val["r"])
                    x = Float64(val["x"])
                    push!(rows, mkrow(ctg_idx, val, Float64(-x / (x^2 + r^2))))
                end
            end
            push!(result, rows)
        end
        return result
    end

    ln = survivors(LnRow, data.ac_line_lookup, (ctg_idx, val, b_sr) ->
        let j = _uidnum(val["uid"]) + 1
            (ctg = ctg_idx, j_ln = j, uid = String(val["uid"]),
             to_bus = goc3_bus_id(data, val["to_bus"]), fr_bus = goc3_bus_id(data, val["fr_bus"]),
             b_sr = b_sr, s_max_ctg = Float64(val["mva_ub_em"]))
        end)
    xf = survivors(XfRow, data.twt_lookup, (ctg_idx, val, b_sr) ->
        let j_xf = _uidnum(val["uid"]) + 1
            (ctg = ctg_idx, j_xf = j_xf, uid = String(val["uid"]),
             to_bus = goc3_bus_id(data, val["to_bus"]), fr_bus = goc3_bus_id(data, val["fr_bus"]),
             b_sr = b_sr, s_max_ctg = Float64(val["mva_ub_em"]))
        end)

    return (ln = ln, xf = xf)
end

"""
    goc3_dc_contingency_flows(data)

Enumerate the surviving DC lines for each contingency and period, returning the
flattened `jtk_dc_flattened` set. Rows carry the per-class `j_dc`; the client
attaches the stacked `j`. Fully pure: no unit commitment status is involved for
DC lines.
"""
function goc3_dc_contingency_flows(data)
    periods = data.periods
    dt = Float64.(data.dt)
    contingencies = data.raw["reliability"]["contingency"]

    jtk_dc_flattened = Vector{@NamedTuple{flat_jtk_dc::Int, ctg::Int, j_dc::Int, to_bus::Int, fr_bus::Int, t::Int, dt::Float64}}()
    flat_jtk_dc = 1
    for ctg in contingencies
        outaged = Set(String.(ctg["components"]))
        ctg_idx = _uidnum(ctg["uid"]) + 1
        for t in periods
            for val in values(data.dc_line_lookup)
                if !(String(val["uid"]) in outaged)
                    push!(jtk_dc_flattened, (flat_jtk_dc=flat_jtk_dc, ctg = ctg_idx,
                    j_dc = _uidnum(val["uid"])+1, to_bus = goc3_bus_id(data, val["to_bus"]),
                    fr_bus = goc3_bus_id(data, val["fr_bus"]), t=t, dt = dt[t]))
                    flat_jtk_dc += 1
                end
            end
        end
    end
    return jtk_dc_flattened
end
