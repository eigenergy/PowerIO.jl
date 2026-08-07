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

# One boolean capability per entry, in the order `pio_dist_capabilities_json`
# documents them. These tuples are the single source: the all-false default,
# the parsed result, the docstring field list, and the test assertions all
# derive from them, so a new upstream flag is one line here and none of the
# four can disagree.
#
# The v0.6.2 set: BMOPF fidelity fixes. Every library from v0.6.2 on reports
# all six `true`.
const _DIST_CAPABILITY_KEYS = (
    :bmopf_fixed_taps,
    :bmopf_center_tap_leakage,
    :bmopf_delta_wye_leakage,
    :bmopf_delta_roll,
    :bmopf_voltage_source_merge,
    :bmopf_transformer_diagnostics,
)

# The v0.8 era set (capability document 1.1.0). `false` against any library
# whose document predates them, including released v0.8.0 binaries — additive
# by design, so no assertion may require them.
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

# Keyword construction, not positional-over-the-fields-tuple: with keywords a
# reordered or grown fields list cannot silently shift a value under the wrong
# name — the mistake would be a construction error instead.
_dist_capabilities_from(obj, dist_default) = begin
    flag(k) = Bool(get(obj, k, false))
    (;
        dist = Bool(get(obj, :dist, dist_default)),
        schema_version = get(obj, :schema_version, nothing),
        NamedTuple{_DIST_CAPABILITY_KEYS}(map(flag, _DIST_CAPABILITY_KEYS))...,
        NamedTuple{_DIST_CAPABILITY_V08_KEYS}(map(flag, _DIST_CAPABILITY_V08_KEYS))...,
        bmopf_schema_id = get(obj, :bmopf_schema_id, nothing),
        bmopf_schema_version = get(obj, :bmopf_schema_version, nothing),
    )
end

_dist_capabilities_default() = _dist_capabilities_from((;), dist_available())

"""
    dist_capabilities() -> NamedTuple

Return fine grained distribution fidelity capabilities reported by the resolved
PowerIO C ABI.

The fields are $(join(string.('`', _DIST_CAPABILITY_FIELDS, '`'), ", ", ", and ")).

Older libraries that do not export `pio_dist_capabilities_json` return the same
layout with every flag `false` and the strings `nothing`; so does any library
whose capability document predates a given flag. Absence therefore means "not
known to this library", never an error, and downstream packages gate a specific
behavior on its flag: the `bmopf_*` fidelity fixes are v0.6.2, and
`typed_capacitors`, `line_and_generator_ratings`, `per_sequence_bus_bounds`,
and `transformer_extras_relocation` report the v0.8 distribution work.

`bmopf_schema_id` and `bmopf_schema_version` name the BMOPF schema vintage the
library's writer targets (v0.8 changed the `\\$id` and relocated transformer
fields under `extras`, which is exactly what a downstream reader needs to key
on). Both are `nothing` when the document predates them. Neither identifies a
vintage alone — upstream serves the schema from an unpinned branch and has
changed content without moving the version — so pair them.
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
    return _dist_capabilities_from(JSON3.read(_take_string(lib, s)), dist_available())
end
