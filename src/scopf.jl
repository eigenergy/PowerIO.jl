# Native SCOPF problem instances over the C ABI (`pio_scopf_*`, powerio-capi
# built `--features prob`, powerio v0.9).
#
# The Rust core parses SCOPF source text into an owned instance;
# `pio_scopf_to_json_with_index_base` serializes it as versioned JSON with the
# caller's requested index base. The handle
# exposes nothing but that serialization today, so the binding is one shot:
# parse, serialize, free — no Julia-visible handle type until the C surface
# grows per-field accessors.
# `goc3_scopf_data` types the 1-based form directly; there is one projection and
# no Julia-side index conversion.

# The four symbols ship together with the prob feature; requiring all of them
# keeps scopf_available and parse_scopf in agreement on a partial library,
# like _has_switch_extractors does for the switch surface.
const _SCOPF_SYMBOLS = (
    :pio_scopf_parse_str,
    :pio_scopf_to_json,
    :pio_scopf_to_json_with_index_base,
    :pio_scopf_instance_free,
)

"""
    scopf_available() -> Bool

True if the resolved C library exports the `pio_scopf_*` API (built
`--features prob`, on in the powerio v0.9.0 release binaries).
"""
scopf_available() = all(sym -> _exports_symbol(sym), _SCOPF_SYMBOLS)

"""
    parse_scopf(text; from="goc3-json", index_base=1) -> JSON3.Object

Parse SCOPF source `text` into the Rust core's native problem instance and
return its versioned JSON document. `from` names the source format;
`"goc3-json"` (a full ARPA-E GO Challenge 3 input document) is the one accepted
today. `index_base` accepts only `0` or `1` and defaults to Julia's native
1-based indexing. The returned object carries `schema` (`"powerio.scopf"`),
`powerio_version`, `index_base`, and `instance` — static data, per-class
lengths, energy windows, price blocks, contingency survivor sets, the device
class layout, and the interval durations: the document behind
[`goc3_scopf_data`](@ref), which requests and types the 1-based rows directly.
Every ordinal in either representation comes from document-order enumeration.
"""
function parse_scopf(text::AbstractString; from::AbstractString="goc3-json",
                     index_base::Integer=1)
    base = if index_base == 0
        Cint(0)
    elseif index_base == 1
        Cint(1)
    else
        throw(ArgumentError("index_base must be 0 or 1, got $index_base"))
    end
    lib = _lib()
    _ensure_compatible(lib)
    for sym in _SCOPF_SYMBOLS
        _require_export("parse_scopf", sym, "powerio v0.9, `--features prob`", lib)
    end
    err = zeros(UInt8, _ERRLEN)
    ptr = ccall(_library_symbol(lib, :pio_scopf_parse_str), Ptr{Cvoid},
                (Cstring, Cstring, Ptr{UInt8}, Csize_t),
                String(text), String(from), err, length(err))
    ptr == C_NULL && error("PowerIO.parse_scopf: " * _cstr(err))
    try
        s = ccall(_library_symbol(lib, :pio_scopf_to_json_with_index_base), Cstring,
                  (Ptr{Cvoid}, Cint, Ptr{UInt8}, Csize_t),
                  ptr, base, err, length(err))
        s == C_NULL && error("PowerIO.parse_scopf: " * _cstr(err))
        return JSON3.read(_take_string(lib, s))
    finally
        ccall(_library_symbol(lib, :pio_scopf_instance_free), Cvoid, (Ptr{Cvoid},), ptr)
    end
end
