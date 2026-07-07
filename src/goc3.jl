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

"""
    goc3_static_data(data, producers_first)

Build the static SCOPF index sets from a `parse_goc3_json` result. Returns
`(sc_data, lengths, cost_vector_pr, cost_vector_cs)` where `sc_data` is the
named tuple of buses, shunts, AC/DC branches, transformer control sets,
producers, consumers, zonal reserves, and device-zone membership sets. Pure
function of `data`; no unit commitment solution is used.
"""
function goc3_static_data(data, producers_first)
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

    cost_vector_pr = sort(
            #producers
            [
                begin
                    ts_val = data.sdd_ts_lookup[key]
                    bus = goc3_bus_id(data, val["bus"])
                    uid = val["uid"]
                    cost = ts_val["cost"]
                    (bus=bus, uid = uid, cost=cost)
                end for (key, val) in data.sdd_lookup if val["device_type"] == "producer"

            ], by = x -> parse(Int, match(r"\d+", x.uid).match))

            #Consumers
    cost_vector_cs = sort(
            [
                begin
                    ts_val = data.sdd_ts_lookup[key]
                    bus = goc3_bus_id(data, val["bus"])
                    uid = val["uid"]
                    cost = ts_val["cost"]
                    (bus=bus, uid = uid, cost=cost)
                end for (key, val) in data.sdd_lookup if val["device_type"] == "consumer"
            ], by = x -> parse(Int, match(r"\d+", x.uid).match))


    sc_data = (
        bus = sort([
            begin
                i = goc3_bus_id(data, val["uid"])
                uid = val["uid"]
                v_min = val["vm_lb"]
                v_max = val["vm_ub"]
                (i = i, uid = uid, v_min = v_min, v_max = v_max)
            end for val in values(data.bus_lookup)
        ], by = x -> x.i),

        shunt = sort([
            begin
                uid = val["uid"]
                bus = goc3_bus_id(data, val["bus"])
                g_sh = val["gs"]
                b_sh = val["bs"]
                (uid = uid, bus=bus, g_sh = g_sh, b_sh = b_sh)
            end for val in values(data.shunt_lookup)
        ], by = x -> parse(Int, match(r"\d+", x.uid).match)),

        acl_branch = sort(
            # AC lines
            [
                begin
                    j_ac = parse(Int, match(r"\d+", val["uid"]).match)+1
                    j_ln = j_ac
                    uid = val["uid"]
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
                    (j_ac = j_ac, j_ln = j_ln, uid = uid, to_bus = to_bus, fr_bus = fr_bus, c_su = c_su, c_sd = c_sd, s_max = s_max,
                    g_sr = g_sr, b_sr = b_sr, b_ch = b_ch, g_fr = g_fr, g_to = g_to, b_fr = b_fr, b_to = b_to)
                end for val in values(data.ac_line_lookup)
            ],by = x -> x.j_ln),

            # Transformers
        acx_branch = sort(
            [
                begin
                    j_xf = parse(Int, match(r"\d+", val["uid"]).match)+1
                    j_ac = j_xf + L_J_ln
                    uid = val["uid"]
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
                    (j_ac = j_ac, j_xf=j_xf, uid = uid, to_bus = to_bus, fr_bus = fr_bus, c_su = c_su, c_sd = c_sd, s_max = s_max,
                    g_sr = g_sr, b_sr = b_sr, b_ch = b_ch, g_fr = g_fr, g_to = g_to, b_fr = b_fr, b_to = b_to)
                end for val in values(data.twt_lookup)
            ]
        , by = x -> x.j_ac),
        #Variable phase difference
        vpd = isempty(val for val in values(data.twt_lookup) if val["ta_lb"] < val["ta_ub"]) ? Vector{@NamedTuple{j_ac::Int64, j_xf::Int64, phi_min::Float64, phi_max::Float64}}() : sort([
            begin
                j_xf = parse(Int, match(r"\d+", val["uid"]).match)+1
                j_ac = parse(Int, match(r"\d+", val["uid"]).match) + L_J_ln+1
                phi_min = val["ta_lb"]
                phi_max = val["ta_ub"]
                (j_ac = j_ac, j_xf=j_xf, phi_min = phi_min, phi_max = phi_max)
            end for val in values(data.twt_lookup) if val["ta_lb"] < val["ta_ub"]
        ], by = x -> x.j_ac),
        #Fixed phase difference
        fpd = isempty(val for val in values(data.twt_lookup) if val["ta_lb"] >= val["ta_ub"]) ? Vector{@NamedTuple{j_ac::Int64, j_xf::Int64, phi_o::Float64}}() : sort([
            begin
                j_ac = parse(Int, match(r"\d+", val["uid"]).match) + L_J_ln+1
                j_xf = parse(Int, match(r"\d+", val["uid"]).match)+1
                phi_o = val["initial_status"]["ta"]
                (j_ac = j_ac, j_xf=j_xf, phi_o = phi_o)
            end for val in values(data.twt_lookup) if val["ta_lb"] >= val["ta_ub"]
        ], by = x -> x.j_ac),
        #Variable winding ratio
        vwr = isempty(val for val in values(data.twt_lookup) if val["tm_lb"] < val["tm_ub"]) ? Vector{@NamedTuple{j_ac::Int64, j_xf::Int64, tau_min::Float64, tau_max::Float64}}() : sort([
            begin
                j_ac = parse(Int, match(r"\d+", val["uid"]).match) + L_J_ln+1
                j_xf = parse(Int, match(r"\d+", val["uid"]).match)+1
                tau_min = val["tm_lb"]
                tau_max = val["tm_ub"]
                (j_ac=j_ac, j_xf=j_xf, tau_min=tau_min, tau_max=tau_max)
            end for val in values(data.twt_lookup) if val["tm_lb"] < val["tm_ub"]
        ], by = x -> x.j_ac),
        #Fixed winding ratio
        fwr = isempty(val for val in values(data.twt_lookup) if val["tm_lb"] >= val["tm_ub"]) ? Vector{@NamedTuple{j_ac::Int64, j_xf::Int64, tau_o::Float64}}() : sort([
            begin
                j_ac = parse(Int, match(r"\d+", val["uid"]).match) + L_J_ln+1
                j_xf = parse(Int, match(r"\d+", val["uid"]).match)+1
                tau_o = val["initial_status"]["tm"]
                (j_ac=j_ac, j_xf=j_xf, tau_o=tau_o)
            end for val in values(data.twt_lookup) if val["tm_lb"] >= val["tm_ub"]

        ], by = x -> x.j_ac),

        dc_branch = sort([
            begin
                j_dc = parse(Int, match(r"\d+", val["uid"]).match)+1
                uid = val["uid"]
                pdc_max = val["pdc_ub"]
                qdc_fr_min = val["qdc_fr_lb"]
                qdc_to_min = val["qdc_to_lb"]
                qdc_fr_max = val["qdc_fr_ub"]
                qdc_to_max = val["qdc_to_ub"]
                to_bus = goc3_bus_id(data, val["to_bus"])
                fr_bus = goc3_bus_id(data, val["fr_bus"])
                (j_dc = j_dc, uid=uid, pdc_max=pdc_max, qdc_fr_min=qdc_fr_min, qdc_to_min=qdc_to_min, qdc_fr_max=qdc_fr_max, qdc_to_max=qdc_to_max, to_bus=to_bus, fr_bus=fr_bus)
            end for val in values(data.dc_line_lookup)

        ], by = x -> x.j_dc),

        prod = sort(
            # Producers
            [
                begin
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
                    c_rgu = convert(Vector{Float64}, ts_val["p_reg_res_up_cost"]) #these need checks to see if empty
                    c_rgd = convert(Vector{Float64}, ts_val["p_reg_res_down_cost"])
                    c_scr = convert(Vector{Float64}, ts_val["p_syn_res_cost"])
                    c_nsc = convert(Vector{Float64}, ts_val["p_nsyn_res_cost"])
                    c_rru_on = convert(Vector{Float64}, ts_val["p_ramp_res_up_online_cost"])
                    c_rru_off = convert(Vector{Float64}, ts_val["p_ramp_res_up_offline_cost"])
                    c_rrd_on = convert(Vector{Float64}, ts_val["p_ramp_res_down_online_cost"])
                    c_rrd_off = convert(Vector{Float64}, ts_val["p_ramp_res_down_offline_cost"])
                    c_qru = convert(Vector{Float64}, ts_val["q_res_up_cost"])
                    c_qrd = convert(Vector{Float64}, ts_val["q_res_down_cost"])
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
                    p_max = convert(Vector{Float64}, ts_val["p_ub"])
                    p_min = convert(Vector{Float64}, ts_val["p_lb"])
                    q_max = convert(Vector{Float64}, ts_val["q_ub"])
                    q_min = convert(Vector{Float64}, ts_val["q_lb"])
                    sus = convert(Vector{Vector{Float64}}, val["startup_states"])

                    (bus=bus, uid = uid, c_on = c_on, c_su = c_su, c_sd = c_sd, p_ru = p_ru, p_rd = p_rd, p_ru_su = p_ru_su, p_rd_sd = p_rd_sd,
                    c_rgu = c_rgu, c_rgd = c_rgd, c_scr = c_scr, c_nsc = c_nsc, c_rru_on = c_rru_on, c_rru_off = c_rru_off, c_rrd_on = c_rrd_on, c_rrd_off = c_rrd_off,
                    c_qru = c_qru, c_qrd = c_qrd, p_rgu_max = p_rgu_max, p_rgd_max = p_rgd_max, p_scr_max = p_scr_max, p_nsc_max = p_nsc_max, p_rru_on_max = p_rru_on_max,
                    p_rru_off_max=p_rru_off_max, p_rrd_on_max=p_rrd_on_max, p_rrd_off_max=p_rrd_off_max, p_0=p_0, q_0=q_0, p_max=p_max, p_min=p_min, q_max=q_max, q_min=q_min, sus=sus)
                end for (key, val) in data.sdd_lookup if val["device_type"] == "producer"
            ], by = x -> parse(Int, match(r"\d+", x.uid).match)),

        #Consumers
        cons = sort(
            [
                begin
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
                    c_rgu = convert(Vector{Float64}, ts_val["p_reg_res_up_cost"])
                    c_rgd = convert(Vector{Float64}, ts_val["p_reg_res_down_cost"])
                    c_scr = convert(Vector{Float64}, ts_val["p_syn_res_cost"])
                    c_nsc = convert(Vector{Float64}, ts_val["p_nsyn_res_cost"])
                    c_rru_on = convert(Vector{Float64}, ts_val["p_ramp_res_up_online_cost"])
                    c_rru_off = convert(Vector{Float64}, ts_val["p_ramp_res_up_offline_cost"])
                    c_rrd_on = convert(Vector{Float64}, ts_val["p_ramp_res_down_online_cost"])
                    c_rrd_off = convert(Vector{Float64}, ts_val["p_ramp_res_down_offline_cost"])
                    c_qru = convert(Vector{Float64}, ts_val["q_res_up_cost"])
                    c_qrd = convert(Vector{Float64}, ts_val["q_res_down_cost"])
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
                    p_max = convert(Vector{Float64}, ts_val["p_ub"])
                    p_min = convert(Vector{Float64}, ts_val["p_lb"])
                    q_max = convert(Vector{Float64}, ts_val["q_ub"])
                    q_min = convert(Vector{Float64}, ts_val["q_lb"])
                    sus = convert(Vector{Vector{Float64}}, val["startup_states"])

                    (bus=bus, uid = uid, c_on = c_on, c_su = c_su, c_sd = c_sd, p_ru = p_ru, p_rd = p_rd, p_ru_su = p_ru_su, p_rd_sd = p_rd_sd,
                    c_rgu = c_rgu, c_rgd = c_rgd, c_scr = c_scr, c_nsc = c_nsc, c_rru_on = c_rru_on, c_rru_off = c_rru_off, c_rrd_on = c_rrd_on, c_rrd_off = c_rrd_off,
                    c_qru = c_qru, c_qrd = c_qrd, p_rgu_max = p_rgu_max, p_rgd_max = p_rgd_max, p_scr_max = p_scr_max, p_nsc_max = p_nsc_max, p_rru_on_max = p_rru_on_max,
                    p_rru_off_max=p_rru_off_max, p_rrd_on_max=p_rrd_on_max, p_rrd_off_max=p_rrd_off_max, p_0=p_0, q_0=q_0, p_max=p_max, p_min=p_min, q_max=q_max, q_min=q_min, sus=sus)
                end for (key, val) in data.sdd_lookup if val["device_type"] == "consumer"
            ]
        , by = x -> parse(Int, match(r"\d+", x.uid).match)),
        active_reserve = sort([
            begin
                ts_val = data.azr_ts_lookup[key]
                n = parse(Int, match(r"\d+", val["uid"]).match) + 1
                n_p = n
                uid = val["uid"]
                c_rgu = val["REG_UP_vio_cost"]
                c_rgd = val["REG_DOWN_vio_cost"]
                c_scr = val["SYN_vio_cost"]
                c_nsc = val["NSYN_vio_cost"]
                c_rru = val["RAMPING_RESERVE_UP_vio_cost"]
                c_rrd = val["RAMPING_RESERVE_DOWN_vio_cost"]
                σ_rgu = val["REG_UP"]
                σ_rgd = val["REG_DOWN"]
                σ_scr = val["SYN"]
                σ_nsc = val["NSYN"]
                p_rru_min = convert(Vector{Float64}, ts_val["RAMPING_RESERVE_UP"])
                p_rrd_min = convert(Vector{Float64}, ts_val["RAMPING_RESERVE_DOWN"])
                (n=n, n_p=n_p, uid=uid, c_rgu=c_rgu, c_rgd=c_rgd, c_scr=c_scr, c_nsc=c_nsc, c_rru=c_rru, c_rrd=c_rrd, σ_rgu=σ_rgu, σ_rgd=σ_rgd, σ_scr=σ_scr,
                σ_nsc=σ_nsc, p_rru_min=p_rru_min, p_rrd_min=p_rrd_min)
            end for (key, val) in data.azr_lookup
        ], by = x -> x.n),
        reactive_reserve = sort([
            begin
                ts_val = data.rzr_ts_lookup[key]
                n = parse(Int, match(r"\d+", val["uid"]).match) + L_N_p + 1
                n_q = parse(Int, match(r"\d+", val["uid"]).match) + 1
                uid = val["uid"]
                c_qru = val["REACT_UP_vio_cost"]
                c_qrd = val["REACT_DOWN_vio_cost"]
                q_qru_min = convert(Vector{Float64}, ts_val["REACT_UP"])
                q_qrd_min = convert(Vector{Float64}, ts_val["REACT_DOWN"])
                (n=n, n_q=n_q, uid=uid, c_qru=c_qru, c_qrd=c_qrd, q_qru_min=q_qru_min, q_qrd_min=q_qrd_min)
            end for (key, val) in data.rzr_lookup
        ], by = x -> x.n),

        active_reserve_set_pr = [
            (i = goc3_bus_id(data, bus["uid"]),
             n = parse(Int, match(r"\d+", uid).match) + 1,
             n_p =  parse(Int, match(r"\d+", uid).match) + 1,
             uid = device["uid"],
            )
            for uid in data.azr_ids
            for bus in values(data.bus_lookup)
            if uid in bus["active_reserve_uids"]
            for device in values(data.sdd_lookup)
            if device["bus"] == bus["uid"] && device["device_type"] == "producer"
        ],

        active_reserve_set_cs = [
            (i = goc3_bus_id(data, bus["uid"]),
             n = parse(Int, match(r"\d+", uid).match) + 1,
             n_p =  parse(Int, match(r"\d+", uid).match) + 1,
             uid = device["uid"],)
            for uid in data.azr_ids
            for bus in values(data.bus_lookup)
            if uid in bus["active_reserve_uids"]
            for device in values(data.sdd_lookup)
            if device["bus"] == bus["uid"] && device["device_type"] == "consumer"
        ],

        reactive_reserve_set_pr = [
            (i = goc3_bus_id(data, bus["uid"]),
             n = parse(Int, match(r"\d+", uid).match) + L_N_p + 1,
             n_q = parse(Int, match(r"\d+", uid).match) + 1,
             uid = device["uid"],)
            for uid in data.rzr_ids
            for bus in values(data.bus_lookup)
            if uid in bus["reactive_reserve_uids"]
            for device in values(data.sdd_lookup)
            if device["bus"] == bus["uid"] && device["device_type"] == "producer"
        ],

        reactive_reserve_set_cs = [
            (i = goc3_bus_id(data, bus["uid"]),
             n = parse(Int, match(r"\d+", uid).match) + L_N_p + 1,
             n_q = parse(Int, match(r"\d+", uid).match) + 1,
             uid = device["uid"],)
            for uid in data.rzr_ids
            for bus in values(data.bus_lookup)
            if uid in bus["reactive_reserve_uids"]
            for device in values(data.sdd_lookup)
            if device["bus"] == bus["uid"] && device["device_type"] == "consumer"
        ],

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

    W_en_max_pr = Vector{@NamedTuple{w_en_max_pr_ind::Int, uid::String, a_en_max_start::Float64, a_en_max_end::Float64, e_max::Float64}}()
    w_en_max_pr_ind = 1
    for val in values(data.sdd_lookup)
        if val["device_type"] == "producer"
            for w in val["energy_req_ub"]
                push!(W_en_max_pr, (
                    w_en_max_pr_ind=w_en_max_pr_ind,
                    uid = val["uid"],
                    a_en_max_start = w[1],
                    a_en_max_end = w[2],
                    e_max = w[3])
                )
                w_en_max_pr_ind +=1
            end
        end
    end

    W_en_max_cs = Vector{@NamedTuple{w_en_max_cs_ind::Int, uid::String, a_en_max_start::Float64, a_en_max_end::Float64, e_max::Float64}}()
    w_en_max_cs_ind = 1
    for val in values(data.sdd_lookup)
        if val["device_type"] == "consumer"
            for w in val["energy_req_ub"]
                push!(W_en_max_cs, (
                    w_en_max_cs_ind=w_en_max_cs_ind,
                    uid = val["uid"],
                    a_en_max_start = w[1],
                    a_en_max_end = w[2],
                    e_max = w[3])
                )
                w_en_max_cs_ind +=1
            end
        end
    end

    W_en_min_pr = Vector{@NamedTuple{w_en_min_pr_ind::Int, uid::String, a_en_min_start::Float64, a_en_min_end::Float64, e_min::Float64}}()
    w_en_min_pr_ind = 1
    for val in values(data.sdd_lookup)
        if val["device_type"] == "producer"
            for w in val["energy_req_lb"]
                push!(W_en_min_pr, (w_en_min_pr_ind = w_en_min_pr_ind,
                uid = val["uid"],
                a_en_min_start = w[1],
                a_en_min_end = w[2],
                e_min = w[3]))
                w_en_min_pr_ind += 1
            end
        end
    end

    W_en_min_cs = Vector{@NamedTuple{w_en_min_cs_ind::Int, uid::String, a_en_min_start::Float64, a_en_min_end::Float64, e_min::Float64}}()
    w_en_min_cs_ind = 1
    for val in values(data.sdd_lookup)
        if val["device_type"] == "consumer"
            for w in val["energy_req_lb"]
                push!(W_en_min_cs, (w_en_min_cs_ind = w_en_min_cs_ind,
                uid = val["uid"],
                a_en_min_start = w[1],
                a_en_min_end = w[2],
                e_min = w[3]))
                w_en_min_cs_ind += 1
            end
        end
    end

    T_w_en_max_pr = Vector{@NamedTuple{w_en_max_pr_ind::Int, uid::String, t::Int, dt::Float64}}()
    w_en_max_pr_ind = 0
    for val in values(data.sdd_lookup)
        if val["device_type"] == "producer"
            for w in val["energy_req_ub"]
                w_en_max_pr_ind += 1
                for t in periods
                    if w[1] + ε_time < goc3_interval_bounds(dt, t)[2] && goc3_interval_bounds(dt, t)[2] <= w[2] + ε_time
                        push!(T_w_en_max_pr, (w_en_max_pr_ind = w_en_max_pr_ind,
                            uid = val["uid"],
                            t = t,
                            dt=dt[t]))
                    end
                end
            end
        end
    end

    T_w_en_max_cs = Vector{@NamedTuple{w_en_max_cs_ind::Int, uid::String, t::Int, dt::Float64}}()
    w_en_max_cs_ind = 0
    for val in values(data.sdd_lookup)
        if val["device_type"] == "consumer"
            for w in val["energy_req_ub"]
                w_en_max_cs_ind += 1
                for t in periods
                    if w[1] + ε_time < goc3_interval_bounds(dt, t)[2] && goc3_interval_bounds(dt, t)[2] <= w[2] + ε_time
                        push!(T_w_en_max_cs, (w_en_max_cs_ind = w_en_max_cs_ind,
                            uid = val["uid"],
                            t = t,
                            dt=dt[t]))
                    end
                end
            end
        end
    end

    T_w_en_min_pr = Vector{@NamedTuple{w_en_min_pr_ind::Int, uid::String, t::Int, dt::Float64}}()
    w_en_min_pr_ind = 0
    for val in values(data.sdd_lookup)
        if val["device_type"] == "producer"
            for w in val["energy_req_lb"]
                w_en_min_pr_ind += 1
                for t in periods
                    if w[1] + ε_time < goc3_interval_bounds(dt, t)[2] && goc3_interval_bounds(dt, t)[2] <= w[2] + ε_time
                        push!(T_w_en_min_pr, (w_en_min_pr_ind=w_en_min_pr_ind,
                        uid = val["uid"],
                        t = t,
                        dt = dt[t]))
                    end
                end
            end
        end
    end

    T_w_en_min_cs = Vector{@NamedTuple{w_en_min_cs_ind::Int, uid::String, t::Int, dt::Float64}}()
    w_en_min_cs_ind = 0
    for val in values(data.sdd_lookup)
        if val["device_type"] == "consumer"
            for w in val["energy_req_lb"]
                w_en_min_cs_ind += 1
                for t in periods
                    if w[1] + ε_time < goc3_interval_bounds(dt, t)[2] && goc3_interval_bounds(dt, t)[2] <= w[2] + ε_time
                        push!(T_w_en_min_cs, (w_en_min_cs_ind=w_en_min_cs_ind,
                        uid = val["uid"],
                        t = t,
                        dt = dt[t]))
                    end
                end
            end
        end
    end

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
    p_jtm_flattened_pr = Vector{@NamedTuple{flat_k::Int, uid::String, t::Int, m::Int, c_en::Float64, p_max::Float64}}()
    flat_k=1
    for pc in cost_vector_pr
        uid = pc.uid
        for (t, cost_t) in enumerate(pc.cost)
            for (m, cost_tm) in enumerate(cost_t)
                c_en, p_max = cost_tm
                push!(p_jtm_flattened_pr, (flat_k=flat_k, uid=uid, t=t, m=m, c_en=c_en, p_max=p_max))
                flat_k+=1
            end
        end
    end

    p_jtm_flattened_cs = Vector{@NamedTuple{flat_k::Int, uid::String, t::Int, m::Int, c_en::Float64, p_max::Float64}}()
    flat_k=1
    for pc in cost_vector_cs
        uid = pc.uid
        for (t, cost_t) in enumerate(pc.cost)
            for (m, cost_tm) in enumerate(cost_t)
                c_en, p_max = cost_tm
                push!(p_jtm_flattened_cs, (flat_k=flat_k, uid=uid, t=t, m=m, c_en=c_en, p_max=p_max))
                flat_k+=1
            end
        end
    end

    return p_jtm_flattened_pr, p_jtm_flattened_cs
end

"""
    goc3_ac_contingency_survivors(data, lengths)

Enumerate, for each contingency, the AC lines and transformers that remain in
service (the branch is not among the contingency's outaged components). Returns
`(ln, xf)` where each is a vector, in contingency order, of the surviving-branch
rows for that contingency in lookup-iteration order. Rows carry the per-class
fields `(ctg, j_ac, j_ln|j_xf, uid, to_bus, fr_bus, b_sr, s_max_ctg)`. The client
attaches the stacked `j`, the `u_on` status, and expands over periods.
"""
function goc3_ac_contingency_survivors(data, lengths)
    L_J_ln = lengths.L_J_ln
    contingencies = data.raw["reliability"]["contingency"]

    LnRow = @NamedTuple{ctg::Int, j_ac::Int, j_ln::Int, uid::String, to_bus::Int, fr_bus::Int, b_sr::Float64, s_max_ctg::Float64}
    XfRow = @NamedTuple{ctg::Int, j_ac::Int, j_xf::Int, uid::String, to_bus::Int, fr_bus::Int, b_sr::Float64, s_max_ctg::Float64}

    ln = Vector{Vector{LnRow}}()
    xf = Vector{Vector{XfRow}}()

    for ctg in contingencies
        ctg_idx = parse(Int, match(r"\d+", ctg["uid"]).match) + 1

        ln_rows = Vector{LnRow}()
        for component in ctg["components"]
            for val in values(data.ac_line_lookup)
                if val["uid"] != component
                    r = val["r"]
                    x = val["x"]
                    j_ac = parse(Int, match(r"\d+", val["uid"]).match) + 1
                    push!(ln_rows, (ctg = ctg_idx, j_ac = j_ac, j_ln = j_ac, uid = String(val["uid"]),
                        to_bus = goc3_bus_id(data, val["to_bus"]), fr_bus = goc3_bus_id(data, val["fr_bus"]),
                        b_sr = -x / (x^2 + r^2), s_max_ctg = Float64(val["mva_ub_em"])))
                end
            end
        end
        push!(ln, ln_rows)

        xf_rows = Vector{XfRow}()
        for component in ctg["components"]
            for val in values(data.twt_lookup)
                if val["uid"] != component
                    r = val["r"]
                    x = val["x"]
                    j_xf = parse(Int, match(r"\d+", val["uid"]).match) + 1
                    j_ac = j_xf + L_J_ln
                    push!(xf_rows, (ctg = ctg_idx, j_ac = j_ac, j_xf = j_xf, uid = String(val["uid"]),
                        to_bus = goc3_bus_id(data, val["to_bus"]), fr_bus = goc3_bus_id(data, val["fr_bus"]),
                        b_sr = -x / (x^2 + r^2), s_max_ctg = Float64(val["mva_ub_em"])))
                end
            end
        end
        push!(xf, xf_rows)
    end

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
    for ctg in contingencies, t in periods
        for component in ctg["components"]
            for val in values(data.dc_line_lookup)
                if val["uid"] != component
                    push!(jtk_dc_flattened, (flat_jtk_dc=flat_jtk_dc, ctg = parse(Int, match(r"\d+", ctg["uid"]).match)+1,
                    j_dc = parse(Int, match(r"\d+", val["uid"]).match)+1, to_bus = goc3_bus_id(data, val["to_bus"]),
                    fr_bus = goc3_bus_id(data, val["fr_bus"]), t=t, dt = dt[t]))
                    flat_jtk_dc += 1
                end
            end
        end
    end
    return jtk_dc_flattened
end
