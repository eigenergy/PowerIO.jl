@testset "GO Challenge 3 static index sets" begin
    # Minimal synthetic GOC3 document: 2 buses, 2 AC lines, 1 transformer,
    # 1 DC line, one producer + one consumer, one active and one reactive
    # reserve zone, 2 periods,
    # and two contingencies. Field values are chosen so the derived global
    # indices are hand-checkable.
    sdd_common = (
        on_cost = 1.0, startup_cost = 2.0, shutdown_cost = 3.0,
        p_ramp_up_ub = 1.0, p_ramp_down_ub = 1.0,
        p_startup_ramp_ub = 1.0, p_shutdown_ramp_ub = 1.0,
        p_reg_res_up_ub = 0.0, p_reg_res_down_ub = 0.0,
        p_syn_res_ub = 0.0, p_nsyn_res_ub = 0.0,
        p_ramp_res_up_online_ub = 0.0, p_ramp_res_up_offline_ub = 0.0,
        p_ramp_res_down_online_ub = 0.0, p_ramp_res_down_offline_ub = 0.0,
        startup_states = Vector{Vector{Float64}}(),
    )
    producer = (;
        uid = "sd_00", device_type = "producer", bus = "bus_00",
        initial_status = (on_status = 1, p = 10.0, q = 0.0),
        energy_req_ub = [[0.0, 2.0, 9.0]], energy_req_lb = [[0.0, 2.0, 1.0]],
        sdd_common...,
    )
    consumer = (;
        uid = "sd_01", device_type = "consumer", bus = "bus_01",
        initial_status = (on_status = 1, p = 4.0, q = 0.0),
        energy_req_ub = Vector{Vector{Float64}}(), energy_req_lb = Vector{Vector{Float64}}(),
        sdd_common...,
    )
    sdd_ts_common = (
        p_reg_res_up_cost = [0.0, 0.0], p_reg_res_down_cost = [0.0, 0.0],
        p_syn_res_cost = [0.0, 0.0], p_nsyn_res_cost = [0.0, 0.0],
        p_ramp_res_up_online_cost = [0.0, 0.0], p_ramp_res_up_offline_cost = [0.0, 0.0],
        p_ramp_res_down_online_cost = [0.0, 0.0], p_ramp_res_down_offline_cost = [0.0, 0.0],
        q_res_up_cost = [0.0, 0.0], q_res_down_cost = [0.0, 0.0],
        p_ub = [5.0, 5.0], q_ub = [1.0, 1.0], q_lb = [-1.0, -1.0],
    )

    acx_common = (
        connection_cost = 0.0, disconnection_cost = 0.0, mva_ub_nom = 1.0,
        b = 0.0, additional_shunt = 0,
    )
    doc = (
        network = (
            bus = [(uid = "bus_00", vm_lb = 0.9, vm_ub = 1.1,
                    active_reserve_uids = ["azr_00"], reactive_reserve_uids = ["rzr_00"]),
                   (uid = "bus_01", vm_lb = 0.9, vm_ub = 1.1,
                    active_reserve_uids = ["azr_00"], reactive_reserve_uids = ["rzr_00"])],
            shunt = Any[],
            ac_line = [
                (; uid = "acl_00", to_bus = "bus_01", fr_bus = "bus_00",
                   r = 0.0, x = 2.0, mva_ub_em = 7.0, acx_common...),
                (; uid = "acl_01", to_bus = "bus_01", fr_bus = "bus_00",
                   r = 0.0, x = 1.0, mva_ub_em = 8.0, acx_common...),
            ],
            two_winding_transformer = [
                (; uid = "xf_00", to_bus = "bus_01", fr_bus = "bus_00",
                   r = 0.0, x = 4.0, mva_ub_em = 6.0,
                   ta_lb = 0.0, ta_ub = 0.0, tm_lb = 1.0, tm_ub = 1.0,
                   initial_status = (ta = 0.0, tm = 1.0), acx_common...),
            ],
            dc_line = [(uid = "dc_00", to_bus = "bus_01", fr_bus = "bus_00",
                        pdc_ub = 1.0, qdc_fr_lb = -1.0, qdc_to_lb = -1.0,
                        qdc_fr_ub = 1.0, qdc_to_ub = 1.0)],
            simple_dispatchable_device = [producer, consumer],
            active_zonal_reserve = [(
                uid = "azr_00",
                REG_UP_vio_cost = 1.0, REG_DOWN_vio_cost = 1.0,
                SYN_vio_cost = 1.0, NSYN_vio_cost = 1.0,
                RAMPING_RESERVE_UP_vio_cost = 1.0,
                RAMPING_RESERVE_DOWN_vio_cost = 1.0,
                REG_UP = 1.0, REG_DOWN = 1.0, SYN = 1.0, NSYN = 1.0,
            )],
            reactive_zonal_reserve = [(
                uid = "rzr_00",
                REACT_UP_vio_cost = 1.0,
                REACT_DOWN_vio_cost = 1.0,
            )],
            violation_cost = (p_bus_vio_cost = 1.0, q_bus_vio_cost = 1.0,
                              s_vio_cost = 1.0, e_vio_cost = 1.0),
        ),
        time_series_input = (
            general = (time_periods = 2, interval_duration = [1.0, 1.0]),
            simple_dispatchable_device = [
                (; uid = "sd_00", cost = [[[10.0, 5.0]], [[11.0, 6.0]]],
                   p_lb = [2.0, 3.0], sdd_ts_common...),
                (; uid = "sd_01", cost = [[[20.0, 5.0]], [[21.0, 6.0]]],
                   p_lb = [0.0, 0.0], sdd_ts_common...),
            ],
            active_zonal_reserve = [(
                uid = "azr_00",
                RAMPING_RESERVE_UP = [0.0, 0.0],
                RAMPING_RESERVE_DOWN = [0.0, 0.0],
            )],
            reactive_zonal_reserve = [(
                uid = "rzr_00",
                REACT_UP = [0.0, 0.0],
                REACT_DOWN = [0.0, 0.0],
            )],
        ),
        reliability = (contingency = [
            (uid = "ctg_00", components = ["acl_00"]),
            (uid = "ctg_01", components = ["dc_00"]),
            (uid = "ctg_02", components = ["acl_00", "xf_00"]),
        ],),
    )

    data = PowerIO.parse_goc3_json(IOBuffer(JSON3.write(doc)))

    # --- interval helper ---------------------------------------------------
    @test PowerIO.goc3_interval_bounds([1.0, 1.0], 2) == (1.0, 1.5, 2.0)

    # --- static data -------------------------------------------------------
    sc_data, lengths, cost_pr, cost_cs = PowerIO.goc3_static_data(data)
    @test lengths.L_J_ln == 2
    @test lengths.L_J_xf == 1
    @test lengths.L_J_ac == 3
    @test lengths.L_J_dc == 1
    @test lengths.L_J_br == 4
    @test lengths.L_J_pr == 1
    @test lengths.L_J_cs == 1
    @test lengths.L_J_cspr == 2
    @test lengths.I == 2
    @test lengths.L_T == 2
    @test lengths.L_N_p == 1
    @test lengths.L_N_q == 1

    @test [b.i for b in sc_data.bus] == [1, 2]
    @test length(sc_data.prod) == 1 && sc_data.prod[1].uid == "sd_00"
    @test length(sc_data.cons) == 1 && sc_data.cons[1].uid == "sd_01"
    @test sc_data.acl_branch[1].j_ln == 1 && sc_data.acl_branch[2].j_ln == 2
    @test sc_data.acx_branch[1].j_xf == 1   # per-class only; client adds j_ac = j_xf + L_J_ln
    @test !hasproperty(sc_data.acx_branch[1], :j_ac)
    @test !hasproperty(sc_data.acl_branch[1], :j_ac)
    @test sc_data.dc_branch[1].j_dc == 1
    @test isempty(sc_data.vpd) && isempty(sc_data.vwr)      # bounds equal -> fixed
    @test length(sc_data.fpd) == 1 && length(sc_data.fwr) == 1
    @test sc_data.fpd[1].j_xf == 1 && !hasproperty(sc_data.fpd[1], :j_ac)
    @test sc_data.fwr[1].j_xf == 1 && !hasproperty(sc_data.fwr[1], :j_ac)
    @test cost_pr[1].uid == "sd_00" && cost_cs[1].uid == "sd_01"
    @test sc_data.active_reserve[1].n_p == 1 && !hasproperty(sc_data.active_reserve[1], :n)
    @test sc_data.reactive_reserve[1].n_q == 1 && !hasproperty(sc_data.reactive_reserve[1], :n)
    @test sc_data.active_reserve_set_pr[1].n_p == 1 && !hasproperty(sc_data.active_reserve_set_pr[1], :n)
    @test sc_data.active_reserve_set_cs[1].n_p == 1 && !hasproperty(sc_data.active_reserve_set_cs[1], :n)
    @test sc_data.reactive_reserve_set_pr[1].n_q == 1 && !hasproperty(sc_data.reactive_reserve_set_pr[1], :n)
    @test sc_data.reactive_reserve_set_cs[1].n_q == 1 && !hasproperty(sc_data.reactive_reserve_set_cs[1], :n)

    # --- energy windows ----------------------------------------------------
    ew = PowerIO.goc3_energy_windows(data)
    @test length(ew.W_en_max_pr) == 1
    @test ew.W_en_max_pr[1].uid == "sd_00"
    @test ew.W_en_max_pr[1].e_max == 9.0
    @test ew.W_en_max_pr[1].a_en_max_end == 2.0
    @test isempty(ew.W_en_max_cs)              # consumer has no windows
    @test length(ew.W_en_min_pr) == 1 && ew.W_en_min_pr[1].e_min == 1.0
    # both period midpoints (0.5, 1.5) fall inside [0, 2]
    @test length(ew.T_w_en_max_pr) == 2
    @test [r.t for r in ew.T_w_en_max_pr] == [1, 2]
    @test length(ew.T_w_en_min_pr) == 2

    # --- price blocks ------------------------------------------------------
    pjtm_pr, pjtm_cs = PowerIO.goc3_price_blocks(cost_pr, cost_cs)
    @test length(pjtm_pr) == 2               # 2 periods x 1 block
    @test [r.flat_k for r in pjtm_pr] == [1, 2]
    @test [r.t for r in pjtm_pr] == [1, 2]
    @test pjtm_pr[1].c_en == 10.0 && pjtm_pr[1].p_max == 5.0
    @test pjtm_pr[2].c_en == 11.0 && pjtm_pr[2].p_max == 6.0
    @test pjtm_pr[1].uid == "sd_00"
    @test length(pjtm_cs) == 2 && pjtm_cs[1].uid == "sd_01"

    # --- AC contingency survivors -----------------------------------------
    surv = PowerIO.goc3_ac_contingency_survivors(data, lengths)
    @test length(surv.ln) == 3               # one group per contingency
    @test length(surv.ln[1]) == 1            # ctg_00 outages acl_00 -> acl_01 survives
    @test surv.ln[1][1].uid == "acl_01"
    @test surv.ln[1][1].ctg == 1
    @test surv.ln[1][1].j_ln == 2
    @test surv.ln[1][1].b_sr == -1.0        # -x/(x^2+r^2) = -1/(1+0)
    @test surv.ln[1][1].s_max_ctg == 8.0    # mva_ub_em
    @test !hasproperty(surv.ln[1][1], :j_ac)
    @test length(surv.ln[2]) == 2            # ctg_01 outages dc_00 -> both lines survive
    @test surv.xf[1][1].j_xf == 1             # transformer survives ctg_00
    @test !hasproperty(surv.xf[1][1], :j_ac)
    @test length(surv.ln[3]) == 1 && surv.ln[3][1].uid == "acl_01"
    @test isempty(surv.xf[3])                # ctg_02 also outages xf_00

    # --- DC contingency flows ---------------------------------------------
    jtk_dc = PowerIO.goc3_dc_contingency_flows(data)
    # ctg_00 and ctg_02: dc_00 survives x 2 periods; ctg_01 outages dc_00.
    @test length(jtk_dc) == 4
    @test [r.ctg for r in jtk_dc] == [1, 1, 3, 3]
    @test [r.t for r in jtk_dc] == [1, 2, 1, 2]
    @test jtk_dc[1].ctg == 1 && jtk_dc[1].j_dc == 1
end
