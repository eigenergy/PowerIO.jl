@testset "GO Challenge 3 JSON helper" begin
    text = JSON3.write((
        network = (
            bus = [(uid = "bus_01",), (uid = "bus_00",)],
            shunt = [(uid = "sh_00",)],
            ac_line = [(uid = "acl_00",)],
            two_winding_transformer = [(uid = "xf_00",)],
            dc_line = [(uid = "dc_00",)],
            simple_dispatchable_device = [
                (uid = "sd_01", device_type = "consumer"),
                (uid = "sd_00", device_type = "producer"),
            ],
            violation_cost = (
                p_bus_vio_cost = 1.0,
                q_bus_vio_cost = 2.0,
                s_vio_cost = 3.0,
                e_vio_cost = 4.0,
            ),
        ),
        time_series_input = (
            general = (time_periods = 2, interval_duration = [1.0, 1.0]),
            simple_dispatchable_device = [
                (uid = "sd_00", p_lb = [0.0, 0.0]),
                (uid = "sd_01", p_lb = [0.0, 0.0]),
            ],
        ),
    ))
    data = PowerIO.parse_goc3_json(IOBuffer(text))

    @test data.raw["network"]["bus"][1]["uid"] == "bus_01"
    @test data.periods == 1:2
    @test data.bus_ids == ["bus_00", "bus_01"]
    @test data.bus_id_by_uid == Dict("bus_01" => 2, "bus_00" => 1)
    @test data.sdd_ids_producer == ["sd_00"]
    @test data.sdd_ids_consumer == ["sd_01"]
    @test data.ac_line_ids == ["acl_00"]
    @test data.twt_ids == ["xf_00"]
    @test data.dc_line_ids == ["dc_00"]
    @test isempty(data.azr_ids)
    @test isempty(data.rzr_ids)
    @test data.violation_cost["s_vio_cost"] == 3.0

    @test PowerIO.parse_goc3_json(data.raw).bus_ids == data.bus_ids

    flags = PowerIO.goc3_status_flags([0, 1, 1, 0], 1)
    @test flags.on_status == [0, 1, 1, 0]
    @test flags.su_status == [0, 1, 0, 0]
    @test flags.sd_status == [1, 0, 0, 1]

    uc_rows = [Dict("uid" => "sd_00", "on_status" => [1, 0, 1])]
    lookup = Dict("sd_00" => Dict("initial_status" => Dict("on_status" => 0)))
    @test PowerIO.goc3_add_status_flags!(uc_rows, lookup) === uc_rows
    @test uc_rows[1]["on_status"] == [1, 0, 1]
    @test uc_rows[1]["su_status"] == [1, 0, 1]
    @test uc_rows[1]["sd_status"] == [0, 1, 0]
end
