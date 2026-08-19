# The instance is the Rust core's projection, so this whole file needs the
# native library with the prob feature (on in every released binary since
# powerio v0.7.0). `parse_goc3_json`'s own coverage lives in test_goc3.jl.
if !(PowerIO.library_available() && PowerIO.scopf_available())
    @testset "GO Challenge 3 static index sets" begin
        @info "pio_scopf_* not exported (needs powerio-capi --features prob); skipping"
        @test_skip PowerIO.goc3_scopf_data("{}")
    end
else
@testset "GO Challenge 3 static index sets" begin
    # Minimal synthetic GOC3 document: 2 buses, 2 AC lines, 1 transformer,
    # 1 DC line, one producer + one consumer, one active and one reactive
    # reserve zone, 2 periods,
    # and two contingencies. Field values are chosen so the derived global
    # indices are hand-checkable.
    sdd_common = (
        on_cost = 1.0, startup_cost = 2.0, shutdown_cost = 3.0,
        p_reg_res_up_ub = 0.0, p_reg_res_down_ub = 0.0,
        p_syn_res_ub = 0.0, p_nsyn_res_ub = 0.0,
        p_ramp_res_up_online_ub = 0.0, p_ramp_res_up_offline_ub = 0.0,
        p_ramp_res_down_online_ub = 0.0, p_ramp_res_down_offline_ub = 0.0,
        startup_states = Vector{Vector{Float64}}(),
    )
    # One device per reactive capability mode, so both branches of the row builder
    # are covered and the unselected mode's NaN fields are observable.
    producer = (;
        uid = "sd_00", device_type = "producer", bus = "bus_00",
        initial_status = (on_status = 1, p = 10.0, q = 0.0),
        energy_req_ub = [[0.0, 2.0, 9.0]], energy_req_lb = [[0.0, 2.0, 1.0]],
        p_ramp_up_ub = 1.5, p_ramp_down_ub = 0.75,
        p_startup_ramp_ub = 0.5, p_shutdown_ramp_ub = 0.25,
        q_bound_cap = 1, q_linear_cap = 0,
        beta_ub = 0.31, beta_lb = -0.17, q_0_ub = 0.41, q_0_lb = -0.29,
        sdd_common...,
    )
    consumer = (;
        uid = "sd_01", device_type = "consumer", bus = "bus_01",
        initial_status = (on_status = 1, p = 4.0, q = 0.0),
        energy_req_ub = Vector{Vector{Float64}}(), energy_req_lb = Vector{Vector{Float64}}(),
        p_ramp_up_ub = 2.5, p_ramp_down_ub = 1.75,
        p_startup_ramp_ub = 1.25, p_shutdown_ramp_ub = 0.6,
        q_bound_cap = 0, q_linear_cap = 1, beta = 0.13, q_0 = 0.07,
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
            shunt = [(uid = "sh_00", bus = "bus_00", gs = 0.0, bs = 3.0)],
            ac_line = [
                (; uid = "acl_00", to_bus = "bus_01", fr_bus = "bus_00",
                   r = 0.0, x = 2.0, mva_ub_em = 7.0,
                   initial_status = (on_status = 1,), acx_common...),
                (; uid = "acl_01", to_bus = "bus_01", fr_bus = "bus_00",
                   r = 0.0, x = 1.0, mva_ub_em = 8.0,
                   initial_status = (on_status = 0,), acx_common...),
            ],
            two_winding_transformer = [
                (; uid = "xf_00", to_bus = "bus_01", fr_bus = "bus_00",
                   r = 0.0, x = 4.0, mva_ub_em = 6.0,
                   ta_lb = 0.0, ta_ub = 0.0, tm_lb = 1.0, tm_ub = 1.0,
                   initial_status = (ta = 0.0, tm = 1.0, on_status = 1), acx_common...),
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

    # --- the instance, typed off the Rust projection -----------------------
    scd = PowerIO.goc3_scopf_data(JSON3.write(doc))
    sc_data = scd.static
    lengths = scd.lengths
    for rows in (
        sc_data.bus, sc_data.shunt, sc_data.acl_branch, sc_data.acx_branch,
        sc_data.vpd, sc_data.fpd, sc_data.vwr, sc_data.fwr, sc_data.dc_branch,
        sc_data.prod, sc_data.cons, sc_data.active_reserve, sc_data.reactive_reserve,
        sc_data.active_reserve_set_pr, sc_data.active_reserve_set_cs,
        sc_data.reactive_reserve_set_pr, sc_data.reactive_reserve_set_cs,
    )
        @test isconcretetype(eltype(rows))
        @test eltype(rows) !== Any
    end
    # `isconcretetype && !== Any` is not enough: JSON3 reads an integer-valued number
    # ("1.0") as Int64, so an untyped row builder yields a concrete-but-wrong `Int64`
    # field (and a non-isbits `Any` field once a branch differs across rows). Pin the
    # declared Float64 fields so a builder that drops the typed comprehension is caught.
    @test length(sc_data.shunt) == 1 && sc_data.shunt[1].uid == "sh_00"
    @test fieldtype(eltype(sc_data.shunt), :g_sh) === Float64
    @test fieldtype(eltype(sc_data.shunt), :b_sh) === Float64
    # Per-class shunt index, document-order enumeration like the branch
    # classes, so a client stops re-deriving anything from the uid string.
    @test sc_data.shunt[1].j_sh == 1
    @test propertynames(sc_data.shunt[1])[1] === :j_sh
    @test fieldtype(eltype(sc_data.shunt), :j_sh) === Int
    @test fieldtype(eltype(sc_data.acl_branch), :s_max) === Float64
    @test fieldtype(eltype(sc_data.acx_branch), :s_max) === Float64
    @test fieldtype(eltype(sc_data.acx_branch), :g_fr) === Float64
    @test fieldtype(eltype(sc_data.dc_branch), :pdc_max) === Float64
    @test fieldtype(eltype(sc_data.active_reserve), :c_rgu) === Float64
    @test fieldtype(eltype(sc_data.active_reserve), :c_scr) === Float64
    @test fieldtype(eltype(sc_data.reactive_reserve), :c_qru) === Float64
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
    # The contingency count, so a client sizing per-contingency arrays does not
    # reach back into the raw document.
    @test lengths.K == 3
    @test lengths.K == length(data.raw["reliability"]["contingency"])

    @test [b.i for b in sc_data.bus] == [1, 2]
    @test length(sc_data.prod) == 1 && sc_data.prod[1].uid == "sd_00"
    @test length(sc_data.cons) == 1 && sc_data.cons[1].uid == "sd_01"

    # --- commitment ramp limits and initial operating point ------------------
    # A startup or shutdown power trajectory needs the two ramp limits, the initial
    # dispatch and the per-period p_lb series. Check each against the raw document
    # entry for the same device id, so the row is provably the whole read.
    for r in vcat(sc_data.prod, sc_data.cons)
        val = data.sdd_lookup[r.uid]
        ts_val = data.sdd_ts_lookup[r.uid]
        @test r.p_ru == Float64(val["p_ramp_up_ub"])
        @test r.p_rd == Float64(val["p_ramp_down_ub"])
        @test r.p_ru_su == Float64(val["p_startup_ramp_ub"])
        @test r.p_rd_sd == Float64(val["p_shutdown_ramp_ub"])
        @test r.p_0 == Float64(val["initial_status"]["p"])
        @test r.q_0 == Float64(val["initial_status"]["q"])
        @test r.p_min == Float64.(ts_val["p_lb"])
        @test r.p_max == Float64.(ts_val["p_ub"])
    end
    for f in (:p_ru, :p_rd, :p_ru_su, :p_rd_sd, :p_0, :q_0)
        @test fieldtype(eltype(sc_data.prod), f) === Float64
        @test fieldtype(eltype(sc_data.cons), f) === Float64
    end

    # --- reactive capability ------------------------------------------------
    # The producer declares the bound-cap mode, the consumer the linear-cap mode.
    # Each carries its own parameters and NaN for the mode it did not declare, so
    # a row read without checking its flag fails loudly.
    let p = sc_data.prod[1], c = sc_data.cons[1]
        @test (p.q_bound_cap, p.q_linear_cap) == (1, 0)
        @test (p.beta_ub, p.beta_lb, p.q_0_ub, p.q_0_lb) == (0.31, -0.17, 0.41, -0.29)
        @test isnan(p.beta) && isnan(p.q_p0)

        @test (c.q_bound_cap, c.q_linear_cap) == (0, 1)
        @test (c.beta, c.q_p0) == (0.13, 0.07)
        @test all(isnan, (c.beta_ub, c.beta_lb, c.q_0_ub, c.q_0_lb))

        # `q_p0` is the linear-cap intercept from the document's `q_0`; the row's
        # own `q_0` stays `initial_status.q`.
        @test p.q_0 == 0.0 && c.q_0 == 0.0

        # Setting neither mode is legal and common: every device on the official
        # C3E4N00073D1 scenario does it, leaving reactive power governed by
        # q_lb / q_ub alone. Every capability parameter is then NaN.
        neither = deepcopy(JSON3.read(JSON3.write(doc), Dict{String,Any}))
        for dev in neither["network"]["simple_dispatchable_device"]
            dev["q_bound_cap"] = 0
            dev["q_linear_cap"] = 0
        end
        nscd = PowerIO.goc3_scopf_data(JSON3.write(neither))
        for r in vcat(nscd.static.prod, nscd.static.cons)
            @test (r.q_bound_cap, r.q_linear_cap) == (0, 0)
            @test all(isnan, (r.beta_ub, r.beta_lb, r.q_0_ub, r.q_0_lb, r.beta, r.q_p0))
        end
        for f in (:q_bound_cap, :q_linear_cap)
            @test fieldtype(eltype(sc_data.prod), f) === Int
        end
        for f in (:beta_ub, :beta_lb, :q_0_ub, :q_0_lb, :beta, :q_p0)
            @test fieldtype(eltype(sc_data.prod), f) === Float64
        end
    end

    # Both mode flags are required: a device declaring neither leaves its reactive
    # power unconstrained, which is a malformed case rather than a default.
    let bad = deepcopy(JSON3.read(JSON3.write(doc), Dict{String,Any}))
        delete!(bad["network"]["simple_dispatchable_device"][1], "q_bound_cap")
        @test_throws ErrorException PowerIO.goc3_scopf_data(JSON3.write(bad))
    end
    @test sc_data.acl_branch[1].j_ln == 1 && sc_data.acl_branch[2].j_ln == 2
    @test sc_data.acx_branch[1].j_xf == 1   # per-class only; client adds j_ac = j_xf + L_J_ln
    @test !hasproperty(sc_data.acx_branch[1], :j_ac)
    @test !hasproperty(sc_data.acl_branch[1], :j_ac)
    @test sc_data.dc_branch[1].j_dc == 1
    @test isempty(sc_data.vpd) && isempty(sc_data.vwr)      # bounds equal -> fixed
    @test length(sc_data.fpd) == 1 && length(sc_data.fwr) == 1
    @test sc_data.fpd[1].j_xf == 1 && !hasproperty(sc_data.fpd[1], :j_ac)
    @test sc_data.fwr[1].j_xf == 1 && !hasproperty(sc_data.fwr[1], :j_ac)
    @test sc_data.active_reserve[1].n_p == 1 && !hasproperty(sc_data.active_reserve[1], :n)
    @test sc_data.reactive_reserve[1].n_q == 1 && !hasproperty(sc_data.reactive_reserve[1], :n)
    @test sc_data.active_reserve_set_pr[1].n_p == 1 && !hasproperty(sc_data.active_reserve_set_pr[1], :n)
    @test sc_data.active_reserve_set_cs[1].n_p == 1 && !hasproperty(sc_data.active_reserve_set_cs[1], :n)
    @test sc_data.reactive_reserve_set_pr[1].n_q == 1 && !hasproperty(sc_data.reactive_reserve_set_pr[1], :n)
    @test sc_data.reactive_reserve_set_cs[1].n_q == 1 && !hasproperty(sc_data.reactive_reserve_set_cs[1], :n)

    # --- energy windows ----------------------------------------------------
    ew = scd.energy_windows
    for rows in (
        ew.W_en_max_pr, ew.W_en_max_cs, ew.W_en_min_pr, ew.W_en_min_cs,
        ew.T_w_en_max_pr, ew.T_w_en_max_cs, ew.T_w_en_min_pr, ew.T_w_en_min_cs,
    )
        @test isconcretetype(eltype(rows))
        @test eltype(rows) !== Any
    end
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
    pjtm_pr = scd.price_blocks.producer
    pjtm_cs = scd.price_blocks.consumer
    @test length(pjtm_pr) == 2               # 2 periods x 1 block
    @test [r.flat_k for r in pjtm_pr] == [1, 2]
    @test [r.t for r in pjtm_pr] == [1, 2]
    @test pjtm_pr[1].c_en == 10.0 && pjtm_pr[1].p_max == 5.0
    @test pjtm_pr[2].c_en == 11.0 && pjtm_pr[2].p_max == 6.0
    @test pjtm_pr[1].uid == "sd_00"
    @test length(pjtm_cs) == 2 && pjtm_cs[1].uid == "sd_01"

    # --- AC contingency survivors -----------------------------------------
    surv = scd.ac_contingency_survivors
    @test all(isconcretetype(eltype(rows)) && eltype(rows) !== Any for rows in surv.ln)
    @test all(isconcretetype(eltype(rows)) && eltype(rows) !== Any for rows in surv.xf)
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
    jtk_dc = scd.dc_contingency_flows
    @test isconcretetype(eltype(jtk_dc))
    @test eltype(jtk_dc) !== Any
    # ctg_00 and ctg_02: dc_00 survives x 2 periods; ctg_01 outages dc_00.
    @test length(jtk_dc) == 4
    @test [r.ctg for r in jtk_dc] == [1, 1, 3, 3]
    @test [r.t for r in jtk_dc] == [1, 2, 1, 2]
    @test jtk_dc[1].ctg == 1 && jtk_dc[1].j_dc == 1

    # --- the instance object ------------------------------------------------
    @test scd isa PowerIO.ScopfInstance
    # Seven type parameters make the default show unreadable; report the sizes.
    scd_shown = sprint(show, scd)
    @test startswith(scd_shown, "ScopfInstance(")
    @test occursin("$(scd.lengths.I) buses", scd_shown)
    @test occursin("$(scd.lengths.L_T) periods", scd_shown)
    @test occursin("$(scd.lengths.K) contingencies", scd_shown)
    @test occursin("$(scd.lengths.L_J_pr) producers", scd_shown)
    @test !occursin("ScopfInstance{", scd_shown)
    @test scd.violation_cost == (p_bus = 1.0, q_bus = 1.0, s = 1.0, e = 1.0)
    @test scd.device_class_layout == PowerIO.DeviceClassLayout(:contiguous, true)
    @test scd.dt == [1.0, 1.0]

    # --- the ordinals and initial status the rows carry ---------------------
    @test (sc_data.prod[1].j_dev, sc_data.prod[1].j_sdd) == (1, 1)
    @test (sc_data.cons[1].j_dev, sc_data.cons[1].j_sdd) == (1, 2)
    @test (sc_data.prod[1].u_0, sc_data.cons[1].u_0) == (1, 1)
    @test [b.u_0 for b in sc_data.acl_branch] == [1, 0]
    @test sc_data.acx_branch[1].u_0 == 1
    @test (sc_data.active_reserve_set_pr[1].j_dev, sc_data.active_reserve_set_pr[1].j_sdd) == (1, 1)
    @test (sc_data.reactive_reserve_set_cs[1].j_dev, sc_data.reactive_reserve_set_cs[1].j_sdd) == (1, 2)

    # --- the typed status-flags method ---------------------------------------
    let uc = [Dict{String,Any}("uid" => "sd_00", "on_status" => [0, 1]),
              Dict{String,Any}("uid" => "sd_01", "on_status" => [1, 0])]
        PowerIO.goc3_add_status_flags!(uc, vcat(sc_data.prod, sc_data.cons))
        @test uc[1]["su_status"] == [0, 1]   # u_0 = 1, drops to 0 then starts
        @test uc[1]["sd_status"] == [1, 0]
        @test uc[2]["su_status"] == [0, 0]   # u_0 = 1, stays on then shuts down
        @test uc[2]["sd_status"] == [0, 1]
    end

    # Interleaved device classes are data, never a warning: the ordinals come
    # from enumeration, and the layout reports that no offset scheme holds.
    let mixed = deepcopy(JSON3.read(JSON3.write(doc), Dict{String,Any}))
        devs = mixed["network"]["simple_dispatchable_device"]
        push!(devs, merge(deepcopy(devs[1]), Dict("uid" => "sd_02")))
        push!(devs, merge(deepcopy(devs[2]), Dict("uid" => "sd_03")))
        ts = mixed["time_series_input"]["simple_dispatchable_device"]
        push!(ts, merge(deepcopy(ts[1]), Dict("uid" => "sd_02")))
        push!(ts, merge(deepcopy(ts[2]), Dict("uid" => "sd_03")))
        # document order producer, consumer, producer, consumer: three-plus runs.
        mixed_scd = @test_logs PowerIO.goc3_scopf_data(JSON3.write(mixed))
        @test mixed_scd.device_class_layout == PowerIO.DeviceClassLayout(:interleaved, nothing)
        @test [r.j_dev for r in mixed_scd.static.prod] == [1, 2]
        @test [r.j_sdd for r in mixed_scd.static.prod] == [1, 2]
        @test [r.j_sdd for r in mixed_scd.static.cons] == [3, 4]
    end
end

# A real ARPA-E GO Competition Challenge 3 case, parsed from a JSON file, exercises
# the file-read branch of parse_goc3_json (the in-memory doc above covers the
# IOBuffer/Dict paths) and runs the five SCOPF builders at real scale. The case is
# `14bus_20220707.json` from GOCompetition's own C3DataUtilities validation repo
# (pinned commit), a 14-bus 24-period scenario. At ~340 KB it is too large to vendor,
# so it is git-ignored (see .gitignore) and fetched on demand: in CI, and locally the
# first time this runs. If it is absent and cannot be downloaded (offline), the test
# skips, mirroring how the C-ABI tests skip when the native library is missing.
const GOC3_REAL_CASE_URL =
    "https://raw.githubusercontent.com/GOCompetition/C3DataUtilities/" *
    "bb5df337553b21ab8be89ae5f9106958541730d4/test_data/14bus_20220707.json"

@testset "GOC3 static index sets from a real Challenge 3 case" begin
    path = joinpath(@__DIR__, "data", "goc3_14bus_20220707.json")
    if !isfile(path)
        try
            Base.download(GOC3_REAL_CASE_URL, path)
        catch err
            isfile(path) && rm(path; force = true)  # drop a partial download
            @info "GOC3 real-case fixture unavailable (offline?); skipping real-case parse" exception = err
        end
    end

    if !isfile(path)
        @test_skip PowerIO.parse_goc3_json(path)
    else
        data = PowerIO.parse_goc3_json(path)
        @test length(data.bus_ids) == 14
        @test data.periods == 1:24

        scd = PowerIO.goc3_scopf_data(read(path, String))
        sc_data = scd.static
        lengths = scd.lengths
        # Counts pinned to this specific scenario (14 buses, 17 AC lines, 3 transformers,
        # no DC lines, 6 producers, 11 consumers, 24 periods).
        @test lengths.I == 14
        @test (lengths.L_J_ln, lengths.L_J_xf, lengths.L_J_dc) == (17, 3, 0)
        @test (lengths.L_J_pr, lengths.L_J_cs, lengths.L_T) == (6, 11, 24)
        @test length(sc_data.prod) == 6 && length(sc_data.cons) == 11
        @test [b.i for b in sc_data.bus] == collect(1:14)
        @test lengths.K == length(data.raw["reliability"]["contingency"])
        # Every per-class index is document-order enumeration, so this case's
        # named uids ("Shunt Bus 6", "Line 0") change nothing: `j_sh == 1` with
        # `L_J_sh == 1`, and an array sized by a length is always indexable by
        # its class's ordinals. The uid-suffix builders that once made this
        # file's indices unsound are retired.
        @test [s.j_sh for s in sc_data.shunt] == collect(1:lengths.L_J_sh)
        @test [s.j_ln for s in sc_data.acl_branch] == collect(1:lengths.L_J_ln)
        @test [r.j_dev for r in sc_data.prod] == collect(1:lengths.L_J_pr)
        @test [r.j_sdd for r in sc_data.cons] ==
              collect(lengths.L_J_pr .+ (1:lengths.L_J_cs))
        # The two reactive capability modes are mutually exclusive; a device may set
        # neither (every device on the official C3E4N00073D1 scenario does, though
        # every device on this one sets exactly one). Whichever mode is set has
        # finite parameters and the other's are NaN.
        for r in vcat(sc_data.prod, sc_data.cons)
            @test r.q_bound_cap + r.q_linear_cap <= 1
            bound = (r.beta_ub, r.beta_lb, r.q_0_ub, r.q_0_lb)
            linear = (r.beta, r.q_p0)
            @test all(r.q_bound_cap == 1 ? isfinite : isnan, bound)
            @test all(r.q_linear_cap == 1 ? isfinite : isnan, linear)
        end
        @test any(r -> r.q_bound_cap == 1 || r.q_linear_cap == 1,
                  vcat(sc_data.prod, sc_data.cons))

        # The ramp limits and initial dispatch a startup or shutdown trajectory
        # needs, on all 17 devices of a real scenario, each against the raw
        # document entry for the same device id.
        @test length(vcat(sc_data.prod, sc_data.cons)) == 17
        for r in vcat(sc_data.prod, sc_data.cons)
            val = data.sdd_lookup[r.uid]
            ts_val = data.sdd_ts_lookup[r.uid]
            @test r.p_ru == Float64(val["p_ramp_up_ub"])
            @test r.p_rd == Float64(val["p_ramp_down_ub"])
            @test r.p_ru_su == Float64(val["p_startup_ramp_ub"])
            @test r.p_rd_sd == Float64(val["p_shutdown_ramp_ub"])
            @test r.p_0 == Float64(val["initial_status"]["p"])
            @test r.q_0 == Float64(val["initial_status"]["q"])
            @test r.p_min == Float64.(ts_val["p_lb"])
            @test r.p_max == Float64.(ts_val["p_ub"])
            @test length(r.p_min) == lengths.L_T
        end

        @test propertynames(scd.violation_cost) == (:p_bus, :q_bus, :s, :e)
        # This case omits `e_vio_cost`, which is why the four prices are optional.
        @test all(isfinite, (scd.violation_cost.p_bus, scd.violation_cost.q_bus,
                             scd.violation_cost.s))
        @test isnan(scd.violation_cost.e)
        @test !haskey(data.violation_cost, "e_vio_cost")
        # The document lists its six producers before its eleven consumers.
        @test scd.device_class_layout == PowerIO.DeviceClassLayout(:contiguous, true)
        @test length(scd.dt) == lengths.L_T
        for rows in (sc_data.bus, sc_data.acl_branch, sc_data.acx_branch, sc_data.dc_branch,
                     sc_data.prod, sc_data.cons)
            @test isconcretetype(eltype(rows)) && eltype(rows) !== Any
        end

        ew = scd.energy_windows
        for rows in (ew.W_en_max_pr, ew.W_en_max_cs, ew.W_en_min_pr, ew.W_en_min_cs)
            @test isconcretetype(eltype(rows)) && eltype(rows) !== Any
        end

        pjtm_pr = scd.price_blocks.producer
        pjtm_cs = scd.price_blocks.consumer
        # Total (device, period, cost-block) rows, pinned to this scenario's cost curves.
        @test length(pjtm_pr) == 720 && length(pjtm_cs) == 1056

        surv = scd.ac_contingency_survivors
        @test length(surv.ln) == 19 && length(surv.xf) == 19      # one group per contingency
        @test all(isconcretetype(eltype(r)) && eltype(r) !== Any for r in surv.ln)
        @test all(isconcretetype(eltype(r)) && eltype(r) !== Any for r in surv.xf)

        jtk_dc = scd.dc_contingency_flows
        @test isempty(jtk_dc)                                     # no DC lines in this case
    end
end

end # library gate
