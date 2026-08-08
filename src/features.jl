# One "usable from Julia" probe per optional cargo feature. `features()` and
# `has_feature`'s pre-0.7 fallback both read this table, so adding a feature is
# one entry and the two can never disagree.
const _FEATURE_PROBES = (;
    arrow = arrow_available,
    matrix = matrix_available,
    gridfm = gridfm_available,
    dist = dist_available,
    package = package_available,
    prob = scopf_available,
)

"""
    features() -> NamedTuple

Return the optional C ABI features available in the resolved library.

The fields are `arrow`, `matrix`, `gridfm`, `dist`, `package`, and `prob`. Each
field reports "usable from Julia" (symbol present and, where one exists, the
feature ABI handshake passes); [`has_feature`](@ref) asks the library itself
what it was compiled with. Use this in downstream packages instead of probing
private symbols.
"""
features() = map(probe -> probe(), _FEATURE_PROBES)

"""
    has_feature(feature) -> Bool

Whether the resolved library was compiled with the named cargo feature
(`pio_has_feature`): `"arrow"`, `"matrix"`, `"gridfm"`, `"dist"`, `"pkg"` (the
[`features`](@ref) field name `"package"` is accepted as an alias), or
`"prob"`. Unknown names return `false`; like the sibling probes this never
throws — an unresolvable or ABI-incompatible library answers `false`. Unlike
[`features`](@ref), this is what the library says it was compiled with; it
does not run the per-feature ABI handshakes. A pre-0.7 library without
`pio_has_feature` is probed by each feature's representative entry point
instead.
"""
function has_feature(feature::AbstractString)
    feature = feature == "package" ? "pkg" : String(feature)
    lib = _lib()
    if _exports_symbol(:pio_has_feature, lib)
        try
            _ensure_compatible(lib)
            return ccall(_library_symbol(lib, :pio_has_feature), Cint,
                         (Cstring,), feature) != 0
        catch e
            @debug "PowerIO: pio_has_feature probe failed" exception = (e, catch_backtrace())
            return false
        end
    end
    # Pre-0.7 fallback: the docstring's "ABI-incompatible answers false" holds
    # here too — library_available() runs the main handshake without throwing —
    # and the probes come from the same table features() reads, so the two
    # cannot drift.
    library_available() || return false
    probe = get(_FEATURE_PROBES, feature == "pkg" ? :package : Symbol(feature), nothing)
    probe === nothing && return false
    return probe()
end

# One flag per entry, in `pio_dist_capabilities_json` document order.
const _DIST_CAPABILITY_KEYS = (
    :bmopf_fixed_taps,
    :bmopf_center_tap_leakage,
    :bmopf_delta_wye_leakage,
    :bmopf_delta_roll,
    :bmopf_voltage_source_merge,
    :bmopf_transformer_diagnostics,
)

# Added in capability document 1.1.0; an older document reads as `false`.
const _DIST_CAPABILITY_V08_KEYS = (
    :typed_capacitors,
    :line_and_generator_ratings,
    :per_sequence_bus_bounds,
    :transformer_extras_relocation,
)

# The full documented shape: envelope, flags, then the BMOPF vintage strings
# (`nothing` when the document predates capability version 1.1.0).
const _DIST_CAPABILITY_FIELDS = (:dist, :schema_version,
                                 _DIST_CAPABILITY_KEYS...,
                                 _DIST_CAPABILITY_V08_KEYS...,
                                 :bmopf_schema_id, :bmopf_schema_version)

function _dist_capabilities_from(obj)
    # A flag is set only by JSON `true`; null, absence, and a reshaped
    # value all read as `false`, so the probe never throws on a document.
    flag(k) = get(obj, k, false) === true
    return NamedTuple{_DIST_CAPABILITY_FIELDS}((
        haskey(obj, :dist) ? obj.dist === true : dist_available(),
        get(obj, :schema_version, nothing),
        map(flag, _DIST_CAPABILITY_KEYS)...,
        map(flag, _DIST_CAPABILITY_V08_KEYS)...,
        get(obj, :bmopf_schema_id, nothing),
        get(obj, :bmopf_schema_version, nothing),
    ))
end

_dist_capabilities_default() = _dist_capabilities_from((;))

"""
    dist_capabilities() -> NamedTuple

Return fine grained distribution fidelity capabilities reported by the resolved
PowerIO C ABI.

The fields are $(join(string.('`', _DIST_CAPABILITY_FIELDS, '`'), ", ", ", and ")).

A library that does not export `pio_dist_capabilities_json` reports every
flag `false` and every string `nothing`. A capability document that predates
a flag reports the same `false`. A `false` flag means the library does not
report the capability; a missing entry never raises an error.

`bmopf_schema_id` and `bmopf_schema_version` name the BMOPF schema vintage
the library's writer targets. Both are `nothing` when the document predates
them. Neither identifies a vintage alone; use them together.
"""
function dist_capabilities()
    lib = _lib()
    _exports_symbol(:pio_dist_capabilities_json, lib) || return _dist_capabilities_default()
    _ensure_dist_compatible(lib)
    s = try
        ccall(_library_symbol(lib, :pio_dist_capabilities_json), Cstring, ())
    catch e
        _feature_call_error("dist_capabilities", "pio_dist_capabilities_json", "dist", e)
    end
    s == C_NULL && error("PowerIO.dist_capabilities: pio_dist_capabilities_json returned null")
    return _dist_capabilities_from(JSON3.read(_take_string(lib, s)))
end

const _SCHEMA_VERSION_FIELDS = (:schema_version, :abi, :package, :arrow)

"""
    schema_versions() -> NamedTuple

Return the document-format versions the resolved library reports through
`pio_schema_versions_json` (powerio v0.8).

The fields are `schema_version`, `abi`, `package`, and `arrow`. `package` and
`arrow` name the `.pio.json` envelope and Arrow schema lineages the library
speaks; this binding targets `PIO_PACKAGE_SCHEMA_VERSION` and
`PIO_ARROW_SCHEMA_VERSION`. A field the document does not carry is `nothing`.
A library without the entry point reports every field `nothing`; a missing
report never raises an error.
"""
function schema_versions()
    lib = _lib()
    _exports_symbol(:pio_schema_versions_json, lib) ||
        return NamedTuple{_SCHEMA_VERSION_FIELDS}((nothing, nothing, nothing, nothing))
    _ensure_compatible(lib)
    s = ccall(_library_symbol(lib, :pio_schema_versions_json), Cstring, ())
    s == C_NULL && error("PowerIO.schema_versions: pio_schema_versions_json returned null")
    obj = JSON3.read(_take_string(lib, s))
    return NamedTuple{_SCHEMA_VERSION_FIELDS}(map(k -> get(obj, k, nothing), _SCHEMA_VERSION_FIELDS))
end
