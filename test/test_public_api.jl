# The exported surface, pinned exactly. A name added or removed shows up here
# before it reaches a user.
const EXPORTED_NAMES = Set([
    :PowerIO,
    # operations
    :PioModule, :emit, :serialize, :deserialize,
    # values
    :BalancedNetwork, :MulticonductorNetwork, :TimeSeries, :ScenarioSet, :OperatingPoint,
    :DcPfInstance, :AcPfInstance, :DcOpfInstance, :AcOpfInstance,
    :McAcPfInstance, :McAcOpfInstance, :AcScucInstance,
    :DcPfSolution, :AcPfSolution, :DcOpfSolution, :AcOpfSolution, :SocwrOpfSolution,
    :McAcPfSolution, :McAcOpfSolution, :AcScucSolution, :UnknownValue,
    # records and results
    :Diagnostic, :SourceSpan, :PowerIOError, :EmitResult, :Artifact,
    :Producer, :ModuleSource, :HistoryEntry,
    # balanced network elements
    :Elements, :ComponentId, :TerminalReference, :Location, :Geo, :DetailedConnectivity,
    :Bus, :Branch, :Generator, :Load, :Shunt, :StaticVarCompensator, :Storage, :Switch, :Hvdc,
    :ThreeWindingTransformer, :Area,
    :LoadVoltageModel, :ShuntBlock, :ShuntControl, :TransformerControl, :BranchRating,
    :GeneratorCost, :GeneratorCapability, :ActivePowerControl, :HvdcConverter,
    :TransformerWinding, :TransformerImpedance, :reference_bus_ids,
    # multiconductor network elements
    :MulticonductorBus, :MulticonductorLineCode, :MulticonductorLine, :MulticonductorSwitch,
    :MulticonductorTransformer, :MulticonductorTransformerWinding, :MulticonductorLoad,
    :MulticonductorGenerator, :InverterBasedResource, :ControlProfile, :VoltVarControl,
    :VoltWattControl, :MulticonductorShunt, :MulticonductorCapacitor, :VoltageSource,
    :UntypedObject, :SourceCommand,
    # dense tables and graphs
    :to_dense, :to_graph,
    # matrices and vectors
    :calc_incidence_matrix, :calc_branch_susceptances, :calc_bus_susceptance_matrix,
    :calc_branch_flow_matrix, :calc_branch_phase_shift_injection, :calc_bus_phase_shift_injection,
    :calc_branch_flow_dc, :calc_bus_injection_dc,
    :calc_admittance_matrix, :calc_bprime_matrix, :calc_bdoubleprime_matrix, :BusMappedMatrix,
    # calculation constructions and solution access
    :to_dc_pf_instance, :to_ac_pf_instance, :to_dc_opf_instance, :to_ac_opf_instance,
    :to_mc_ac_pf_instance, :to_mc_ac_opf_instance, :time_count,
    # typed updates
    :ActivePower, :ReactivePower, :ApparentPower, :OperatingPointUpdate, :NetworkUpdate,
    :UpdateReport, :UpdateChange, :apply_updates!,
    :set_load_active_power, :set_load_reactive_power, :set_generator_active_power,
    :set_generator_reactive_power, :set_generator_voltage_magnitude, :set_generator_in_service,
    :set_branch_in_service, :set_transformer_tap_ratio, :set_transformer_phase_shift_degrees,
    :set_switch_closed, :set_branch_thermal_rating,
    # solver and modeling bridges
    :to_powermodels, :from_powermodels, :build_powermodels_ref, :repair_powermodels_angle_bounds!,
    :to_powerdata, :to_ac_power_data,
    # library resolution
    :set_library!, :clear_library!, :abi_version, :library_version, :library_available,
])

# Names the 0.10 binding exported and 1.0 removes. None may be defined.
const RETIRED_NAMES = [
    :parse_file, :parse_text, :parse_bytes, :write_file, :kind, :inspect, :source_format,
    :resolve_format, :FormatInfo, :list_states, :export_state, :to_balanced,
    :to_balanced_report, :to_normalized, :to_json, :from_json,
    :buses, :branches, :generators, :loads, :shunts, :storage, :hvdc, :lines, :linecodes,
    :switches, :transformers, :ibrs, :control_profiles, :capacitors, :voltage_sources,
    :untyped, :n_buses, :n_branches, :n_generators, :n_switches, :base_mva, :base_frequency,
    :network_name, :reference_bus_id, :reference_bus_positions, :n_islands, :is_radial,
    :to_bus_type_code, :to_arrow, :ArrowTable, :arrow_catalog, :arrow_available,
    :matrix_available, :gridfm_available, :dist_available, :prob_available,
    :features, :has_feature, :schema_versions, :build_info,
    :calc_branch_susceptance_matrix, :calc_phase_shift_injection,
    :history, :module_sources, :ModuleHistoryEntry, :StoredModule,
    :BalancedNetworkHandle, :MulticonductorNetworkHandle, :DcData,
]

@testset "public API" begin
    @test Set(names(PowerIO)) == EXPORTED_NAMES
    for name in RETIRED_NAMES
        @test !isdefined(PowerIO, name) || !Base.isexported(PowerIO, name)
    end
    # `parse` is a Base extension, never a PowerIO export.
    @test !(:parse in names(PowerIO))
    @test hasmethod(Base.parse, Tuple{AbstractString})
    @test hasmethod(Base.parse, Tuple{IO})
    @test hasmethod(Base.parse, Tuple{AbstractVector{UInt8}})
    @test PowerIO.PIO_ABI_VERSION == 7

    @testset "documentation names no removed operation" begin
        root = dirname(@__DIR__)
        pages = [joinpath(root, "docs", "src", p) for p in readdir(joinpath(root, "docs", "src"))
                 if endswith(p, ".md") && !startswith(p, "migration")]
        push!(pages, joinpath(root, "README.md"))
        retired = (r"\bparse_file\(", r"\bparse_text\(", r"\bto_json\(", r"\bfrom_json\(",
                   r"\blist_states\(", r"\bexport_state\(", r"\bto_balanced\(",
                   r"\bresolve_format\(", r"\bto_arrow\(", r"\bbuild_info\(", r"\bhas_feature\(",
                   r"\bn_buses\(", r"\bbuses\(", r"ABI 6", r"\.data\.", r"—")
        for page in pages
            text = read(page, String)
            for pattern in retired
                @test isnothing(match(pattern, text)) || "$(basename(page)) matches $(pattern.pattern)" == ""
            end
        end
        for src in readdir(joinpath(root, "src"); join=true)
            @test !occursin("—", read(src, String)) || "$(basename(src)) has an em dash" == ""
        end
    end
end
