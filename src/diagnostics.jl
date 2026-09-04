# Structured diagnostics decoded from a `PioDiagnostics` list.

"""
    SourceSpan(source, byte_start, byte_end)

One byte range in a named source, attached to a [`Diagnostic`](@ref).
"""
struct SourceSpan
    source::String
    byte_start::UInt64
    byte_end::UInt64
end

"""
    Diagnostic

One finding recorded by a reader, writer, or transformation.

- `code`: the stable code to branch on, such as `"READ.MATPOWER.FIELD_DEFAULTED"`.
- `severity`: `:error`, `:warning`, `:remark`, or `:note`.
- `message`: rendered text for people.
- `id`: durable identity, or `nothing`.
- `target`: locator of the value element concerned, or `nothing`.
- `suggested_action`: what to do about it, or `nothing`.
- `spans`: source byte ranges.
- `related`: identities of related diagnostics.
- `details`: structured details as a `JSON3.Object`, or `nothing`.
"""
struct Diagnostic
    code::String
    severity::Symbol
    message::String
    id::Union{String,Nothing}
    target::Union{String,Nothing}
    suggested_action::Union{String,Nothing}
    spans::Vector{SourceSpan}
    related::Vector{String}
    details::Union{JSON3.Object,Nothing}
end

function Base.show(io::IO, d::Diagnostic)
    print(io, "Diagnostic(", d.severity, " ", d.code, ": ", d.message, ")")
end

# Decode every record of a `PioDiagnostics *` and release the list. A NULL
# pointer is an empty list.
function _diagnostics(lib::AbstractString, ptr::Ptr{Cvoid})
    ptr == C_NULL && return Diagnostic[]
    h = DiagnosticsHandle(ptr, lib)
    out = GC.@preserve h _decode_diagnostics(lib, _ptr(h))
    release!(h)
    return out
end

_view(lib, sym::Symbol, p::Ptr{Cvoid}, i) =
    ccall(_library_symbol(lib, sym), PioStringView, (Ptr{Cvoid}, Csize_t), p, i)
_flag(lib, sym::Symbol, p::Ptr{Cvoid}, i) =
    ccall(_library_symbol(lib, sym), Bool, (Ptr{Cvoid}, Csize_t), p, i)

function _decode_diagnostics(lib::AbstractString, p::Ptr{Cvoid})
    n = Int(ccall(_library_symbol(lib, :pio_diagnostics_len), Csize_t, (Ptr{Cvoid},), p))
    out = Vector{Diagnostic}(undef, n)
    for k in 1:n
        i = Csize_t(k - 1)
        code = _str(_view(lib, :pio_diagnostic_code, p, i))
        severity = Symbol(_str(_view(lib, :pio_diagnostic_severity, p, i)))
        message = _str(_view(lib, :pio_diagnostic_message, p, i))
        id = _flag(lib, :pio_diagnostic_has_id, p, i) ?
            _str(_view(lib, :pio_diagnostic_id, p, i)) : nothing
        target = _flag(lib, :pio_diagnostic_has_target, p, i) ?
            _str(_view(lib, :pio_diagnostic_target, p, i)) : nothing
        action = _flag(lib, :pio_diagnostic_has_suggested_action, p, i) ?
            _str(_view(lib, :pio_diagnostic_suggested_action, p, i)) : nothing
        n_spans = Int(ccall(_library_symbol(lib, :pio_diagnostic_n_spans), Csize_t,
                            (Ptr{Cvoid}, Csize_t), p, i))
        spans = Vector{SourceSpan}(undef, n_spans)
        for s in 1:n_spans
            span = _fill(PioDiagnosticSpanView, lib) do out_span, err
                ccall(_library_symbol(lib, :pio_diagnostic_span), Bool,
                      (Ptr{Cvoid}, Csize_t, Csize_t, Ref{PioDiagnosticSpanView}, Ref{Ptr{Cvoid}}),
                      p, i, Csize_t(s - 1), out_span, err)
            end
            spans[s] = SourceSpan(_str(span.source), span.byte_start, span.byte_end)
        end
        n_related = Int(ccall(_library_symbol(lib, :pio_diagnostic_n_related), Csize_t,
                              (Ptr{Cvoid}, Csize_t), p, i))
        related = [_str(ccall(_library_symbol(lib, :pio_diagnostic_related), PioStringView,
                              (Ptr{Cvoid}, Csize_t, Csize_t), p, i, Csize_t(r - 1)))
                   for r in 1:n_related]
        details_ptr = _checked(lib) do err
            ccall(_library_symbol(lib, :pio_diagnostic_details_json), Ptr{Cvoid},
                  (Ptr{Cvoid}, Csize_t, Ref{Ptr{Cvoid}}), p, i, err)
        end
        details_text = _take_string(lib, details_ptr)
        details = isempty(details_text) ? nothing : JSON3.read(details_text)
        details = details isa JSON3.Object && !isempty(details) ? details : nothing
        out[k] = Diagnostic(code, severity, message, id, target, action, spans, related, details)
    end
    return out
end
