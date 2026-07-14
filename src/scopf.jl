# Native SCOPF problem instances over the C ABI (`pio_scopf_*`, powerio-capi
# built `--features prob`, powerio v0.7).
#
# The Rust core parses SCOPF source text into an owned instance and serializes
# it as a versioned, 1-based wire JSON document. The handle exposes nothing but
# that serialization today, so the binding is one shot: parse, serialize, free —
# no Julia-visible handle type until the C surface grows per-field accessors.
#
# This is the native sibling of the pure Julia GOC3 surface in `goc3.jl`
# ([`goc3_scopf_data`](@ref)); see the `parse_scopf` docstring for how the two
# relate and where their index conventions differ.

"""
    scopf_available() -> Bool

True if the resolved C library exports the `pio_scopf_*` API (built
`--features prob`, on in the released binaries from powerio v0.7.0).
"""
scopf_available() = _exports_symbol(:pio_scopf_parse_str)

"""
    parse_scopf(text; from="goc3-json") -> JSON3.Object

Parse SCOPF source `text` into the Rust core's native problem instance and
return its versioned wire document (`pio_scopf_parse_str` → `pio_scopf_to_json`).
`from` names the source format; `"goc3-json"` (a full ARPA-E GO Challenge 3
input document) is the one accepted today. The returned object is the envelope
`schema` (`"powerio.scopf.julia"`), `schema_version`, `index_base` (1), and
`instance` — static data, per-class lengths, energy windows, price blocks, and
contingency survivor sets, the same fields as [`ScopfInstance`](@ref).

This is the Rust-parsed sibling of the pure Julia
[`goc3_scopf_data`](@ref)`(parse_goc3_json(text))`. One convention differs: the
wire assigns reserve zone and branch indices from document order, while the
Julia builders derive them from uid numeric suffixes; the two agree on official
GOC3 files (eigenergy/powerio#252 tracks hardening the wire renumbering).
"""
function parse_scopf(text::AbstractString; from::AbstractString="goc3-json")
    lib = _lib()
    _ensure_compatible(lib)
    err = zeros(UInt8, _ERRLEN)
    ptr = try
        ccall(_library_symbol(lib, :pio_scopf_parse_str), Ptr{Cvoid},
              (Cstring, Cstring, Ptr{UInt8}, Csize_t),
              String(text), String(from), err, length(err))
    catch e
        _feature_call_error("parse_scopf", "pio_scopf_parse_str", "prob", e)
    end
    ptr == C_NULL && error("PowerIO.parse_scopf: " * _cstr(err))
    try
        s = ccall(_library_symbol(lib, :pio_scopf_to_json), Cstring,
                  (Ptr{Cvoid}, Ptr{UInt8}, Csize_t), ptr, err, length(err))
        s == C_NULL && error("PowerIO.parse_scopf: " * _cstr(err))
        wire = unsafe_string(s)
        ccall(_library_symbol(lib, :pio_string_free), Cvoid, (Cstring,), s)
        return JSON3.read(wire)
    finally
        ccall(_library_symbol(lib, :pio_scopf_instance_free), Cvoid, (Ptr{Cvoid},), ptr)
    end
end
