# Migration gate: the Rust-backed typed rows must agree with the Julia
# projection everywhere the two index conventions coincide. The small fixture
# follows the official uid convention (suffix == document order), so every
# shared field must be equal; the 14-bus validation case does not, which is
# the divergence the migration removes. This file is deleted with the Julia
# projection once the swap lands.
@testset "scopf parity" begin
    small = joinpath(@__DIR__, "data", "goc3_small.json")
    text = read(small, String)
    old = PowerIO.goc3_scopf_data(PowerIO.parse_goc3_json(small))
    new = PowerIO._scopf_instance_tables(PowerIO.parse_scopf(text))

    strip_new(rows, keep) = [NamedTuple{keep}(r) for r in rows]
    same_rows(new_rows, old_rows) = begin
        keep = fieldnames(eltype(old_rows))
        isequal(strip_new(new_rows, keep), collect(old_rows))
    end

    for name in (:bus, :shunt, :acl_branch, :acx_branch, :vpd, :fpd, :vwr, :fwr,
                 :dc_branch, :prod, :cons, :active_reserve, :reactive_reserve,
                 :active_reserve_set_pr, :active_reserve_set_cs,
                 :reactive_reserve_set_pr, :reactive_reserve_set_cs)
        @test same_rows(getproperty(new.static, name), getproperty(old.static, name))
    end
    @test new.lengths == old.lengths
    for name in propertynames(old.energy_windows)
        @test getproperty(new.energy_windows, name) == getproperty(old.energy_windows, name)
    end
    @test new.price_blocks.producer == old.price_blocks.producer
    @test new.price_blocks.consumer == old.price_blocks.consumer
    @test new.ac_contingency_survivors.ln == old.ac_contingency_survivors.ln
    @test new.ac_contingency_survivors.xf == old.ac_contingency_survivors.xf
    @test new.dc_contingency_flows == old.dc_contingency_flows
    @test all(isequal(getproperty(new.violation_cost, k), getproperty(old.violation_cost, k)) for k in (:p_bus, :q_bus, :s, :e))
    @test new.device_class_layout.kind === :contiguous
    @test new.device_class_layout.producers_first == old.producers_first

    # The divergence the migration exists for: on the validation case the old
    # projection's suffix indices interleave and warn; the new ordinals are
    # document order and never warn.
    val = joinpath(@__DIR__, "data", "goc3_14bus_20220707.json")
    inst = PowerIO._scopf_instance_tables(PowerIO.parse_scopf(read(val, String)))
    @test inst.device_class_layout.kind === :interleaved ||
          inst.device_class_layout.producers_first isa Bool
    @test [r.j_dev for r in inst.static.prod] == collect(1:length(inst.static.prod))
    @test [r.j_sdd for r in inst.static.cons] ==
          collect(length(inst.static.prod) .+ (1:length(inst.static.cons)))
end
