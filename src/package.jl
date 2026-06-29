# `.pio.json` compiler package envelope. The package payload is the same
# balanced JSON transport already handled by `from_json`; the Rust package
# validation and multiconductor lowering passes are not exposed through C ABI yet.

const PIO_PACKAGE_SCHEMA_URL = "https://powerio.dev/schema/pio-package/0.2"
const PIO_PACKAGE_SCHEMA_VERSION = "0.2.0"

"""
    CompilerPackage

JSON backed `.pio.json` compiler package envelope. A package carries one typed
payload plus model kind, producer, origin, validation, summary, and optional
derived metadata. `from_package` currently rebuilds balanced payloads into a
live [`BalancedNetwork`](@ref).
"""
struct CompilerPackage
    data::JSON3.Object
end

CompilerPackage(text::AbstractString) = CompilerPackage(JSON3.read(text))
CompilerPackage(data::AbstractDict) = CompilerPackage(JSON3.read(JSON3.write(data)))
CompilerPackage(data::NamedTuple) = CompilerPackage(JSON3.read(JSON3.write(data)))

Base.getproperty(pkg::CompilerPackage, name::Symbol) =
    name === :data ? getfield(pkg, :data) : getproperty(getfield(pkg, :data), name)
Base.propertynames(pkg::CompilerPackage) = propertynames(getfield(pkg, :data))
Base.show(io::IO, pkg::CompilerPackage) =
    print(io, "CompilerPackage{", package_model_kind(pkg), "}")

_validation_ok() = Dict(
    "status" => "ok",
    "counts" => Dict("fatal" => 0, "error" => 0, "warning" => 0, "info" => 0, "debug" => 0),
)

function _package_producer()
    version = try
        v = Base.pkgversion(@__MODULE__)
        v === nothing ? "unknown" : string(v)
    catch
        "unknown"
    end
    return Dict("tool" => "PowerIO.jl", "version" => version)
end

function _balanced_package_format_name(source::AbstractString)
    source == "Matpower" && return "matpower"
    source == "PowerModelsJson" && return "powermodels-json"
    source == "EgretJson" && return "egret-json"
    source == "Psse" && return "psse"
    source == "PowerWorld" && return "powerworld"
    source == "PandapowerJson" && return "pandapower-json"
    source == "Pslf" && return "pslf"
    source == "PowerWorldBinary" && return "powerworld-pwb"
    source == "Gridfm" && return "gridfm"
    source == "PypsaCsv" && return "pypsa-csv"
    source == "Normalized" && return "normalized"
    source == "InMemory" && return "in-memory"
    return lowercase(source)
end

function _balanced_package_origin(net::BalancedNetwork)
    source = source_format(net)
    fmt = _balanced_package_format_name(source)
    source == "InMemory" && return Dict("kind" => "in_memory")
    source == "Normalized" && return Dict(
        "kind" => "derived",
        "pass" => "normalize-balanced",
        "options" => Dict{String,Any}(),
    )
    source in ("Gridfm", "PypsaCsv") && return Dict(
        "kind" => "folder",
        "path" => "",
        "format" => fmt,
        "file_hashes" => Dict{String,String}(),
    )
    source == "PowerWorldBinary" && return Dict(
        "kind" => "binary_file",
        "path" => "",
        "format" => fmt,
        "decoded_sections" => String[],
    )
    return Dict("kind" => "file", "path" => "", "format" => fmt, "retained_source" => false)
end

function _balanced_package_sources(net::BalancedNetwork)
    source = source_format(net)
    source in ("InMemory", "Normalized") && return Any[]
    kind = source in ("Gridfm", "PypsaCsv") ? "folder" :
           source == "PowerWorldBinary" ? "binary_file" : "file"
    return Any[Dict(
        "id" => "src0",
        "kind" => kind,
        "format" => _balanced_package_format_name(source),
    )]
end

_count_table(net::BalancedNetwork, field::Symbol) =
    _has(net.data, field) ? length(getproperty(net.data, field)) : 0

function _balanced_package_summary(net::BalancedNetwork)
    elements = Dict(
        "buses" => n_buses(net),
        "loads" => length(loads(net)),
        "shunts" => length(shunts(net)),
        "branches" => length(branches(net)),
        "generators" => length(generators(net)),
        "storage" => length(storage(net)),
        "hvdc" => length(hvdc(net)),
        "transformers_3w" => _count_table(net, :transformers_3w),
    )
    refs = String[string(b.id) for b in buses(net) if String(b.kind) == "REF"]
    return Dict(
        "elements" => elements,
        "topology" => Dict("reference_buses" => refs),
        "units" => Dict("power" => "MW/MVAr", "angle" => "degrees", "base_mva" => base_mva(net)),
    )
end

_source_rows(values) = [x < 0 ? nothing : Int(x) for x in values]

function _normalized_solver_table_metadata(net::BalancedNetwork)
    bus = to_arrow(net, :solver_bus)
    load = to_arrow(net, :solver_load)
    shunt = to_arrow(net, :solver_shunt)
    branch = to_arrow(net, :solver_branch)
    switch = to_arrow(net, :solver_switch)
    arc = to_arrow(net, :solver_arc)
    gen = to_arrow(net, :solver_gen)
    storage_table = to_arrow(net, :solver_storage)
    hvdc_table = to_arrow(net, :solver_hvdc)

    n_branch = length(branch.index)
    from_arc = fill(-1, n_branch)
    to_arc = fill(-1, n_branch)
    for i in eachindex(arc.index)
        b = Int(arc.branch_index[i]) + 1
        if 1 <= b <= n_branch
            Int(arc.terminal[i]) == 0 ? (from_arc[b] = Int(arc.index[i])) :
                                        (to_arc[b] = Int(arc.index[i]))
        end
    end

    return Dict(
        "pass" => "balanced-to-normalized-solver-tables",
        "units" => Dict(
            "power" => "per_unit",
            "voltage" => "per_unit",
            "angle" => "radian",
            "impedance" => "per_unit",
            "admittance" => "per_unit",
            "dense_index_base" => "zero",
        ),
        "row_counts" => Dict(
            "buses" => length(bus.index),
            "loads" => length(load.index),
            "shunts" => length(shunt.index),
            "branches" => length(branch.index),
            "switches" => length(switch.index),
            "arcs" => length(arc.index),
            "generators" => length(gen.index),
            "storage" => length(storage_table.index),
            "hvdc" => length(hvdc_table.index),
        ),
        "bus_ids" => collect(Int, bus.bus_id),
        "reference_bus_indices" => [Int(bus.index[i]) for i in eachindex(bus.index)
                                    if bus.is_reference[i] != 0],
        "component_labels" => collect(Int, bus.component_label),
        "branch_from_arc_indices" => from_arc,
        "branch_to_arc_indices" => to_arc,
        "source_rows" => Dict(
            "buses" => _source_rows(bus.source_row),
            "loads" => _source_rows(load.source_row),
            "shunts" => _source_rows(shunt.source_row),
            "branches" => _source_rows(branch.source_row),
            "switches" => _source_rows(switch.source_row),
            "generators" => _source_rows(gen.source_row),
            "storage" => _source_rows(storage_table.source_row),
            "hvdc" => _source_rows(hvdc_table.source_row),
        ),
    )
end

"""
    to_package(net::BalancedNetwork; include_solver_metadata=false) -> CompilerPackage
    to_package(path; from=nothing, include_solver_metadata=false) -> CompilerPackage

Wrap a balanced network in the `.pio.json` compiler package envelope. The package
uses `model_kind = "balanced"` and embeds the same JSON payload that
[`to_json`](@ref) writes. Set `include_solver_metadata=true` to attach the
compact normalized solver table identity block from the Arrow solver tables;
that requires a loaded C library with the current Arrow table ids.
"""
function to_package(net::BalancedNetwork; include_solver_metadata::Bool=false)
    payload = _json_plain(JSON3.read(to_json(net)))
    package = Dict{String,Any}(
        "schema" => PIO_PACKAGE_SCHEMA_URL,
        "schema_version" => PIO_PACKAGE_SCHEMA_VERSION,
        "producer" => _package_producer(),
        "model_kind" => "balanced",
        "model" => Dict("kind" => "balanced", "balanced_network" => payload),
        "origin" => _balanced_package_origin(net),
        "validation" => _validation_ok(),
        "summary" => _balanced_package_summary(net),
    )
    sources = _balanced_package_sources(net)
    isempty(sources) || (package["sources"] = sources)
    if include_solver_metadata
        package["derived"] = Dict(
            "normalized_solver_tables" => _normalized_solver_table_metadata(net),
        )
    end
    return CompilerPackage(package)
end

to_package(path::AbstractString; from=nothing, include_solver_metadata::Bool=false) =
    to_package(parse_file(path; from=from); include_solver_metadata=include_solver_metadata)

"""
    package_model_kind(pkg::CompilerPackage) -> Symbol

Return the explicit package `model_kind`, for example `:balanced` or
`:multiconductor`.
"""
package_model_kind(pkg::CompilerPackage) = Symbol(String(pkg.data.model_kind))

function _ensure_package_kind_consistent(pkg::CompilerPackage)
    model_kind = String(pkg.data.model_kind)
    payload_kind = String(pkg.data.model.kind)
    model_kind == payload_kind || error(
        "PowerIO.from_package: model_kind `$model_kind` does not match model.kind `$payload_kind`")
    return model_kind
end

"""
    from_package(pkg::CompilerPackage) -> BalancedNetwork
    from_package(text::AbstractString) -> BalancedNetwork

Read a balanced `.pio.json` package back into a live [`BalancedNetwork`](@ref).
Multiconductor package payloads are detected but not lowered or materialized in
Julia yet; that needs package-level C ABI support from `powerio-pkg`.
"""
function from_package(pkg::CompilerPackage)
    kind = _ensure_package_kind_consistent(pkg)
    if kind == "balanced"
        return from_json(JSON3.write(pkg.data.model.balanced_network))
    elseif kind == "multiconductor"
        error("PowerIO.from_package: multiconductor packages require powerio-pkg C ABI support; use the BMOPF/PMD/DSS distribution APIs for now.")
    else
        error("PowerIO.from_package: unsupported package model_kind `$kind`")
    end
end

from_package(text::AbstractString) = from_package(CompilerPackage(text))

"""
    read_package(path) -> CompilerPackage

Read a `.pio.json` package envelope from disk.
"""
read_package(path::AbstractString) = CompilerPackage(read(path, String))

"""
    write_package(path, pkg_or_net; include_solver_metadata=false) -> String

Write a [`CompilerPackage`](@ref) or [`BalancedNetwork`](@ref) as `.pio.json` and
return `path`.
"""
function write_package(path::AbstractString, pkg::CompilerPackage)
    write(path, to_json(pkg))
    return path
end

function write_package(path::AbstractString, net::BalancedNetwork; include_solver_metadata::Bool=false)
    return write_package(path, to_package(net; include_solver_metadata=include_solver_metadata))
end

to_json(pkg::CompilerPackage) = JSON3.write(pkg.data)
