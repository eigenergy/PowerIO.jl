# Display helpers for the two parsed network wrappers. These use summary JSON,
# so live handles stay lazy and `net.data` remains unset.

_display_source(summary) = _display_text(summary.source_format; default="?")
_display_name(summary) = _display_text(summary.name; default="(unnamed)")
_display_text(value; default::AbstractString) =
    (value === nothing || String(value) == "") ? default : String(value)

function _display_count(summary, field::Symbol)
    counts = summary.counts
    return haskey(counts, field) ? Int(getproperty(counts, field)) : 0
end

_display_data_state(net) =
    getfield(net, :data) === nothing ? "not materialized" : "materialized"

function _display_vector(value)
    value === nothing && return "unknown"
    return "[" * join(string.(collect(value)), ", ") * "]"
end

_display_bool(value) = value === nothing ? "unknown" : string(Bool(value))

function _display_line(io::IO, label::AbstractString, value)
    println(io, "  ", label, ": ", value)
end

function Base.show(io::IO, net::BalancedNetwork)
    summary = _summary(net)
    print(io, "BalancedNetwork{", _display_source(summary), "}: ",
          _display_count(summary, :buses), " buses, ",
          _display_count(summary, :branches), " branches, ",
          _display_count(summary, :generators), " gens")
end

function Base.show(io::IO, ::MIME"text/plain", net::BalancedNetwork)
    summary = _summary(net)
    topology = summary.topology
    println(io, "BalancedNetwork{", _display_source(summary), "}")
    _display_line(io, "name", _display_name(summary))
    _display_line(io, "base_mva", Float64(summary.base_mva))
    _display_line(io, "base_frequency", string(Float64(summary.base_frequency), " Hz"))
    for field in (:buses, :branches, :generators, :loads, :shunts, :storage, :hvdc)
        _display_line(io, String(field), _display_count(summary, field))
    end
    _display_line(io, "components", topology.n_components === nothing ? "unknown" : Int(topology.n_components))
    _display_line(io, "radial", _display_bool(topology.is_radial))
    _display_line(io, "reference_bus_ids", _display_vector(topology.reference_bus_ids))
    _display_line(io, "warnings", _display_count(summary, :warnings))
    print(io, "  data: ", _display_data_state(net))
end

function Base.show(io::IO, net::MulticonductorNetwork)
    summary = _summary(net)
    print(io, "MulticonductorNetwork{", _display_source(summary), "}: ",
          _display_count(summary, :buses), " buses, ",
          _display_count(summary, :lines), " lines, ",
          _display_count(summary, :loads), " loads")
end

function Base.show(io::IO, ::MIME"text/plain", net::MulticonductorNetwork)
    summary = _summary(net)
    println(io, "MulticonductorNetwork{", _display_source(summary), "}")
    _display_line(io, "name", _display_name(summary))
    _display_line(io, "base_frequency", string(Float64(summary.base_frequency), " Hz"))
    for field in _MC_TABLE_NAMES
        # The core tables print even at zero; the rest (typed capacitors, IBRs,
        # control profiles, untyped leftovers) only when the case has some, so a
        # typical feeder does not grow four zero rows.
        n = _display_count(summary, field)
        (field in _MC_ALWAYS_SHOWN || n > 0) || continue
        _display_line(io, String(field), n)
    end
    _display_line(io, "warnings", _display_count(summary, :warnings))
    print(io, "  data: ", _display_data_state(net))
end
