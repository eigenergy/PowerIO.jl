"""
    FormatInfo

Canonical metadata returned by [`resolve_format`](@ref). `extension` is the
conventional filename suffix without a leading dot, can be compound such as
`"pio.json"`, and is `nothing` when the format has no conventional suffix.
`can_emit` reports whether the format has a fresh universal emitter. It is not
a build feature probe or a promise that every module value kind can emit the
format. A false value neither promises nor forbids a same format retained
source echo.
"""
struct FormatInfo
    token::String
    extension::Union{String,Nothing}
    is_directory::Bool
    can_emit::Bool
end

"""
    resolve_format(name) -> Union{FormatInfo,Nothing}

Resolve a format token or common alias to its canonical token, conventional
extension, and destination shape. Returns `nothing` for an unknown or
ambiguous name.
"""
function resolve_format(name::AbstractString)
    lib = _lib()
    _ensure_compatible(lib)
    _require_export("resolve_format", :pio_resolve_format_json,
                    "a PowerIO 1.0 C ABI library", lib)
    raw = ccall(_library_symbol(lib, :pio_resolve_format_json), Cstring,
                (Cstring,), String(name))
    raw == C_NULL && return nothing
    descriptor = JSON3.read(_take_string(lib, raw))
    extension = get(descriptor, :extension, nothing)
    return FormatInfo(
        String(descriptor.token),
        extension === nothing ? nothing : String(extension),
        Bool(descriptor.is_directory),
        Bool(descriptor.can_emit),
    )
end
