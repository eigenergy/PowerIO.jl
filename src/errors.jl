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
function _take_error(lib::AbstractString, err::Ptr{Cvoid})
    code = _str(ccall(_library_symbol(lib, :pio_error_code), PioStringView, (Ptr{Cvoid},), err))
    message = _str(ccall(_library_symbol(lib, :pio_error_message), PioStringView, (Ptr{Cvoid},), err))
    diagnostics = _diagnostics(lib, ccall(_library_symbol(lib, :pio_error_diagnostics), Ptr{Cvoid},
                                           (Ptr{Cvoid},), err))
    ccall(_library_symbol(lib, :pio_error_release), Cvoid, (Ptr{Cvoid},), err)
    return PowerIOError(code, message, diagnostics)
end

# Run `f(err)` where `err` is the `PioError **` output parameter, throwing the
# structured error when the library set one. The call's own return value is
# handed back untouched; callers that receive a NULL pointer with no error
# treat it as absence.
function _checked(f, lib::AbstractString)
    err = Ref{Ptr{Cvoid}}(C_NULL)
    result = f(err)
    err[] == C_NULL || throw(_take_error(lib, err[]))
    return result
end

# Fill one output struct through a `bool f(..., T *output, PioError **error)`
# entry point. `call(out, err)` performs the ccall.
function _fill(call, ::Type{T}, lib::AbstractString) where {T}
    out = Ref{T}()
    ok = _checked(lib) do err
        call(out, err)
    end
    ok || error("PowerIO: the library reported failure without an error record")
    return out[]
end
