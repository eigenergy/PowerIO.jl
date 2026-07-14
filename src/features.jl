"""
    features() -> NamedTuple

Return the optional C ABI features available in the resolved library.

The fields are `arrow`, `matrix`, `gridfm`, `dist`, `package`, and `prob`. Each
field reports "usable from Julia" (symbol present and, where one exists, the
feature ABI handshake passes); [`has_feature`](@ref) asks the library itself
what it was compiled with. Use this in downstream packages instead of probing
private symbols.
"""
features() = (;
    arrow = arrow_available(),
    matrix = matrix_available(),
    gridfm = gridfm_available(),
    dist = dist_available(),
    package = package_available(),
    prob = scopf_available(),
)

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
    # and each feature delegates to its own probe, so the representative
    # symbols live in one place and cannot drift from features().
    library_available() || return false
    feature == "arrow" && return arrow_available()
    feature == "matrix" && return matrix_available()
    feature == "gridfm" && return gridfm_available()
    feature == "dist" && return dist_available()
    feature == "pkg" && return package_available()
    feature == "prob" && return scopf_available()
    return false
end

const _DIST_CAPABILITY_KEYS = (
    :bmopf_fixed_taps,
    :bmopf_center_tap_leakage,
    :bmopf_delta_wye_leakage,
    :bmopf_delta_roll,
    :bmopf_voltage_source_merge,
    :bmopf_transformer_diagnostics,
)

_dist_capabilities_default() = (;
    dist = dist_available(),
    schema_version = nothing,
    bmopf_fixed_taps = false,
    bmopf_center_tap_leakage = false,
    bmopf_delta_wye_leakage = false,
    bmopf_delta_roll = false,
    bmopf_voltage_source_merge = false,
    bmopf_transformer_diagnostics = false,
)

"""
    dist_capabilities() -> NamedTuple

Return fine grained distribution fidelity capabilities reported by the resolved
PowerIO C ABI.

The fields are `dist`, `schema_version`, `bmopf_fixed_taps`,
`bmopf_center_tap_leakage`, `bmopf_delta_wye_leakage`, `bmopf_delta_roll`,
`bmopf_voltage_source_merge`, and `bmopf_transformer_diagnostics`.

Older libraries that do not export `pio_dist_capabilities_json` return the same
layout with all BMOPF fidelity flags set to `false`. Use this in downstream
packages when deciding whether PowerIO's BMOPF export already carries a
specific v0.6.2 fidelity fix.
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
    text = unsafe_string(s)
    ccall(_library_symbol(lib, :pio_string_free), Cvoid, (Cstring,), s)
    obj = JSON3.read(text)

    flag(k) = Bool(get(obj, k, false))
    return (;
        dist = Bool(get(obj, :dist, default.dist)),
        schema_version = get(obj, :schema_version, default.schema_version),
        bmopf_fixed_taps = flag(:bmopf_fixed_taps),
        bmopf_center_tap_leakage = flag(:bmopf_center_tap_leakage),
        bmopf_delta_wye_leakage = flag(:bmopf_delta_wye_leakage),
        bmopf_delta_roll = flag(:bmopf_delta_roll),
        bmopf_voltage_source_merge = flag(:bmopf_voltage_source_merge),
        bmopf_transformer_diagnostics = flag(:bmopf_transformer_diagnostics),
    )
end
