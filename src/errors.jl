# Structured failures from the C library.

"""
    PowerIOError(code, message, diagnostics)

A failure reported by the PowerIO library. `code` is the stable diagnostic
code to branch on, `message` is the rendered text, and `diagnostics` are the
structured [`Diagnostic`](@ref) records that caused the failure.
"""
struct PowerIOError <: Exception
    code::String
    message::String
    diagnostics::Vector{Diagnostic}
end

function Base.showerror(io::IO, e::PowerIOError)
    print(io, "PowerIOError: ")
    if isempty(e.code) || startswith(e.message, e.code)
        print(io, e.message)
    else
        print(io, e.code, ": ", e.message)
    end
end

# Convert a `PioError *` into a `PowerIOError`, releasing the C error.
function _take_error(lib::AbstractString, err::Ptr{PioError})
    try
        code = _str(@capi lib :pio_error_code(err))
        message = _str(@capi lib :pio_error_message(err))
        diagnostics = _diagnostics(lib, @capi lib :pio_error_diagnostics(err))
        return PowerIOError(code, message, diagnostics)
    finally
        @capi lib :pio_error_release(err)
    end
end

# Run `f(err)` where `err` is the `PioError **` output parameter, throwing the
# structured error when the library set one. The call's own return value is
# handed back untouched; callers that receive a NULL pointer with no error
# treat it as absence.
function _checked(f, lib::AbstractString)
    _ensure_compatible(lib)
    err = Ref{Ptr{PioError}}(C_NULL)
    result = f(err)
    err[] == C_NULL || throw(_take_error(lib, err[]))
    return result
end

# Fill one output struct through a `bool f(..., T *output, PioError **error)`
# entry point. `call(out, err)` performs the ccall.
#
# Both cells are created here rather than by routing the call through
# `_checked`, and `call` is inlined, so that the cells and the `ccall` that
# writes them share one frame. The optimizer then places them in stack slots
# instead of on the heap, which the element tables read once per row. The
# checks keep `_checked`'s order: a library-reported error wins over a bare
# false return.
function _fill(call, ::Type{T}, lib::AbstractString) where {T}
    _ensure_compatible(lib)
    out = Ref{T}()
    err = Ref{Ptr{PioError}}(C_NULL)
    ok = @inline call(out, err)
    err[] == C_NULL || throw(_take_error(lib, err[]))
    ok || error("PowerIO: the library reported failure without an error record")
    return out[]
end
