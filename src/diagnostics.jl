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
- `details`: structured details as a `Dict{String,Any}`, or `nothing`.
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
    details::Union{Dict{String,Any},Nothing}
end

function Base.show(io::IO, d::Diagnostic)
    print(io, "Diagnostic(", d.severity, " ", d.code, ": ", d.message, ")")
end

# Decode every record of a `PioDiagnostics *` and release the list. A NULL
# pointer is an empty list.
function _diagnostics(lib::AbstractString, ptr::Ptr)
    ptr == C_NULL && return Diagnostic[]
    h = DiagnosticsHandle(ptr, lib)
    out = @with_handles h _decode_diagnostics(lib, _ptr(h))
    release!(h)
    return out
end

_view(lib, entry, p::Ptr{Cvoid}, i) =
    @capi lib entry(p, i)
_flag(lib, entry, p::Ptr{Cvoid}, i) =
    @capi lib entry(p, i)

function _decode_diagnostics(lib::AbstractString, p::Ptr{Cvoid})
    n = Int(@capi lib :pio_diagnostics_len(p))
    out = Vector{Diagnostic}(undef, n)
    for k in 1:n
        i = Csize_t(k - 1)
        code = _str(_view(lib, Val(:pio_diagnostic_code), p, i))
        severity = Symbol(_str(_view(lib, Val(:pio_diagnostic_severity), p, i)))
        message = _str(_view(lib, Val(:pio_diagnostic_message), p, i))
        id = _flag(lib, Val(:pio_diagnostic_has_id), p, i) ?
            _str(_view(lib, Val(:pio_diagnostic_id), p, i)) : nothing
        target = _flag(lib, Val(:pio_diagnostic_has_target), p, i) ?
            _str(_view(lib, Val(:pio_diagnostic_target), p, i)) : nothing
        action = _flag(lib, Val(:pio_diagnostic_has_suggested_action), p, i) ?
            _str(_view(lib, Val(:pio_diagnostic_suggested_action), p, i)) : nothing
        n_spans = Int(@capi lib :pio_diagnostic_n_spans(p, i))
        spans = Vector{SourceSpan}(undef, n_spans)
        for s in 1:n_spans
            span = _fill(PioDiagnosticSpanView, lib) do out_span, err
                @capi lib :pio_diagnostic_span(p, i, Csize_t(s - 1), out_span, err)
            end
            spans[s] = SourceSpan(_str(span.source), span.byte_start, span.byte_end)
        end
        n_related = Int(@capi lib :pio_diagnostic_n_related(p, i))
        related = [_str(@capi lib :pio_diagnostic_related(p, i, Csize_t(r - 1)))
                   for r in 1:n_related]
        details_ptr = _checked(lib) do err
            @capi lib :pio_diagnostic_details_json(p, i, err)
        end
        details_text = _take_string(lib, details_ptr)
        details = isempty(details_text) ? nothing : JSON3.read(details_text, Dict{String,Any})
        details = details isa Dict && !isempty(details) ? details : nothing
        out[k] = Diagnostic(code, severity, message, id, target, action, spans, related, details)
    end
    return out
end

"""
    diagnostic_record(d::Diagnostic) -> Dict{String,Any}

One diagnostic as a JSON ready dictionary, matching what the Python binding
writes. `"code"`, `"severity"`, `"message"`, and `"target"` are always
present; a `target` of `nothing` serializes as `null`. `"id"`,
`"suggested_action"`, and `"related"` follow when the diagnostic sets them,
`"details"` when it carries structured details, and `"spans"` as `"source"`,
`"byte_start"`, `"byte_end"` dictionaries when it carries at least one span.
"""
function diagnostic_record(d::Diagnostic)
    record = Dict{String,Any}("code" => d.code, "severity" => String(d.severity),
                              "message" => d.message, "target" => d.target)
    if d.id !== nothing && !isempty(d.id)
        record["id"] = d.id
    end
    if d.suggested_action !== nothing && !isempty(d.suggested_action)
        record["suggested_action"] = d.suggested_action
    end
    if !isempty(d.related)
        record["related"] = copy(d.related)
    end
    if d.details !== nothing
        record["details"] = d.details
    end
    if !isempty(d.spans)
        record["spans"] = [Dict{String,Any}("source" => span.source,
                                            "byte_start" => Int(span.byte_start),
                                            "byte_end" => Int(span.byte_end))
                           for span in d.spans]
    end
    return record
end

"""
    diagnostic_records(diagnostics) -> Vector{Dict{String,Any}}

Every diagnostic as a JSON ready dictionary, in the order given. See
[`diagnostic_record`](@ref).
"""
diagnostic_records(diagnostics) = Dict{String,Any}[diagnostic_record(d) for d in diagnostics]
