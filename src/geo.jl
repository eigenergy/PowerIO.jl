# The geographic layer: a coordinate document kept beside a case, read from
# five text forms and written as a GeoJSON FeatureCollection carrying a
# `powerio_geo` member.
#
# A layer taken from a module value is copied out of it, so it outlives the
# module the way a parsed layer does. Applying a layer derives a new module and
# leaves the input one unchanged; the C entry point is module level and covers
# balanced and multiconductor modules alike, so the Julia function takes and
# returns a module rather than a network.

"""
    parse_geo(text; name_hint=nothing) -> GeoLayer

Read a geographic layer from text. Headerless buscoords CSV, aliased CSV and
JSON records, and GeoJSON Point and LineString features all read. `name_hint`
is a file name whose extension picks CSV against JSON when the content alone is
ambiguous; without one the source is named `"<memory>"` and the content
decides. Text holding no usable coordinates throws [`PowerIOError`](@ref).
"""
function parse_geo(text::AbstractString; name_hint::Union{AbstractString,Nothing}=nothing)
    lib = _checked_lib()
    name = name_hint === nothing ? "<memory>" : String(name_hint)
    source = _source_from_memory(lib, name, codeunits(text))
    ptr = @with_handles source _checked(lib) do err
        @capi lib :pio_geo_layer_parse(_ptr(source), err)
    end
    release!(source)
    handle = GeoLayerHandle(ptr, lib)
    notes = @with_handles handle @capi lib :pio_geo_layer_diagnostics(_ptr(handle))
    return GeoLayer(handle, _diagnostics(lib, notes))
end

function Base.getproperty(layer::GeoLayer, name::Symbol)
    name === :geojson && return _with_handle(layer) do lib, p
        _take_string(lib, _checked(lib) do err
            @capi lib :pio_geo_layer_to_geojson(p, err)
        end)
    end
    return getfield(layer, name)
end

Base.propertynames(::GeoLayer, private::Bool=false) =
    private ? (:geojson, :diagnostics, :handle) : (:geojson, :diagnostics)

Base.show(io::IO, ::GeoLayer) = print(io, "GeoLayer()")

"""
    GeoApplyReport

What one [`apply_geo_layer`](@ref) pass did: how many buses and branches the
layer matched, how many of its features matched no element
(`unmatched_features`), how many buses and branches the derived network still
states no coordinates for, and the `notes` the pass recorded.
"""
struct GeoApplyReport
    matched_buses::Int
    matched_branches::Int
    unmatched_features::Int
    unlocated_buses::Int
    unlocated_branches::Int
    notes::Vector{String}
end

function Base.show(io::IO, r::GeoApplyReport)
    print(io, "GeoApplyReport(", r.matched_buses, " buses, ", r.matched_branches,
          " branches matched, ", r.unmatched_features, " features unmatched)")
end

# Decode one report handle in full.
function _geo_apply_report(lib::AbstractString, h::GeoApplyReportHandle)
    return @with_handles h begin
        p = _ptr(h)
        n = Int(@capi lib :pio_geo_apply_report_note_count(p))
        notes = String[_str(_checked(lib) do err
                           @capi lib :pio_geo_apply_report_note_at(p, Csize_t(k - 1), err)
                       end) for k in 1:n]
        GeoApplyReport(Int(@capi lib :pio_geo_apply_report_matched_buses(p)),
                       Int(@capi lib :pio_geo_apply_report_matched_branches(p)),
                       Int(@capi lib :pio_geo_apply_report_unmatched_features(p)),
                       Int(@capi lib :pio_geo_apply_report_unlocated_buses(p)),
                       Int(@capi lib :pio_geo_apply_report_unlocated_branches(p)),
                       notes)
    end
end

"""
    apply_geo_layer(m::PioModule, layer::GeoLayer) -> (PioModule, GeoApplyReport)
    apply_geo_layer(m::PioModule, text::AbstractString; name_hint=nothing) -> (PioModule, GeoApplyReport)

Place the coordinates of a geographic layer on a balanced or multiconductor
network module. The returned module is a new one carrying the coordinates and
the layer's notes; `m` is unchanged. The second returned value reports what
matched.

Python exposes this as a network method. Here it takes and returns a module,
because the C entry point is module level and one call serves both network
kinds. A module holding anything but a network throws [`PowerIOError`](@ref)
with code `"REQUEST.MODULE.WRONG_MODEL_KIND"`.
"""
function apply_geo_layer(m::PioModule, layer::GeoLayer)
    mh = _handle(m)
    lh = getfield(layer, :handle)
    lib = _lib_of(m)
    report = Ref{Ptr{LibPowerIO.PioGeoApplyReport}}(C_NULL)
    ptr = @with_handles mh lh report _checked(lib) do err
        @capi lib :pio_module_apply_geo_layer(_ptr(mh), _ptr(lh), report, err)
    end
    handle = GeoApplyReportHandle(report[], lib)
    decoded = _geo_apply_report(lib, handle)
    release!(handle)
    return _wrap_module(lib, ptr), decoded
end

apply_geo_layer(m::PioModule, text::AbstractString;
                name_hint::Union{AbstractString,Nothing}=nothing) =
    apply_geo_layer(m, parse_geo(text; name_hint=name_hint))
