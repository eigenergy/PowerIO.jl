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
