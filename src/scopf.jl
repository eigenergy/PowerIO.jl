# Native SCOPF problem instances over the C ABI (`pio_scopf_*`, powerio-capi
# built `--features prob`, powerio v0.7).
#
# The Rust core parses SCOPF source text into an owned instance;
# `pio_scopf_to_json` serializes it as versioned, 1-based JSON. The handle
# exposes nothing but that serialization today, so the binding is one shot:
# parse, serialize, free — no Julia-visible handle type until the C surface
# grows per-field accessors.
#
# This is the native sibling of the pure Julia GOC3 surface in `goc3.jl`
# ([`goc3_scopf_data`](@ref)); see the `parse_scopf` docstring for how the two
# relate and where their index conventions differ.

# The three symbols ship together with the prob feature; requiring all of them
# keeps scopf_available and parse_scopf in agreement on a partial library,
# like _has_switch_extractors does for the switch surface.
const _SCOPF_SYMBOLS = (:pio_scopf_parse_str, :pio_scopf_to_json, :pio_scopf_instance_free)

"""
    scopf_available() -> Bool

True if the resolved C library exports the `pio_scopf_*` API (built
`--features prob`, on in the released binaries from powerio v0.7.0).
"""
scopf_available() = all(sym -> _exports_symbol(sym), _SCOPF_SYMBOLS)

"""
    parse_scopf(text; from="goc3-json") -> JSON3.Object

Parse SCOPF source `text` into the Rust core's native problem instance and
return the versioned JSON `pio_scopf_to_json` produces for it. `from` names the
source format; `"goc3-json"` (a full ARPA-E GO Challenge 3 input document) is
the one accepted today. The returned object carries `schema`
(`"powerio.scopf"`), `powerio_version`, `index_base` (1), and `instance` —
static data, per-class lengths, energy windows, price blocks, contingency
survivor sets, the device class layout, and the interval durations: the
document behind [`goc3_scopf_data`](@ref), which types these rows. Every
index in the document comes from document-order enumeration.
"""
function parse_scopf(text::AbstractString; from::AbstractString="goc3-json")
    lib = _lib()
    _ensure_compatible(lib)
    for sym in _SCOPF_SYMBOLS
        _require_export("parse_scopf", sym, "powerio v0.7, `--features prob`", lib)
    end
    err = zeros(UInt8, _ERRLEN)
    ptr = ccall(_library_symbol(lib, :pio_scopf_parse_str), Ptr{Cvoid},
                (Cstring, Cstring, Ptr{UInt8}, Csize_t),
                String(text), String(from), err, length(err))
    ptr == C_NULL && error("PowerIO.parse_scopf: " * _cstr(err))
    try
        s = ccall(_library_symbol(lib, :pio_scopf_to_json), Cstring,
                  (Ptr{Cvoid}, Ptr{UInt8}, Csize_t), ptr, err, length(err))
        s == C_NULL && error("PowerIO.parse_scopf: " * _cstr(err))
        return JSON3.read(_take_string(lib, s))
    finally
        ccall(_library_symbol(lib, :pio_scopf_instance_free), Cvoid, (Ptr{Cvoid},), ptr)
    end
end
