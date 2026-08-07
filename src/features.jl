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

# One BMOPF fidelity flag per entry, in the order `pio_dist_capabilities_json`
# documents them. This tuple is the single source: the all-false default, the
# parsed result, and the docstring field list are all derived from it, so a new
# upstream flag is one line here and the three can never disagree.
const _DIST_CAPABILITY_KEYS = (
    :bmopf_fixed_taps,
    :bmopf_center_tap_leakage,
    :bmopf_delta_wye_leakage,
    :bmopf_delta_roll,
    :bmopf_voltage_source_merge,
    :bmopf_transformer_diagnostics,
)

# The two envelope fields the capabilities JSON always carries, ahead of the flags.
const _DIST_CAPABILITY_FIELDS = (:dist, :schema_version, _DIST_CAPABILITY_KEYS...)

_dist_capabilities_default() = NamedTuple{_DIST_CAPABILITY_FIELDS}((
    dist_available(),
    nothing,
    ntuple(_ -> false, length(_DIST_CAPABILITY_KEYS))...,
))

"""
    dist_capabilities() -> NamedTuple

Return fine grained distribution fidelity capabilities reported by the resolved
PowerIO C ABI.

The fields are $(join(string.('`', _DIST_CAPABILITY_FIELDS, '`'), ", ", ", and ")).

Older libraries that do not export `pio_dist_capabilities_json` return the same
layout with all BMOPF fidelity flags set to `false`. Use this in downstream
packages when deciding whether PowerIO's BMOPF export already carries a
specific BMOPF fidelity fix.

!!! warning
    These flags cover only the v0.6.2 BMOPF fidelity work, and the C ABI has
    not extended them since — every release from v0.6.2 on reports the same six
    `true` values and the same `schema_version`. So this cannot answer "does it
    know about typed capacitors" or "which BMOPF schema vintage does it write",
    and gating v0.8 era behavior on it yields a false negative. For payload
    questions read the network instead: an element table the library does not
    populate reads as empty (`PowerIO.capacitors(net)`), which is the same
    answer a caller needs either way.
"""
function dist_capabilities()
    default = _dist_capabilities_default()
    lib = _lib()
    _exports_symbol(:pio_dist_capabilities_json, lib) || return default
    _ensure_dist_compatible(lib)
    s = try
        ccall(_library_symbol(lib, :pio_dist_capabilities_json), Cstring, ())
    catch e
        _feature_call_error("dist_capabilities", "pio_dist_capabilities_json", "dist", e)
    end
    s == C_NULL && error("PowerIO.dist_capabilities: pio_dist_capabilities_json returned null")
    text = _take_string(lib, s)
    obj = JSON3.read(text)

    flag(k) = Bool(get(obj, k, false))
    return NamedTuple{_DIST_CAPABILITY_FIELDS}((
        Bool(get(obj, :dist, default.dist)),
        get(obj, :schema_version, default.schema_version),
        map(flag, _DIST_CAPABILITY_KEYS)...,
    ))
end
