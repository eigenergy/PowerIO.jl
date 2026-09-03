# Owned handles over the opaque C ABI 7 pointers.
#
# Every C handle family has a retain and a release entry point. A Julia handle
# owns one reference: its finalizer calls the family's release function through
# the library that allocated it, so a `set_library!` swap after allocation
# never crosses allocators. The release symbol is resolved before the handle is
# constructed; a failed lookup cannot strand a pointer without a finalizer.
#
# Owner rooting is a property of the C library, not of these wrappers: a
# network handle borrowed from a module keeps that module's data alive after
# the module handle is released. The wrappers only need to release what they
# own, in any order.

abstract type Handle end

# Define one mutable handle type whose finalizer calls `release`. The release
# symbol appears as a literal so the ABI coverage gate in the powerio repository
# checks it against the header.
macro handle(name, release, doc)
    quote
        Core.@doc $doc mutable struct $(esc(name)) <: Handle
            ptr::Ptr{Cvoid}
            lib::String
            function $(esc(name))(ptr::Ptr{Cvoid}, lib::AbstractString)
                ptr == C_NULL && error("PowerIO: null $($(string(name)))")
                lib = String(lib)
                free = _library_symbol(lib, $release)
                h = new(ptr, lib)
                finalizer(h) do x
                    x.ptr == C_NULL || ccall(free, Cvoid, (Ptr{Cvoid},), x.ptr)
                    x.ptr = C_NULL
                end
                return h
            end
        end
    end
end

@handle SourceHandle :pio_source_release "Acquired input bytes or path."
@handle DestinationHandle :pio_destination_release "Selected output location."
@handle ModuleHandle :pio_module_release "One `PioModule` inside the C library."
@handle ValueHandle :pio_value_release "View of a module value; keeps the module alive."
@handle BalancedNetworkHandle :pio_balanced_network_release "Balanced network; keeps its module alive."
@handle MulticonductorNetworkHandle :pio_multiconductor_network_release "Multiconductor network; keeps its module alive."
@handle DetailedConnectivityHandle :pio_detailed_connectivity_release "Detailed connectivity tables; keep their network alive."
@handle GeoLayerHandle :pio_geo_layer_release "Geographic layer; owns its own data."
@handle DiagnosticsHandle :pio_diagnostics_release "One diagnostics list."
@handle EmitResultHandle :pio_emit_result_release "Completed emission inventory."
@handle ArtifactHandle :pio_artifact_release "One emitted artifact."
@handle TimeSeriesHandle :pio_time_series_release "Time series; keeps its module alive."
@handle ScenarioSetHandle :pio_scenario_set_release "Scenario set; keeps its module alive."
@handle OperatingPointHandle :pio_operating_point_release "Operating point; keeps its module alive."
@handle CalculationInstanceHandle :pio_calculation_instance_release "Calculation instance; keeps its module alive."
@handle CalculationSolutionHandle :pio_calculation_solution_release "Calculation solution; keeps its module alive."
@handle ComponentIdHandle :pio_component_id_release "Stable component identity."
@handle ActivePowerHandle :pio_active_power_release "Active power with an explicit unit."
@handle ReactivePowerHandle :pio_reactive_power_release "Reactive power with an explicit unit."
@handle ApparentPowerHandle :pio_apparent_power_release "Apparent power with an explicit unit."
@handle OperatingPointUpdateHandle :pio_operating_point_update_release "One operating point update."
@handle NetworkUpdateHandle :pio_network_update_release "One network update."
@handle CalculationUpdateHandle :pio_calculation_update_release "One update ready to apply."
@handle UpdateReportHandle :pio_update_report_release "Report of one applied update batch."
@handle UpdateChangeHandle :pio_update_change_release "One change from an update report."
@handle SparseMatrixHandle :pio_sparse_matrix_release "Owned CSR matrix."
@handle VectorHandle :pio_vector_release "Owned double vector."
@handle StringHandle :pio_string_release "Owned string."
@handle JsonValueHandle :pio_json_value_release "Owned structured JSON value."

# Release a handle now instead of at finalization. Safe to call twice.
release!(h::Handle) = (finalize(h); nothing)

# Every ccall that takes a handle runs inside `GC.@preserve` of that handle;
# `_ptr` reads the pointer and refuses a released one.
function _ptr(h::Handle)
    p = getfield(h, :ptr)
    p == C_NULL && error("PowerIO: $(nameof(typeof(h))) was released")
    return p
end
