@testset "Geographic layers" begin
    if !LIBRARY_AVAILABLE
        @test_skip "libpowerio_capi unavailable"
    else
        buscoords = "1, -89.6, 40.6\n2, -89.2, 39.8\n"
        feature_collection = """
        {"type": "FeatureCollection", "features": [
          {"type": "Feature", "geometry": {"type": "Point", "coordinates": [-89.6, 40.6]},
           "properties": {"bus": "1"}},
          {"type": "Feature", "geometry": {"type": "Point", "coordinates": [-89.2, 39.8]},
           "properties": {"bus": "2"}}]}
        """

        @testset "parse_geo" begin
            layer = parse_geo(buscoords)
            @test layer isa GeoLayer
            @test layer.diagnostics == Diagnostic[]
            @test occursin("FeatureCollection", layer.geojson)
            @test occursin("powerio_geo", layer.geojson)
            @test propertynames(layer) == (:geojson, :diagnostics)
            @test sprint(show, layer) == "GeoLayer()"
            # The canonical document reads back as itself.
            @test parse_geo(layer.geojson; name_hint="layer.geo.json").geojson == layer.geojson
            @test_throws PowerIOError parse_geo("not a geo file")
        end

        @testset "apply to a balanced module" begin
            case = parse(fixture("case9.m"))
            placed, report = apply_geo_layer(case, buscoords)
            @test placed isa PioModule{BalancedNetwork}
            @test report.matched_buses == 2
            @test report.matched_branches == 0
            @test report.unmatched_features == 0
            @test report.unlocated_buses == 7
            @test report.unlocated_branches == 9
            @test report.notes == String[]
            @test sprint(show, report) ==
                  "GeoApplyReport(2 buses, 0 branches matched, 0 features unmatched)"
            @test placed.value.buses[1].location.x == -89.6
            @test placed.value.buses[1].location.y == 40.6
            @test placed.value.buses[2].location.x == -89.2
            # The input module is unchanged.
            @test case.value.buses[1].location === nothing
            @test last(placed.history).name == "apply_geo_layer"

            wrong_kind = try
                apply_geo_layer(to_dc_pf_instance(case), parse_geo(buscoords))
                nothing
            catch e
                e
            end
            @test wrong_kind isa PowerIOError
            @test wrong_kind.code == "REQUEST.MODULE.WRONG_MODEL_KIND"
        end

        @testset "apply to a multiconductor module" begin
            feeder = parse(fixture("dist", "switch.dss"))
            placed, report = apply_geo_layer(feeder,
                                             "sourcebus, -89.6, 40.6\nloadbus, -89.2, 39.8\n")
            @test placed isa PioModule{MulticonductorNetwork}
            @test report.matched_buses == 2
            @test report.matched_branches == 0
            @test report.unmatched_features == 0
            @test report.unlocated_buses == 2
            @test report.unlocated_branches == 1
            @test report.notes == String[]
            @test placed.value.buses[1].location.y == 40.6
        end

        @testset "a layer as a module value" begin
            m = parse(codeunits(feature_collection); format="geojson", name="layer.geo.json")
            @test m isa PioModule{GeoLayer}
            @test occursin("FeatureCollection", m.value.geojson)
            # A value taken from a module carries no notes; the module holds them.
            @test m.value.diagnostics == Diagnostic[]

            placed, report = apply_geo_layer(parse(fixture("case9.m")), m.value)
            @test report.matched_buses == 2
            @test placed.value.buses[1].location.x == -89.6

            # The layer is copied out of the value, so it outlives the module.
            layer = m.value
            PowerIO.release!(PowerIO._handle(m))
            GC.gc()
            @test occursin("FeatureCollection", layer.geojson)
        end
    end
end
