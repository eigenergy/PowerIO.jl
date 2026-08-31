# Native structured diagnostics: every record crosses the C boundary through
# the PioDiagnostics list handle and its field accessors, never through JSON.

"""
    SourceSpan

One byte range of a retained source: `source` is the module local source
identifier, `byte_start` and `byte_end` a half open byte range in that
source's bytes.
"""
struct SourceSpan
    source::String
    byte_start::UInt64
    byte_end::UInt64
end

Base.show(io::IO, s::SourceSpan) =
    print(io, s.source, "[", s.byte_start, "..", s.byte_end, ")")

"""
    Diagnostic

One coded finding: a stable dotted `code`, a `severity` (`:error`,
`:warning`, `:remark`, or `:note`), and the rendered `message`. `target`
names the value or source construct the finding is about, `spans` are byte
ranges into the retained source, `related` names other records by identity,
`suggested_action` states a reasonable next step, and `details` is the
finding's open detail object as a JSON string. Every field except the first
three can be absent.

Read a module's findings from `module.diagnostics`; a failed operation's
findings ride on the thrown [`PowerIOError`](@ref). Branch on `code`, never on
the message text.
"""
struct Diagnostic
    code::String
    severity::Symbol
    message::String
    id::Union{Nothing,String}
    target::Union{Nothing,String}
    suggested_action::Union{Nothing,String}
    spans::Vector{SourceSpan}
    related::Vector{String}
    details::Union{Nothing,String}
end

function Base.show(io::IO, d::Diagnostic)
    print(io, uppercase(String(d.severity)), " ", d.code, ": ", d.message)
    d.target === nothing || print(io, " [", d.target, "]")
end

function Base.show(io::IO, ::MIME"text/plain", d::Diagnostic)
    show(io, d)
    for span in d.spans
        print(io, "\n  at ", span)
    end
    d.suggested_action === nothing || print(io, "\n  action: ", d.suggested_action)
end

const _SEVERITIES = Dict(
    "error" => :error, "warning" => :warning, "remark" => :remark, "note" => :note,
)

_optional_cstr(p::Cstring) = p == C_NULL ? nothing : unsafe_string(p)

# Decode every row of one PioDiagnostics handle into owned Julia records and
# release the handle. `acquire(err_ref)` returns the raw list pointer (NULL is
# an empty list).
function _diagnostics_of(acquire, lib::AbstractString)
    d = acquire(nothing)
    d == C_NULL && return Diagnostic[]
    handle = _library_handle(lib)
    len = ccall(Libdl.dlsym(handle, :pio_diagnostics_len), Csize_t, (Ptr{Cvoid},), d)
    out = Vector{Diagnostic}(undef, Int(len))
    code_fn = Libdl.dlsym(handle, :pio_diagnostic_code)
    severity_fn = Libdl.dlsym(handle, :pio_diagnostic_severity)
    message_fn = Libdl.dlsym(handle, :pio_diagnostic_message)
    id_fn = Libdl.dlsym(handle, :pio_diagnostic_id)
    target_fn = Libdl.dlsym(handle, :pio_diagnostic_target)
    action_fn = Libdl.dlsym(handle, :pio_diagnostic_suggested_action)
    details_fn = Libdl.dlsym(handle, :pio_diagnostic_details_json)
    n_spans_fn = Libdl.dlsym(handle, :pio_diagnostic_n_spans)
    span_fn = Libdl.dlsym(handle, :pio_diagnostic_span)
    n_related_fn = Libdl.dlsym(handle, :pio_diagnostic_n_related)
    related_fn = Libdl.dlsym(handle, :pio_diagnostic_related)
    try
        for i in 1:Int(len)
            index = Csize_t(i - 1)
            severity_name = unsafe_string(
                ccall(severity_fn, Cstring, (Ptr{Cvoid}, Csize_t), d, index))
            n_spans = Int(ccall(n_spans_fn, Csize_t, (Ptr{Cvoid}, Csize_t), d, index))
            spans = Vector{SourceSpan}(undef, n_spans)
            for j in 1:n_spans
                start = Ref{UInt64}(0)
                stop = Ref{UInt64}(0)
                source = ccall(span_fn, Cstring,
                               (Ptr{Cvoid}, Csize_t, Csize_t, Ref{UInt64}, Ref{UInt64}),
                               d, index, Csize_t(j - 1), start, stop)
                spans[j] = SourceSpan(unsafe_string(source), start[], stop[])
            end
            n_related = Int(ccall(n_related_fn, Csize_t, (Ptr{Cvoid}, Csize_t), d, index))
            related = String[
                unsafe_string(ccall(related_fn, Cstring,
                                    (Ptr{Cvoid}, Csize_t, Csize_t), d, index, Csize_t(j - 1)))
                for j in 1:n_related
            ]
            out[i] = Diagnostic(
                unsafe_string(ccall(code_fn, Cstring, (Ptr{Cvoid}, Csize_t), d, index)),
                get(_SEVERITIES, severity_name, Symbol(severity_name)),
                unsafe_string(ccall(message_fn, Cstring, (Ptr{Cvoid}, Csize_t), d, index)),
                _optional_cstr(ccall(id_fn, Cstring, (Ptr{Cvoid}, Csize_t), d, index)),
                _optional_cstr(ccall(target_fn, Cstring, (Ptr{Cvoid}, Csize_t), d, index)),
                _optional_cstr(ccall(action_fn, Cstring, (Ptr{Cvoid}, Csize_t), d, index)),
                spans,
                related,
                _optional_cstr(ccall(details_fn, Cstring, (Ptr{Cvoid}, Csize_t), d, index)),
            )
        end
    finally
        ccall(Libdl.dlsym(handle, :pio_diagnostics_release), Cvoid, (Ptr{Cvoid},), d)
    end
    return out
end
