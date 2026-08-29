# The typed value accessors behind `PioModule` wrapping: each hands back an
# owned network with its retained source attached, so a same format write still
# echoes the retained source bytes. Defined after the network types so the
# constructors resolve.

function _module_balanced_network(m::StoredModule)
    lib = getfield(m, :lib)
    ptr = GC.@preserve m _v6_call(lib) do err
        ccall(_library_symbol(lib, :pio_module_balanced_network), Ptr{Cvoid},
              (Ptr{Cvoid}, Ref{Ptr{Cvoid}}), _module_ptr(m), err)
    end
    return BalancedNetwork(BalancedNetworkHandle(ptr, lib))
end

function _module_multiconductor_network(m::StoredModule)
    lib = getfield(m, :lib)
    ptr = GC.@preserve m _v6_call(lib) do err
        ccall(_library_symbol(lib, :pio_module_multiconductor_network), Ptr{Cvoid},
              (Ptr{Cvoid}, Ref{Ptr{Cvoid}}), _module_ptr(m), err)
    end
    return MulticonductorNetwork(MulticonductorNetworkHandle(ptr, lib))
end
