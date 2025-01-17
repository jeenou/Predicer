using DataStructures
using JuMP

"""
    create_constraints(model_contents::OrderedDict, input_data::Predicer.InputData)

Create all constraints used in the model.

# Arguments
- `model_contents::OrderedDict`: Dictionary containing all data and structures used in the model. 
- `input_data::OrderedDict`: Dictionary containing data used to build the model. 
"""
function create_constraints(model_contents::OrderedDict, input_data::Predicer.InputData)
    setup_reserve_realisation(model_contents, input_data)
    setup_node_balance(model_contents, input_data)
    setup_process_online_balance(model_contents, input_data)
    setup_process_balance(model_contents, input_data)
    setup_processes_limits(model_contents, input_data)
    setup_reserve_balances(model_contents, input_data)
    setup_ramp_constraints(model_contents, input_data)
    #setup_delay_process_balance(model_contents, input_data)
    setup_bidding_constraints(model_contents, input_data)
    setup_fixed_values(model_contents, input_data)
    setup_generic_constraints(model_contents, input_data)
    setup_cost_calculations(model_contents, input_data)
    setup_cvar_element(model_contents, input_data)
    setup_objective_function(model_contents, input_data)
    setup_reserve_participation(model_contents, input_data)
    setup_inflow_blocks(model_contents, input_data)
end


"""
    setup_node_balance(model_contents::OrderedDict, input_data::Predicer.InputData)

Setup node balance constraints used in the model.

# Arguments
- `model_contents::OrderedDict`: Dictionary containing all data and structures used in the model. 
- `input_data::OrderedDict`: Dictionary containing data used to build the model. 
"""
function setup_node_balance(model_contents::OrderedDict, input_data::Predicer.InputData)
    model = model_contents["model"]
    delay_tuple = create_delay_process_tuple(input_data)
    process_tuple = process_topology_tuples(input_data)
    block_tuples = Predicer.block_tuples(input_data)
    
    node_state_tuple = state_node_tuples(input_data)
    node_balance_tuple = balance_node_tuples(input_data)
    v_flow = model_contents["variable"]["v_flow"]
    v_block = model_contents["variable"]["v_block"]
    if input_data.contains_states
        v_state = model_contents["variable"]["v_state"]
    end
    if input_data.contains_reserves
        v_res_real = model_contents["expression"]["v_res_real"]
        node_res = node_reserves(input_data)
    end



    vq_state_up = model_contents["variable"]["vq_state_up"]
    vq_state_dw = model_contents["variable"]["vq_state_dw"]
    temporals = input_data.temporals  
    nodes = input_data.nodes
    scenarios = collect(keys(input_data.scenarios))


    #######
    ## Setup inflow expression
    inflow_expr =  model_contents["expression"]["inflow_expr"] = OrderedDict()
    for n in collect(keys(nodes))
        for s in scenarios, t in temporals.t
            inflow_expr[(n, s, t)] = AffExpr(0.0)
            if nodes[n].is_inflow
                add_to_expression!(inflow_expr[(n, s, t)], nodes[n].inflow(s, t))
            end
            for b_tup in filter(x -> x[2] == n && x[3] == s && x[4] == t, block_tuples) # get tuples with blocks
                add_to_expression!(inflow_expr[(n, s, t)], input_data.inflow_blocks[b_tup[1]].data(s,t) * v_block[(b_tup[1], b_tup[2], b_tup[3])])
            end
        end
    end
   
    # Balance constraints
    # gather data in dicts, e_prod, etc, now point to a Dict()
    e_prod = model_contents["expression"]["e_prod"] = OrderedDict()
    e_cons = model_contents["expression"]["e_cons"] = OrderedDict()
    e_state = model_contents["expression"]["e_state"] = OrderedDict()
    
    for (i, tu) in enumerate(node_balance_tuple)
        e_prod[tu] = AffExpr(0.0)
        e_cons[tu] = AffExpr(0.0)
        e_state[tu] = AffExpr(0.0)

        # tu of form (node, scenario, t)
        # process tuple of form (process_name, source, sink, scenario, t)
        cons = filter(x -> (x[2] == tu[1] && x[4] == tu[2] && x[5] == tu[3]), vcat(process_tuple, delay_tuple))
        prod = filter(x -> (x[3] == tu[1] && x[4] == tu[2] && x[5] == tu[3]), vcat(process_tuple, delay_tuple))

        add_to_expression!(e_cons[tu], -vq_state_dw[tu])
        add_to_expression!(e_cons[tu], inflow_expr[tu])
        add_to_expression!(e_prod[tu], vq_state_up[tu])

        if input_data.contains_reserves && tu in node_res
            add_to_expression!(e_cons[tu], -v_res_real[tu])
        end

        if !isempty(cons)
            add_to_expression!(e_cons[tu], -sum(v_flow[cons]))
        end
        if !isempty(prod)
            add_to_expression!(e_prod[tu], sum(v_flow[prod]))
        end

        if nodes[tu[1]].is_state
            add_to_expression!(e_state[tu], v_state[tu])
            if tu[3] == temporals.t[1]
                add_to_expression!(e_state[tu], - (1-nodes[tu[1]].state.state_loss_proportional*temporals(tu[3]))*nodes[tu[1]].state.initial_state)
            else
                add_to_expression!(e_state[tu], - (1-nodes[tu[1]].state.state_loss_proportional*temporals(tu[3]))*v_state[node_balance_tuple[i-1]])
            end
        end

    end
    node_bal_eq = @constraint(model, node_bal_eq[tup in node_balance_tuple], temporals(tup[3]) * (e_prod[tup] + e_cons[tup]) == e_state[tup])
    node_state_max_up = @constraint(model, node_state_max_up[tup in node_state_tuple], e_state[tup] <= nodes[tup[1]].state.in_max * temporals(tup[3]))
    node_state_max_dw = @constraint(model, node_state_max_dw[tup in node_state_tuple], -e_state[tup] <= nodes[tup[1]].state.out_max * temporals(tup[3]))  
    model_contents["constraint"]["node_bal_eq"] = node_bal_eq
    model_contents["constraint"]["node_state_max_up"] = node_state_max_up
    model_contents["constraint"]["node_state_max_dw"] = node_state_max_dw
    for tu in node_state_tuple
        set_upper_bound(v_state[tu], nodes[tu[1]].state.state_max)
    end
end


"""
    setup_process_online_balance(model_contents::OrderedDict, input_data::Predicer.InputData)

Setup necessary functionalities for processes with binary online variables.

# Arguments
- `model_contents::OrderedDict`: Dictionary containing all data and structures used in the model. 
- `input_data::OrderedDict`: Dictionary containing data used to build the model. 
"""
function setup_process_online_balance(model_contents::OrderedDict, input_data::Predicer.InputData)
    if input_data.contains_online
        proc_online_tuple = online_process_tuples(input_data)
        if !isempty(proc_online_tuple)
            model = model_contents["model"]
            v_start = model_contents["variable"]["v_start"]
            v_stop = model_contents["variable"]["v_stop"]
            v_online = model_contents["variable"]["v_online"]
            
            processes = input_data.processes
            scenarios = collect(keys(input_data.scenarios))
            temporals = input_data.temporals
            # Dynamic equations for start/stop online variables
            online_expr = model_contents["expression"]["online_expr"] = OrderedDict()
            for (i,tup) in enumerate(proc_online_tuple)
                if tup[3] == temporals.t[1]
                    # Note - initial online state is assumed 1!
                    online_expr[tup] = @expression(model,v_start[tup]-v_stop[tup]-v_online[tup] + Int(processes[tup[1]].initial_state))
                else
                    online_expr[tup] = @expression(model,v_start[tup]-v_stop[tup]-v_online[tup]+v_online[proc_online_tuple[i-1]])
                end
            end
            online_dyn_eq =  @constraint(model,online_dyn_eq[tup in proc_online_tuple], online_expr[tup] == 0)
            model_contents["constraint"]["online_dyn_eq"] = online_dyn_eq

            # Minimum and maximum online and offline periods
            min_online_rhs = OrderedDict()
            min_online_lhs = OrderedDict()
            min_offline_rhs = OrderedDict()
            min_offline_lhs = OrderedDict()
            max_online_rhs = OrderedDict()
            max_online_lhs = OrderedDict()
            max_offline_rhs = OrderedDict()
            max_offline_lhs = OrderedDict()
            for p in keys(processes)
                if processes[p].is_online
                    for s in scenarios
                        for t in temporals.t
                            min_online = processes[p].min_online * Dates.Minute(60)
                            min_offline = processes[p].min_offline * Dates.Minute(60)

                            # get all timesteps that are within min_online/min_offline after t.
                            min_on_hours = filter(x-> Dates.Minute(0) <= ZonedDateTime(x, temporals.ts_format) - ZonedDateTime(t, temporals.ts_format) <= min_online, temporals.t)
                            min_off_hours = filter(x-> Dates.Minute(0) <= ZonedDateTime(x, temporals.ts_format) - ZonedDateTime(t, temporals.ts_format) <= min_offline, temporals.t)

                            if processes[p].max_online == 0.0
                                max_on_hours = []
                            else
                                max_online = processes[p].max_online * Dates.Minute(60)
                                max_on_hours = filter(x-> Dates.Minute(0) <= ZonedDateTime(x, temporals.ts_format) - ZonedDateTime(t, temporals.ts_format) <= max_online, temporals.t)
                            end
                            if processes[p].max_offline == 0.0
                                max_off_hours = []
                            else
                                max_offline = processes[p].max_offline * Dates.Minute(60)
                                max_off_hours = filter(x-> Dates.Minute(0) <= ZonedDateTime(x, temporals.ts_format) - ZonedDateTime(t, temporals.ts_format) <= max_offline, temporals.t)
                            end

                            for h in min_on_hours
                                min_online_rhs[(p, s, t, h)] = v_start[(p,s,t)]
                                min_online_lhs[(p, s, t, h)] = v_online[(p,s,h)]
                            end
                            for h in min_off_hours
                                min_offline_rhs[(p, s, t, h)] = (1-v_stop[(p,s,t)])
                                min_offline_lhs[(p, s, t, h)] = v_online[(p,s,h)]
                            end

                            max_online_rhs[(p, s, t)] = processes[p].max_online
                            max_offline_rhs[(p, s, t)] = 1
                            if length(max_on_hours) > processes[p].max_online 
                                max_online_lhs[(p, s, t)] = AffExpr(0.0)
                                for h in max_on_hours
                                    add_to_expression!(max_online_lhs[(p, s, t)], v_online[(p,s,h)])
                                end
                            end
                            if length(max_off_hours) > processes[p].max_offline
                                max_offline_lhs[(p, s, t)] = AffExpr(0.0)
                                for h in max_off_hours
                                    add_to_expression!(max_offline_lhs[(p, s, t)], v_online[(p,s,h)])
                                end
                            end
                        end
                    end
                end
            end

            min_online_con = @constraint(model, min_online_con[tup in keys(min_online_lhs)], min_online_lhs[tup] >= min_online_rhs[tup])
            min_offline_con = @constraint(model, min_offline_con[tup in keys(min_offline_lhs)], min_offline_lhs[tup] <= min_offline_rhs[tup])

            max_online_con = @constraint(model, max_online_con[tup in keys(max_online_lhs)], sum(max_online_lhs[tup]) <= max_online_rhs[tup])
            max_offline_con = @constraint(model, max_offline_con[tup in keys(max_offline_lhs)], sum(max_offline_lhs[tup]) >= max_offline_rhs[tup])

            model_contents["constraint"]["min_online_con"] = min_online_con
            model_contents["constraint"]["min_offline_con"] = min_offline_con
            model_contents["constraint"]["max_online_con"] = max_online_con
            model_contents["constraint"]["max_offline_con"] = max_offline_con
        end
    end
end


"""
    setup_process_balance(model_contents::OrderedDict, input_data::Predicer.InputData)

Setup constraints used in process balance calculations. 

# Arguments
- `model_contents::OrderedDict`: Dictionary containing all data and structures used in the model. 
- `input_data::OrderedDict`: Dictionary containing data used to build the model. 
"""
function setup_process_balance(model_contents::OrderedDict, input_data::Predicer.InputData)
    model = model_contents["model"]
    proc_balance_tuple = balance_process_tuples(input_data)
    process_tuple = process_topology_tuples(input_data)
    if input_data.contains_piecewise_eff
        proc_op_tuple = piecewise_efficiency_process_tuples(input_data)
        proc_op_balance_tuple = operative_slot_process_tuples(input_data)
        v_flow_op_out = model_contents["variable"]["v_flow_op_out"]
        v_flow_op_in = model_contents["variable"]["v_flow_op_in"]
        v_flow_op_bin = model_contents["variable"]["v_flow_op_bin"]
    end
    v_flow = model_contents["variable"]["v_flow"]
    processes = input_data.processes

    # Fixed efficiency case:
    nod_eff = OrderedDict()
    for tup in proc_balance_tuple
        # fixed eff value
        if isempty(processes[tup[1]].eff_ts)
            eff = processes[tup[1]].eff
        # timeseries based eff
        else
            eff = processes[tup[1]].eff_ts(tup[2], tup[3])
        end
        sources = filter(x -> (x[1] == tup[1] && x[3] == tup[1] && x[4] == tup[2] && x[5] == tup[3]), process_tuple)
        sinks = filter(x -> (x[1] == tup[1] && x[2] == tup[1] && x[4] == tup[2] && x[5] == tup[3]), process_tuple)

        nod_eff[tup] = sum(v_flow[sinks]) - (length(sources) > 0 ? eff * sum(v_flow[sources]) : 0)
    end

# Delay process balance
    model_contents["expression"]["delay_e"] = delay_e = OrderedDict()
    if input_data.contains_delay
        model = model_contents["model"]
        processes = input_data.processes
        scenarios = collect(keys(input_data.scenarios))
        temporals = input_data.temporals
        delay_p_tups = Predicer.create_delay_process_tuple(input_data)
        for dp in unique(map(tup -> tup[1], delay_p_tups))
            delay = processes[dp].delay
            n_delay_ts = Int(round(max(1, abs(delay)/temporals.dtf)))
            for s in scenarios
                if delay > 0
                    for (i, t) in enumerate(temporals.t[begin:end-n_delay_ts])
                        so = filter(tup -> tup[1] == dp && tup[3] == dp && tup[4] == s && tup[5] == temporals.t[i], delay_p_tups)
                        si = filter(tup -> tup[1] == dp && tup[2] == dp && tup[4] == s && tup[5] == temporals.t[i+n_delay_ts], delay_p_tups)
                        delay_e[(dp, s, t)] = @expression(model, sum(v_flow[so]) - sum(v_flow[si]))
                    end
                    dw_at_t_begin1 = filter(tup -> tup[1] == dp && tup[2] == dp && tup[4] == s && tup[5] == temporals.t[begin], delay_p_tups)
                    dw_at_t_begin2 = filter(tup -> tup[1] == dp && tup[2] == dp && tup[4] == s && tup[5] == temporals.t[begin+1], delay_p_tups)
                    up_at_t_end1 = filter(tup -> tup[1] == dp && tup[3] == dp && tup[4] == s && tup[5] == temporals.t[end], delay_p_tups)
                    up_at_t_end2 = filter(tup -> tup[1] == dp && tup[3] == dp && tup[4] == s && tup[5] == temporals.t[end-1], delay_p_tups)
                    delay_e[(dp,s,"dw")] = @expression(model, sum(v_flow[dw_at_t_begin1]) - sum(v_flow[dw_at_t_begin2]))
                    delay_e[(dp,s,"up")] = @expression(model, sum(v_flow[up_at_t_end1]) - sum(v_flow[up_at_t_end2]))
                elseif delay < 0
                    for (i, t) in enumerate(temporals.t[begin+n_delay_ts:end])
                        so = filter(tup -> tup[1] == dp && tup[3] == dp && tup[4] == s && tup[5] == temporals.t[i-n_delay_ts], delay_p_tups)
                        si = filter(tup -> tup[1] == dp && tup[2] == dp && tup[4] == s && tup[5] == temporals.t[i], delay_p_tups)
                        @constraint(model, sum(v_flow[si]) - sum(v_flow[so]) == 0)
                        delay_e[(dp, s, t)] = @expression(model, sum(v_flow[so]) - sum(v_flow[si]))
                    end
                    dw_at_t_begin1 = filter(tup -> tup[1] == dp && tup[3] == dp && tup[4] == s && tup[5] == temporals.t[begin], delay_p_tups)
                    dw_at_t_begin2 = filter(tup -> tup[1] == dp && tup[3] == dp && tup[4] == s && tup[5] == temporals.t[begin+1], delay_p_tups)
                    up_at_t_end1 = filter(tup -> tup[1] == dp && tup[2] == dp && tup[4] == s && tup[5] == temporals.t[end], delay_p_tups)
                    up_at_t_end2 = filter(tup -> tup[1] == dp && tup[2] == dp && tup[4] == s && tup[5] == temporals.t[end-1], delay_p_tups)
                    delay_e[(dp,s,"dw")] = @expression(model, sum(v_flow[dw_at_t_begin1]) - sum(v_flow[dw_at_t_begin2]))
                    delay_e[(dp,s,"up")] = @expression(model, sum(v_flow[up_at_t_end1]) - sum(v_flow[up_at_t_end2]))
                end
            end
        end
        @constraint(model, delay_process_balance_eq[k in collect(keys(delay_e))], delay_e[k] == 0)
    end

    process_bal_eq = @constraint(model, process_bal_eq[tup in proc_balance_tuple], nod_eff[tup] == 0)
    model_contents["constraint"]["process_bal_eq"] = process_bal_eq

    if input_data.contains_piecewise_eff
        # Piecewise linear efficiency curve case:
        op_min = OrderedDict()
        op_max = OrderedDict()
        op_eff = OrderedDict()

        for tup in proc_op_balance_tuple
            p = tup[1]
            cap = sum(map(x->x.capacity,filter(x->x.source == p,processes[p].topos)))

            i = parse(Int64,replace(tup[4], "op"=>""))# Clunky solution, how to improve?
            if i == 1 
                op_min[tup] = 0.0
            else
                op_min[tup] = processes[p].eff_fun[i-1][1]*cap
            end
            op_max[tup] = processes[p].eff_fun[i][1]*cap
            op_eff[tup] = processes[p].eff_fun[i][2]
        end

        flow_op_out_sum = @constraint(model,flow_op_out_sum[tup in proc_op_tuple],sum(v_flow_op_out[filter(x->x[1:3]==tup,proc_op_balance_tuple)]) == sum(v_flow[filter(x->x[2]==tup[1] && x[4] == tup[2] && x[5] == tup[3],process_tuple)]))
        flow_op_in_sum = @constraint(model,flow_op_in_sum[tup in proc_op_tuple],sum(v_flow_op_in[filter(x->x[1:3]==tup,proc_op_balance_tuple)]) == sum(v_flow[filter(x->x[3]==tup[1] && x[4] == tup[2] && x[5] == tup[3],process_tuple)]))
        model_contents["constraint"]["flow_op_out_sum"] = flow_op_out_sum
        model_contents["constraint"]["flow_op_in_sum"] = flow_op_in_sum

        flow_op_lo = @constraint(model,flow_op_lo[tup in proc_op_balance_tuple], v_flow_op_out[tup] >= v_flow_op_bin[tup] .* op_min[tup])
        flow_op_up = @constraint(model,flow_op_up[tup in proc_op_balance_tuple], v_flow_op_out[tup] <= v_flow_op_bin[tup] .* op_max[tup])
        flow_op_ef = @constraint(model,flow_op_ef[tup in proc_op_balance_tuple], v_flow_op_out[tup] == op_eff[tup] .* v_flow_op_in[tup])
        flow_bin = @constraint(model,flow_bin[tup in proc_op_tuple], sum(v_flow_op_bin[filter(x->x[1:3] == tup, proc_op_balance_tuple)]) == 1)
        model_contents["constraint"]["flow_op_lo"] = flow_op_lo
        model_contents["constraint"]["flow_op_up"] = flow_op_up
        model_contents["constraint"]["flow_op_ef"] = flow_op_ef
        model_contents["constraint"]["flow_bin"] = flow_bin
    end
end


"""
    setup_processes_limits(model_contents::OrderedDict, input_data::Predicer.InputData)

Setup constraints used for process limitations, such as min/max loads, unit starts and participation in reserves.

# Arguments
- `model_contents::OrderedDict`: Dictionary containing all data and structures used in the model. 
- `input_data::OrderedDict`: Dictionary containing data used to build the model. 
"""
function setup_processes_limits(model_contents::OrderedDict, input_data::Predicer.InputData)
    model = model_contents["model"]
    trans_tuple = transport_process_topology_tuples(input_data)
    lim_tuple = fixed_limit_process_topology_tuples(input_data)
    cf_balance_tuple = cf_process_topology_tuples(input_data)
    v_flow = model_contents["variable"]["v_flow"]
    processes = input_data.processes

    # Transport processes
    for tup in trans_tuple
        set_upper_bound(v_flow[tup], filter(x -> x.sink == tup[3], processes[tup[1]].topos)[1].capacity)
    end

    # cf processes
    cf_fac_fix = model_contents["expression"]["cf_fac_fix"] = OrderedDict()
    cf_fac_up = model_contents["expression"]["cf_fac_up"] = OrderedDict()
    for tup in cf_balance_tuple
        cf_fac_fix[tup] = AffExpr(0.0)
        cf_fac_up[tup] = AffExpr(0.0)
        cf_val = processes[tup[1]].cf(tup[4], tup[5])
        cap = filter(x -> (x.sink == tup[3]), processes[tup[1]].topos)[1].capacity
        if processes[tup[1]].is_cf_fix
            add_to_expression!(cf_fac_fix[tup], sum(v_flow[tup]) - cf_val * cap)
        else
            add_to_expression!(cf_fac_up[tup], sum(v_flow[tup]) - cf_val * cap)
        end
    end

    cf_fix_bal_eq = @constraint(model, cf_fix_bal_eq[tup in collect(keys(cf_fac_fix))], cf_fac_fix[tup] == 0)
    cf_up_bal_eq = @constraint(model, cf_up_bal_eq[tup in collect(keys(cf_fac_up))], cf_fac_up[tup] <= 0)
    model_contents["constraint"]["cf_fix_bal_eq"] = cf_fix_bal_eq
    model_contents["constraint"]["cf_up_bal_eq"] = cf_up_bal_eq

    # Base expressions as Dict:
    e_lim_max = model_contents["expression"]["e_lim_max"] = OrderedDict()
    e_lim_min = model_contents["expression"]["e_lim_min"] = OrderedDict()
    e_lim_res_max = model_contents["expression"]["e_lim_res_max"] = OrderedDict()
    e_lim_res_min = model_contents["expression"]["e_lim_res_min"] = OrderedDict()
    
    for tup in lim_tuple
        e_lim_max[tup] = AffExpr(0.0)
        e_lim_min[tup] = AffExpr(0.0)
        e_lim_res_max[tup] = AffExpr(0.0)
        e_lim_res_min[tup] = AffExpr(0.0)
    end



    # online processes
    if input_data.contains_online
        proc_online_tuple = online_process_tuples(input_data)
        p_online = filter(x -> processes[x[1]].is_online, lim_tuple)
        
        if !isempty(proc_online_tuple)
            v_online = model_contents["variable"]["v_online"]
            for tup in p_online
                topo = filter(x->x.sink == tup[3] && x.source == tup[2], processes[tup[1]].topos)[1]
                if isempty(topo.cap_ts)
                    cap = topo.capacity
                else
                    cap = topo.cap_ts(tup[4], tup[5])
                end
                add_to_expression!(e_lim_max[tup], -processes[tup[1]].load_max * cap * v_online[(tup[1], tup[4], tup[5])])
                add_to_expression!(e_lim_min[tup], -processes[tup[1]].load_min * cap * v_online[(tup[1], tup[4], tup[5])])
            end
        end
    end 

    # non-online, non-cf processes
    p_offline = filter(x -> !(processes[x[1]].is_online), lim_tuple)
    for tup in p_offline
        topo = filter(x->x.sink == tup[3] || x.source == tup[2], processes[tup[1]].topos)[1]
        if isempty(topo.cap_ts)
            cap = topo.capacity
        else
            cap = topo.cap_ts(tup[4], tup[5])
        end
        add_to_expression!(e_lim_max[tup], -cap)
    end

    # reserve processes
    if input_data.contains_reserves
        v_load = model_contents["variable"]["v_load"]
        res_p_tuples = unique(map(x -> x[3:end], reserve_process_tuples(input_data)))
        res_pot_cons_tuple = consumer_reserve_process_tuples(input_data)
        res_pot_prod_tuple = producer_reserve_process_tuples(input_data)
        v_reserve = model_contents["variable"]["v_reserve"]

        for tup in lim_tuple
            p_reserve_cons_up = filter(x ->x[1] == "res_up" && x[3:end] == tup, res_pot_cons_tuple)
            p_reserve_prod_up = filter(x ->x[1] == "res_up" && x[3:end] == tup, res_pot_prod_tuple)
            p_reserve_cons_down = filter(x ->x[1] == "res_down" && x[3:end] == tup, res_pot_cons_tuple)
            p_reserve_prod_down = filter(x ->x[1] == "res_down" && x[3:end] == tup, res_pot_prod_tuple)

            if !isempty(p_reserve_cons_up)
                add_to_expression!(e_lim_res_min[tup], -sum(v_reserve[p_reserve_cons_up]))
            end
            if !isempty(p_reserve_prod_up)
                add_to_expression!(e_lim_res_max[tup], sum(v_reserve[p_reserve_prod_up]))
            end
            if !isempty(p_reserve_cons_down)
                add_to_expression!(e_lim_res_max[tup], sum(v_reserve[p_reserve_cons_down]))
            end
            if !isempty(p_reserve_prod_down)
                add_to_expression!(e_lim_res_min[tup], -sum(v_reserve[p_reserve_prod_down]))
            end
        end

        v_load_max_eq = @constraint(model, v_load_max_eq[tup in res_p_tuples], v_load[tup] + e_lim_max[tup] + e_lim_res_max[tup] <= 0)
        v_load_min_eq = @constraint(model, v_load_min_eq[tup in res_p_tuples], v_load[tup] + e_lim_min[tup] + e_lim_res_min[tup] >= 0)
        model_contents["constraint"]["v_load_max_eq"] = v_load_max_eq
        model_contents["constraint"]["v_load_min_eq"] = v_load_min_eq
    end 

    v_flow_max_eq = @constraint(model, v_flow_max_eq[tup in collect(keys(e_lim_max))], v_flow[tup] + e_lim_max[tup] <= 0)
    v_flow_min_eq = @constraint(model, v_flow_min_eq[tup in collect(keys(e_lim_min))], v_flow[tup] + e_lim_min[tup] >= 0)

    model_contents["constraint"]["v_flow_max_eq"] = v_flow_max_eq
    model_contents["constraint"]["v_flow_min_eq"] = v_flow_min_eq
end



"""
    setup_reserve_realisation(model_contents::OrderedDict, input_data::Predicer.InputData)

Setup constraints for reserve realisation. 

# Arguments
- `model_contents::OrderedDict`: Dictionary containing all data and structures used in the model. 
- `input_data::OrderedDict`: Dictionary containing data used to build the model. 
"""
function setup_reserve_realisation(model_contents::OrderedDict, input_data::Predicer.InputData)
    if input_data.contains_reserves
        model = model_contents["model"]

        markets = input_data.markets
        v_res_final = model_contents["variable"]["v_res_final"]
        v_flow = model_contents["variable"]["v_flow"]
        v_load = model_contents["variable"]["v_load"]

        v_res_real_tot = model_contents["expression"]["v_res_real_tot"] = OrderedDict()
        v_res_real = model_contents["expression"]["v_res_real"] = OrderedDict()
        v_res_real_node = model_contents["expression"]["v_res_real_node"] = OrderedDict()
        v_res_real_flow = model_contents["expression"]["v_res_real_flow"] = OrderedDict()
        v_res_real_flow_tot = model_contents["expression"]["v_res_real_flow_tot"] = OrderedDict()
    
        res_market_dir_tups = reserve_market_directional_tuples(input_data)
        res_market_tuples = reserve_market_tuples(input_data)
        nodegroup_res = nodegroup_reserves(input_data)
        node_res = node_reserves(input_data)
        res_process_tuples = reserve_process_tuples(input_data)
        process_tuples = process_topology_tuples(input_data)
        res_groups = reserve_groups(input_data)
        groups = create_group_tuples(input_data)


        # Set realisation within nodegroup to be equal to total reserve * realisation
        for tup in nodegroup_res
            v_res_real_tot[tup] = AffExpr(0.0)
            v_res_real_node[tup] = AffExpr(0.0)
            for res_tup in filter(x -> x[2] == tup[1] && x[4] == tup[2] && x[5] == tup[3], res_market_dir_tups)
                res_final_tup = (res_tup[1], res_tup[4:5]...)
                real = markets[res_tup[1]].realisation[res_tup[4]]
                if res_tup[3] == "res_up"
                    add_to_expression!(v_res_real_tot[tup], real * v_res_final[res_final_tup])
                elseif res_tup[3] == "res_down"
                    add_to_expression!(v_res_real_tot[tup], -1.0 * real * v_res_final[res_final_tup])
                end
            end
        end

        # create process-wise reserve_realisation expression "v_res_real_flow"
        for p_tup in process_tuples
            v_res_real_flow[p_tup] = AffExpr(0.0)
            res_p_tup = filter(y -> y == p_tup, unique(map(x -> (x[3:end]), res_process_tuples)))
            if !isempty(res_p_tup)
                add_to_expression!(v_res_real_flow[p_tup], v_flow[p_tup] - v_load[p_tup])
            end
        end

        # create expression for node-wise realisation
        for n_tup in node_res
            n = n_tup[1]
            s = n_tup[2]
            t = n_tup[3]
            v_res_real[n_tup] = AffExpr(0.0)
            for p in unique(map(y -> y[5], filter(z -> z[4] == n, res_groups)))
                prod_tups = unique(map(y -> (y[3:end]), filter(x -> x[3] == p && x[5] == n && x[6] == s && x[7] == t, res_process_tuples)))
                cons_tups = unique(map(y -> (y[3:end]), filter(x -> x[3] == p && x[4] == n && x[6] == s && x[7] == t, res_process_tuples)))
                for pt in prod_tups
                    add_to_expression!(v_res_real[n_tup], v_res_real_flow[pt])
                end
                for ct in cons_tups
                    add_to_expression!(v_res_real[n_tup], -v_res_real_flow[ct])
                end
            end
        end

        # set realisation within nodegroup to be equal to node-wise realisation within members of the nodegroup
        # real(ng) == sumof real n for n in ng
        for ng_tup in nodegroup_res
            for n in unique(map(x -> x[3], filter(y -> y[2] == ng_tup[1], groups)))
                add_to_expression!(v_res_real_node[ng_tup], v_res_real[(n, ng_tup[2], ng_tup[3])])
            end
        end

        res_real_eq = @constraint(model, res_real_eq[tup in nodegroup_res], v_res_real_tot[tup] == v_res_real_node[tup])
        model_contents["constraint"]["res_real_eq"] = res_real_eq


        # enure that the realisation of reserve rp is equal to the realisation of processes in the processgroup of the reserve
        # Ensures that the realisation is done by the "correct" processes. 
        # reserve-specific realisation = sumof process_realisation for p in reserve processgroup. 
        for res in unique(map(x -> x[1], res_market_tuples))
            res_ng = input_data.markets[res].node
            res_ns = unique(map(x -> x[3], filter(y -> y[2] == res_ng, groups)))
            res_ps = unique(map(y -> y[5], filter(x -> x[3] == res, res_groups)))
            for s in scenarios(input_data), t in input_data.temporals.t
                v_res_real_flow_tot[(res_ng, s, t)] = AffExpr(0.0)
                for res_p in res_ps
                    prod_tups = unique(map(y -> (y[3:end]), filter(x -> x[3] == res_p && (x[5] in res_ns) && x[6] == s && x[7] == t, res_process_tuples)))
                    for pt in prod_tups
                        add_to_expression!(v_res_real_flow_tot[(res_ng, s, t)], v_res_real_flow[pt])
                    end
                    cons_tups = unique(map(y -> (y[3:end]), filter(x -> x[3] == res_p && (x[4] in res_ns) && x[6] == s && x[7] == t, res_process_tuples)))
                    for ct in cons_tups
                        add_to_expression!(v_res_real_flow_tot[(res_ng, s, t)], -1.0 * v_res_real_flow[ct])
                    end
                end
            end
        end
        
        res_production_eq = @constraint(model, res_production_eq[tup in nodegroup_res], v_res_real_tot[tup] == v_res_real_flow_tot[tup])
        model_contents["constraint"]["res_production_eq"] = res_production_eq
    end
end


"""
    setup_reserve_balances(model_contents::OrderedDict, input_data::Predicer.InputData)

Setup constraints for reserves. 

# Arguments
- `model_contents::OrderedDict`: Dictionary containing all data and structures used in the model. 
- `input_data::OrderedDict`: Dictionary containing data used to build the model. 
"""
function setup_reserve_balances(model_contents::OrderedDict, input_data::Predicer.InputData)
    if input_data.contains_reserves
        model = model_contents["model"]
        res_nodegroup = reserve_nodegroup_tuples(input_data)
        group_tuples = create_group_tuples(input_data)
        res_potential_tuple = reserve_process_tuples(input_data)
        res_tuple = reserve_market_directional_tuples(input_data)
        res_dir = model_contents["res_dir"]
        res_eq_updn_tuple = up_down_reserve_market_tuples(input_data)
        res_final_tuple = reserve_market_tuples(input_data)
        res_nodes_tuple = reserve_nodes(input_data)
        node_state_tuple = state_node_tuples(input_data)
        state_reserve_tuple = state_reserves(input_data)  
        scenarios = collect(keys(input_data.scenarios))
        temporals = input_data.temporals
        markets = input_data.markets
        nodes = input_data.nodes
        processes = input_data.processes
        v_reserve = model_contents["variable"]["v_reserve"]
        v_res = model_contents["variable"]["v_res"]
        v_res_final = model_contents["variable"]["v_res_final"]
        # state reserve balances
        if input_data.contains_states
            for s_node in unique(map(x -> x[1], state_reserve_tuple))
                state_max = nodes[s_node].state.state_max
                state_min = nodes[s_node].state.state_min
                state_max_in = nodes[s_node].state.in_max
                state_max_out = nodes[s_node].state.out_max
                for s in scenarios, t in temporals.t
                    state_tup = filter(x -> x[1] == s_node && x[2] == s && x[3] == t, node_state_tuple)[1]
                    # Each storage node should have one process in and one out from the storage
                    dtf = temporals(t)
                    p_out_tup = filter(x -> x[1] == s_node && x[2] == "res_up" && x[4] == x[5] && x[7] == s && x[8] == t, state_reserve_tuple)
                    p_in_tup = filter(x -> x[1] == s_node && x[2] == "res_down" && x[4] == x[6] && x[7] == s && x[8] == t, state_reserve_tuple)
                    if !isempty(p_out_tup)
                        p_out_eff = processes[p_out_tup[1][4]].eff
                        # State in/out limit
                        @constraint(model, v_reserve[p_out_tup[1][2:end]] <= state_max_out * p_out_eff)
                        # State value limit
                        @constraint(model, v_reserve[p_out_tup[1][2:end]] <= (model_contents["variable"]["v_state"][state_tup] -  state_min) * p_out_eff / dtf)
                    end
                    if !isempty(p_in_tup)
                        p_in_eff = processes[p_in_tup[1][4]].eff
                        # State in/out limit
                        @constraint(model, v_reserve[p_in_tup[1][2:end]] <= state_max_in / p_in_eff)
                        # State value limit
                        @constraint(model, v_reserve[p_in_tup[1][2:end]] <= (state_max - model_contents["variable"]["v_state"][state_tup]) / p_in_eff / dtf)
                    end
                end
            end
        end

        # Reserve balances (from reserve potential to reserve product):
        e_res_bal_up = model_contents["expression"]["e_res_bal_up"] = OrderedDict()
        e_res_bal_dn = model_contents["expression"]["e_res_bal_up"] = OrderedDict()
        for tup in res_nodegroup
            ng = tup[1]
            r = tup[2]
            s = tup[3]
            t = tup[4]
            e_res_bal_up[tup] = AffExpr(0.0)
            e_res_bal_dn[tup] = AffExpr(0.0)

            res_u = filter(x -> x[3] == "res_up" && markets[x[1]].reserve_type == r && x[4] == s && x[5] == t && x[2] == ng, res_tuple)
            res_d = filter(x -> x[3] == "res_down" && markets[x[1]].reserve_type == r && x[4] == s && x[5] == t && x[2] == ng, res_tuple)
            if !isempty(res_u)
                add_to_expression!(e_res_bal_up[tup], -sum(v_res[res_u]))
            end
            if !isempty(res_d)
                add_to_expression!(e_res_bal_dn[tup], -sum(v_res[res_d]))
            end

            for n in unique(map(y -> y[3], filter(x -> x[2] == ng, group_tuples)))
                if n in res_nodes_tuple
                    res_pot_u = filter(x -> x[1] == "res_up" && x[2] == r && x[6] == s && x[7] == t && (x[4] == n || x[5] == n), res_potential_tuple)
                    res_pot_d = filter(x -> x[1] == "res_down" && x[2] == r && x[6] == s && x[7] == t && (x[4] == n || x[5] == n), res_potential_tuple)
                    if !isempty(res_pot_u)
                        add_to_expression!(e_res_bal_up[tup], sum(v_reserve[res_pot_u]))
                    end
                    if !isempty(res_pot_d)
                        add_to_expression!(e_res_bal_dn[tup], sum(v_reserve[res_pot_d]))
                    end
                end
            end
        end            

        # res_tuple is the tuple use for v_res (market, n, res_dir, s, t)
        # res_eq_updn_tuple (market, s, t)
        # the previously used tuple is res_eq_tuple, of form (ng, rt, s, t)
        res_eq_updn = @constraint(model, res_eq_updn[tup in res_eq_updn_tuple], v_res[(tup[1], markets[tup[1]].node, res_dir[1], tup[2], tup[3])] - v_res[(tup[1], markets[tup[1]].node, res_dir[2], tup[2], tup[3])] == 0)
        res_eq_up = @constraint(model, res_eq_up[tup in res_nodegroup], e_res_bal_up[tup] == 0)
        res_eq_dn = @constraint(model, res_eq_dn[tup in res_nodegroup], e_res_bal_dn[tup] == 0)
        model_contents["constraint"]["res_eq_updn"] = res_eq_updn
        model_contents["constraint"]["res_eq_up"] = res_eq_up
        model_contents["constraint"]["res_eq_dn"] = res_eq_dn

        # Final reserve product:
        # res_final_tuple (m, s, t)
        # r_tup = res_tuple = (m, n, res_dir, s, t)
        reserve_final_exp = model_contents["expression"]["reserve_final_exp"] = OrderedDict()
        for tup in res_final_tuple
            if markets[tup[1]].direction == "up" || markets[tup[1]].direction == "res_up"
                r_tup = filter(x -> x[1] == tup[1] && x[4] == tup[2] && x[5] == tup[3] && x[3] == "res_up", res_tuple)
            elseif markets[tup[1]].direction == "down" || markets[tup[1]].direction == "res_down" 
                r_tup = filter(x -> x[1] == tup[1] && x[4] == tup[2] && x[5] == tup[3] && x[3] == "res_down", res_tuple)
            elseif markets[tup[1]].direction == "up_down" || markets[tup[1]].direction == "res_up_down"
                r_tup = filter(x -> x[1] == tup[1] && x[4] == tup[2] && x[5] == tup[3], res_tuple)
            end
            reserve_final_exp[tup] = @expression(model, sum(v_res[r_tup]) .* (markets[tup[1]].direction == "up_down" ? 0.5 : 1.0) .- v_res_final[tup])
        end
        reserve_final_eq = @constraint(model, reserve_final_eq[tup in res_final_tuple], reserve_final_exp[tup] == 0)
        model_contents["constraint"]["reserve_final_eq"] = reserve_final_eq
    end
end


"""
    setup_ramp_constraints(model_contents::OrderedDict, input_data::Predicer.InputData)

Setup process ramp constraints, based on ramp limits defined in input data and participation in reserves.  

# Arguments
- `model_contents::OrderedDict`: Dictionary containing all data and structures used in the model. 
- `input_data::OrderedDict`: Dictionary containing data used to build the model. 
"""
function setup_ramp_constraints(model_contents::OrderedDict, input_data::Predicer.InputData)
    model = model_contents["model"]
    ramp_tuple = process_topology_ramp_times_tuples(input_data)
    process_tuple = process_topology_tuples(input_data)
    v_flow = model_contents["variable"]["v_flow"]

    processes = input_data.processes
    temporals = input_data.temporals

    ramp_expr_up = model_contents["expression"]["ramp_expr_up"] = OrderedDict()
    ramp_expr_down = model_contents["expression"]["ramp_expr_down"] = OrderedDict()

    if input_data.contains_reserves
        v_load = model_contents["variable"]["v_load"]
        res_proc_tuples = filter(x -> x[5] != input_data.temporals.t[1], unique(map(y -> y[3:end], reserve_process_tuples(input_data))))
        res_nodes_tuple = reserve_nodes(input_data)
        res_potential_tuple = reserve_process_tuples(input_data)
        v_reserve = model_contents["variable"]["v_reserve"]
        reserve_types = input_data.reserve_type
        ramp_expr_res_up = model_contents["expression"]["ramp_expr_res_up"] = OrderedDict()
        ramp_expr_res_down = model_contents["expression"]["ramp_expr_res_down"] = OrderedDict()
    end

    if input_data.contains_online
        v_start = model_contents["variable"]["v_start"]
        v_stop = model_contents["variable"]["v_stop"]
    end

    for tup in ramp_tuple
        if processes[tup[1]].conversion == 1 && !processes[tup[1]].is_cf
            ramp_expr_up[tup] = AffExpr(0.0)
            ramp_expr_down[tup] = AffExpr(0.0)

            topo = filter(x -> x.source == tup[2] && x.sink == tup[3], processes[tup[1]].topos)[1]
            ramp_up_cap = topo.ramp_up * topo.capacity * temporals(tup[5])
            ramp_dw_cap = topo.ramp_down * topo.capacity * temporals(tup[5])
            start_cap = max(0,processes[tup[1]].load_min-topo.ramp_up)*topo.capacity
            stop_cap = max(0,processes[tup[1]].load_min-topo.ramp_down)*topo.capacity

            # add ramp rate limit
            add_to_expression!(ramp_expr_up[tup], ramp_up_cap) 
            add_to_expression!(ramp_expr_down[tup], - ramp_dw_cap)

            # if online process
            if processes[tup[1]].is_online
                add_to_expression!(ramp_expr_up[tup], start_cap * v_start[(tup[1], tup[4], tup[5])]) 
                add_to_expression!(ramp_expr_down[tup], - stop_cap * v_stop[(tup[1], tup[4], tup[5])])
            end

            # if reserve process
            if processes[tup[1]].is_res && input_data.contains_reserves && tup in res_proc_tuples
                ramp_expr_res_up[tup] = AffExpr(0.0)
                ramp_expr_res_down[tup] = AffExpr(0.0)

                # get reserve production for the previous timestep from tup
                res_ramp_tup = process_tuple[findall( x -> x == tup, process_tuple)[1]-1]
                res_tup_up = filter(x->x[1]=="res_up" && x[3:end]==res_ramp_tup,res_potential_tuple)
                res_tup_down = filter(x->x[1]=="res_down" && x[3:end]==res_ramp_tup,res_potential_tuple)
                if tup[2] in res_nodes_tuple
                    for rtd in res_tup_down
                        add_to_expression!(ramp_expr_res_up[tup], -1 * sum(reserve_types[rtd[2]] .* v_reserve[rtd]))
                    end
                    for rtu in res_tup_up
                        add_to_expression!(ramp_expr_res_down[tup], sum(reserve_types[rtu[2]] .* v_reserve[rtu]))
                    end
                elseif tup[3] in res_nodes_tuple
                    for rtu in res_tup_up
                        add_to_expression!(ramp_expr_res_up[tup], -1 * sum(reserve_types[rtu[2]] .* v_reserve[rtu])) 
                    end
                    for rtd in res_tup_down
                        add_to_expression!(ramp_expr_res_down[tup], sum(reserve_types[rtd[2]] .* v_reserve[rtd])) 
                    end
                end
            end
        end
    end
    
    if input_data.contains_reserves
        if !isempty(ramp_expr_res_up)
            ramp_up_eq_v_load = @constraint(model, ramp_up_eq_v_load[tup in res_proc_tuples], v_load[tup] - v_load[process_tuple[findall(x->x==tup,process_tuple)[1]-1]] <= ramp_expr_up[tup] + ramp_expr_res_up[tup])
            ramp_down_eq_v_load = @constraint(model, ramp_down_eq_v_load[tup in res_proc_tuples], v_load[tup] - v_load[process_tuple[findall(x->x==tup,process_tuple)[1]-1]] >= ramp_expr_down[tup] + ramp_expr_res_down[tup])
            model_contents["constraint"]["ramp_up_eq_v_load"] = ramp_up_eq_v_load
            model_contents["constraint"]["ramp_down_eq_v_load"] = ramp_down_eq_v_load
        end
    end
        
    ramp_up_eq_v_flow = @constraint(model, ramp_up_eq_v_flow[tup in ramp_tuple], v_flow[tup] - v_flow[process_tuple[findall(x->x==tup,process_tuple)[1]-1]] <= ramp_expr_up[tup])
    ramp_down_eq_v_flow = @constraint(model, ramp_down_eq_v_flow[tup in ramp_tuple], v_flow[tup] - v_flow[process_tuple[findall(x->x==tup,process_tuple)[1]-1]] >= ramp_expr_down[tup])
    model_contents["constraint"]["ramp_up_eq_v_flow"] = ramp_up_eq_v_flow
    model_contents["constraint"]["ramp_down_eq_v_flow"] = ramp_down_eq_v_flow
end


function setup_delay_process_balance(model_contents::OrderedDict, input_data::Predicer.InputData)
    model = model_contents["model"]
    delay_tuple = create_delay_tuple(input_data)
    v_flow = model_contents["variable"]["v_flow"]
    processes = input_data.processes
    temporals = input_data.temporals
    so_expr= OrderedDict()
    si_expr= OrderedDict()
    for tup in delay_tuple
        so = filter(t -> t.sink == tup[1],  processes[tup[1]].topos)[1]
        si = filter(t -> t.source == tup[1],  processes[tup[1]].topos)[1]
        t = tup[3]
        t_delay = TimeZones.ZonedDateTime(year(t), month(t), day(t), hour(t) - processes[tup[1]].delay, t.timezone)
        if tup[3] in temporals[1:highest_delay]
            so_expr[tup] = @expression(model, v_flow[(tup[1], si.source, si.sink, tup[2], tup[3])])
            si_expr[tup] = @expression(model, v_flow[(tup[1], si.source, si.sink, tup[2], tup[3])])
        else
            so_expr[tup] = @expression(model, v_flow[(tup[1], so.source, so.sink, tup[2], t_delay)])
            si_expr[tup] = @expression(model, v_flow[(tup[1], si.source, si.sink, tup[2], t)])
        end
    end

    delay_balance_eq = @constraint(model, delay_balance_eq[tup in delay_tuple], so_expr[tup] == si_expr[tup])
    model_contents["constraint"]["delay_balance_eq"] = delay_balance_eq
    model_contents["expression"]["delay_expr_so"] = so_expr
    model_contents["expression"]["delay_expr_si"] = si_expr
end

"""
    setup_fixed_values(model_contents::OrderedDict, input_data::Predicer.InputData)

Setup constraints for setting fixed process values at certain timesteps.   

# Arguments
- `model_contents::OrderedDict`: Dictionary containing all data and structures used in the model. 
- `input_data::OrderedDict`: Dictionary containing data used to build the model. 
"""
function setup_fixed_values(model_contents::OrderedDict, input_data::Predicer.InputData)
    model = model_contents["model"]
    fixed_value_tuple = fixed_market_tuples(input_data)
    v_bid = model_contents["expression"]["v_bid"]
    markets = input_data.markets
    scenarios = collect(keys(input_data.scenarios))
    
    if input_data.contains_reserves
        v_res_final = model_contents["variable"]["v_res_final"]
    end
    
    fix_expr = model_contents["expression"]["fix_expr"] = OrderedDict()
    for m in keys(markets)
        if !isempty(markets[m].fixed)
            temps = map(x->x[1],markets[m].fixed)
            fix_vec = map(x->x[2],markets[m].fixed)

            if markets[m].type == "energy"
                for (t, fix_val) in zip(temps, fix_vec)
                    for s in scenarios
                        fix_expr[(m, s, t)] = @expression(model,v_bid[(m,s,t)]-fix_val)
                    end
                end
            elseif markets[m].type == "reserve" && input_data.contains_reserves
                for (t, fix_val) in zip(temps, fix_vec)
                    for s in scenarios
                        fix(v_res_final[(m, s, t)], fix_val; force=true)
                    end
                end
            end
        end
    end
    fixed_value_eq = @constraint(model, fixed_value_eq[tup in fixed_value_tuple], fix_expr[tup] == 0)
    model_contents["constraint"]["fixed_value_eq"] = fixed_value_eq
end


"""
    setup_bidding_constraints(model_contents::OrderedDict, input_data::Predicer.InputData)

Setup constraints for market bidding.   

# Arguments
- `model_contents::OrderedDict`: Dictionary containing all data and structures used in the model. 
- `input_data::OrderedDict`: Dictionary containing data used to build the model. 
"""
function setup_bidding_constraints(model_contents::OrderedDict, input_data::Predicer.InputData)
    model = model_contents["model"]
    markets = input_data.markets
    scenarios = collect(keys(input_data.scenarios))
    temporals = input_data.temporals
    process_tuple = process_topology_tuples(input_data)
    balance_process_tuple = create_balance_market_tuple(input_data)
    
    v_flow = model_contents["variable"]["v_flow"]
    v_flow_bal = model_contents["variable"]["v_flow_bal"]
    v_bid = model_contents["expression"]["v_bid"] = OrderedDict()

    if input_data.contains_reserves
        v_res_final = model_contents["variable"]["v_res_final"]
    end
    
    price_matr = OrderedDict()
    for m in keys(markets)
        if markets[m].is_bid
            for (i,s) in enumerate(scenarios)
                vec = map(x -> x[2], markets[m].price(s).series)
                if i == 1
                    price_matr[m] = vec
                else
                    price_matr[m] = hcat(price_matr[m],vec)
                end
                if markets[m].type == "energy"
                    for t in temporals.t
                        v_bid[(markets[m].name,s,t)] = AffExpr(0.0)
                        add_to_expression!(v_bid[(markets[m].name,s,t)],
                                v_flow[filter(x->x[3]==markets[m].name && x[5]==t && x[4]==s,process_tuple)[1]],1.0)
                        add_to_expression!(v_bid[(markets[m].name,s,t)],
                                v_flow_bal[filter(x->x[1]==markets[m].name && x[2]=="up" && x[4]==t && x[3]==s,balance_process_tuple)[1]],1.0)
                        add_to_expression!(v_bid[(markets[m].name,s,t)],
                                v_flow[filter(x->x[2]==markets[m].name && x[5]==t && x[4]==s,process_tuple)[1]],-1.0)
                        add_to_expression!(v_bid[(markets[m].name,s,t)],
                                v_flow_bal[filter(x->x[1]==markets[m].name && x[2]=="dw" && x[4]==t && x[3]==s,balance_process_tuple)[1]],-1.0)
                    end
                end
                if markets[m].type=="reserve"
                    for t in temporals.t
                        if markets[m].price(s)(t) == 0
                            fix(v_res_final[(m, s, t)], 0.0; force=true)
                        end
                    end
                end
            end
        end
    end
    for m in keys(markets)
        if markets[m].is_bid
            for (i,t) in enumerate(temporals.t)
                s_indx = sortperm((price_matr[m][i,:]))
                if markets[m].type == "energy"
                    for k in 2:length(s_indx)
                        if price_matr[m][i, s_indx[k]] == price_matr[m][i, s_indx[k-1]]
                            @constraint(model,
                                        v_bid[(markets[m].name,scenarios[s_indx[k]],t)] ==
                                        v_bid[(markets[m].name,scenarios[s_indx[k-1]],t)])
                        else
                            @constraint(model, 
                                        v_bid[(markets[m].name,scenarios[s_indx[k]],t)] >=
                                        v_bid[(markets[m].name,scenarios[s_indx[k-1]],t)])
                        end
                    end
                elseif markets[m].type == "reserve" && input_data.contains_reserves
                    for k in 2:length(s_indx)
                        if price_matr[m][i, s_indx[k]] == price_matr[m][i, s_indx[k-1]]
                            @constraint(model, v_res_final[(m,scenarios[s_indx[k]],t)] == v_res_final[(m,scenarios[s_indx[k-1]],t)])
                        else
                            @constraint(model, v_res_final[(m,scenarios[s_indx[k]],t)] >= v_res_final[(m,scenarios[s_indx[k-1]],t)])
                        end
                    end
                end
            end
        end
    end
end

"""
    setup_reserve_participation(model_contents::OrderedDict, input_data::Predicer.InputData)

Setup participation limits for reserve

# Arguments
- `model_contents::OrderedDict`: Dictionary containing all data and structures used in the model. 
- `input_data::OrderedDict`: Dictionary containing data used to build the model. 
"""
function setup_reserve_participation(model_contents::OrderedDict, input_data::Predicer.InputData)
    if input_data.contains_reserves
        model = model_contents["model"]
        markets = input_data.markets
        v_res_online = model_contents["variable"]["v_reserve_online"]
        v_res_final = model_contents["variable"]["v_res_final"]
        res_lim_tuple = create_reserve_limits(input_data)
        res_online_up_expr = model_contents["expression"]["res_online_up_expr"] = OrderedDict()
        res_online_lo_expr = model_contents["expression"]["res_online_lo_expr"] = OrderedDict()
        for tup in res_lim_tuple
            max_bid = markets[tup[1]].max_bid
            min_bid = markets[tup[1]].min_bid
            res_online_up_expr[tup] = @expression(model,v_res_final[tup]-max_bid*v_res_online[tup])
            res_online_lo_expr[tup] = @expression(model,v_res_final[tup]-min_bid*v_res_online[tup]) 
        end
        res_online_up = @constraint(model, res_online_up[tup in res_lim_tuple], res_online_up_expr[tup] <= 0)
        res_online_lo = @constraint(model, res_online_lo[tup in res_lim_tuple], res_online_lo_expr[tup] >= 0)
        model_contents["constraint"]["res_online_up"] = res_online_up
        model_contents["constraint"]["res_online_lo"] = res_online_lo
    end
end


"""
    setup_inflow_blocks(model_contents::OrderedDict, input_data::Predicer.InputData)    

Setup functionality, which can be used to model demand flexibility in Predicer. Only one block can 
be active per node per scenario. 

# Arguments
- `model_contents::OrderedDict`: Dictionary containing all data and structures used in the model. 
- `input_data::OrderedDict`: Dictionary containing data used to build the model. 
"""
function setup_inflow_blocks(model_contents::OrderedDict, input_data::Predicer.InputData)
    model = model_contents["model"]
    block_tuples = Predicer.block_tuples(input_data)
    v_block = model_contents["variable"]["v_block"]
    nodes = input_data.nodes
    scenarios = collect(keys(input_data.scenarios))
    temporals = input_data.temporals

    node_block_expr = model_contents["expression"]["node_block_expr"] = OrderedDict()

    for n in collect(keys(nodes))
        for s in scenarios, t in temporals.t
            b_tups = filter(x -> x[2] == n && x[3] == s && x[4] == t, block_tuples)
            if !isempty(b_tups)
                node_block_expr[(n, s, t)] = AffExpr(0.0)
                for b_tup in b_tups
                    add_to_expression!(node_block_expr[(n, s, t)], v_block[(b_tup[1], n, s)])
                end
            end
        end
    end
    node_block_eq = @constraint(model, node_block_eq[tup in collect(keys(node_block_expr))], sum(node_block_expr[tup]) <= 1)
    model_contents["constraint"]["node_block_eq"] = node_block_eq
end


"""
    setup_generic_constraints(model_contents::OrderedDict, input_data::Predicer.InputData)

Setup generic constraints. 

# Arguments
- `model_contents::OrderedDict`: Dictionary containing all data and structures used in the model. 
- `input_data::OrderedDict`: Dictionary containing data used to build the model. 
"""
function setup_generic_constraints(model_contents::OrderedDict, input_data::Predicer.InputData)
    model = model_contents["model"]
    process_tuple = process_topology_tuples(input_data)
    online_tuple = online_process_tuples(input_data)
    state_tuple = state_node_tuples(input_data)
    setpoint_tups = setpoint_tuples(input_data)
    v_flow = model_contents["variable"]["v_flow"]
    if input_data.contains_online
        v_online = model_contents["variable"]["v_online"]    
    end    
    if input_data.contains_states
        v_state = model_contents["variable"]["v_state"]
    end
    
    v_setpoint = model_contents["variable"]["v_setpoint"]
    v_set_up = model_contents["variable"]["v_set_up"]
    v_set_down = model_contents["variable"]["v_set_down"]

    scenarios = collect(keys(input_data.scenarios))
    temporals = input_data.temporals
    gen_constraints = input_data.gen_constraints

    const_expr = model_contents["gen_expression"] = OrderedDict()
    const_dict = model_contents["gen_constraint"] = OrderedDict()
    setpoint_expr_lhs = OrderedDict()
    setpoint_expr_rhs = OrderedDict()

    for c in keys(gen_constraints)
        # Get timesteps for where there is data defined. (Assuming all scenarios are equal)
        gen_const_ts = map(x -> x[1], gen_constraints[c].factors[1].data(scenarios[1]).series)
        # Get timesteps which are found in both temporals and gen constraints 
        relevant_ts = filter(t -> t in gen_const_ts, temporals.t)
        # use these ts to create gen_consts..
        const_expr[c] = OrderedDict((s,t) => AffExpr(0.0) for s in scenarios, t in relevant_ts)
        facs = gen_constraints[c].factors
        consta = gen_constraints[c].constant
        eq_dir = gen_constraints[c].type
        if !gen_constraints[c].is_setpoint
            for s in scenarios, t in relevant_ts
                add_to_expression!(const_expr[c][(s,t)], consta(s, t))
                for f in facs
                    if f.var_type == "flow"
                        p_flow = f.var_tuple
                        if input_data.processes[p_flow[1]].conversion == 1
                            tup = filter(x->x[1]==p_flow[1] && (x[2]==p_flow[2] || x[3]==p_flow[2]) && x[4]==s && x[5]==t,process_tuple)[1]
                        else
                            tup = filter(x->x[1]==p_flow[1] && (x[2]==p_flow[1] || x[3]==p_flow[2]) && x[4]==s && x[5]==t,process_tuple)[1]
                        end
                        fac_data = f.data(s, t)
                        add_to_expression!(const_expr[c][(s,t)],fac_data,v_flow[tup])
                    elseif f.var_type == "online"
                        p = f.var_tuple[1]
                        if input_data.processes[p].is_online
                            tup = filter(x -> x[1] == p && x[2] == s && x[3] == t, online_tuple)[1]
                        else
                            msg = "Factor " * string((p, f.var_tuple)) * " of gen_constraint " * string(c) * " has no online functionality!" 
                            throw(ErrorException(msg))
                        end
                        fac_data = f.data(s, t)
                        add_to_expression!(const_expr[c][(s,t)],fac_data,v_online[tup])
                    elseif f.var_type == "state"
                        n = f.var_tuple[1]
                        if input_data.nodes[n].is_state
                            tup = filter(x -> x[1] == n && x[2] == s && x[3] == t, state_tuple)[1]
                        else
                            msg = "Factor " * string((n, f.var_tuple)) * " of gen_constraint " * string(c) * " has no state functionality!" 
                            throw(ErrorException(msg))
                        end
                        fac_data = f.data(s, t)
                        add_to_expression!(const_expr[c][(s,t)],fac_data,v_state[tup])
                    end
                end
            end 
            if eq_dir == "eq"
                const_dict[c] = @constraint(model,[s in scenarios,t in relevant_ts],const_expr[c][(s,t)]==0.0)
            elseif eq_dir == "gt"
                const_dict[c] = @constraint(model,[s in scenarios,t in relevant_ts],const_expr[c][(s,t)]>=0.0)
            else
                const_dict[c] = @constraint(model,[s in scenarios,t in relevant_ts],const_expr[c][(s,t)]<=0.0)
            end
        else
            for s in scenarios, t in relevant_ts
                if !((c, s, t) in collect(keys(setpoint_expr_lhs)))
                    setpoint_expr_lhs[(c, s, t)] = AffExpr(0.0)
                    setpoint_expr_rhs[(c, s, t)] = AffExpr(0.0)
                else
                    msg = "Several columns with factors are not supported for setpoint constraints!" 
                    throw(ErrorException(msg))
                end
                for f in facs
                    if f.var_type == "state"
                        n = f.var_tuple[1]
                        d_max = input_data.nodes[n].state.state_max
                        add_to_expression!(setpoint_expr_lhs[(c, s, t)], v_state[(n, s, t)])
                    elseif f.var_type == "flow"
                        p = f.var_tuple[1]
                        topo = filter(x -> x.source == f.var_tuple[2] || x.sink == f.var_tuple[2], input_data.processes[p].topos)[1]
                        d_max = topo.capacity
                        flow_tup = (p, topo.source, topo.sink, s, t)
                        add_to_expression!(setpoint_expr_lhs[(c, s, t)], v_flow[flow_tup])
                    else
                        msg = "Setpoint constraints cannot be used with variables of the type " * f.var_type * "!" 
                        throw(ErrorException(msg))
                    end
                    d_setpoint = f.data(s,t)
                    if eq_dir == "eq" # lower and upper setpoint are the same.  
                        d_upper = d_setpoint / d_max
                        d_lower = d_setpoint / d_max
                    elseif eq_dir == "gt" # No upper bound
                        d_upper = 1.0
                        d_lower = d_setpoint / d_max
                    else # eq_dir == "st" , meaning no lower bound
                        d_upper = d_setpoint / d_max
                        d_lower = 0.0
                    end
                    JuMP.set_upper_bound(v_set_up[(c, s, t)], (1.0 - d_upper) * d_max)
                    JuMP.set_upper_bound(v_set_down[(c, s, t)], d_lower * d_max)
                    JuMP.set_upper_bound(v_setpoint[(c, s, t)], (d_upper - d_lower) * d_max)
                    add_to_expression!(setpoint_expr_rhs[(c, s, t)], d_lower * d_max + v_setpoint[(c, s, t)] + v_set_up[(c, s, t)] - v_set_down[(c, s, t)])                        
                end
            end
        end
    end
    setpoint_eq = @constraint(model, setpoint_eq[tup in setpoint_tups], setpoint_expr_lhs[tup] == setpoint_expr_rhs[tup])
    model_contents["constraint"]["setpoint_eq"] = setpoint_eq
end


"""
    setup_cost_calculations(model_contents::OrderedDict, input_data::Predicer.InputData)

Setup expressions used for calculating the costs in the model. 

# Arguments
- `model_contents::OrderedDict`: Dictionary containing all data and structures used in the model. 
- `input_data::OrderedDict`: Dictionary containing data used to build the model. 
"""
function setup_cost_calculations(model_contents::OrderedDict, input_data::Predicer.InputData)
    model = model_contents["model"]
    process_tuple = process_topology_tuples(input_data)
    node_balance_tuple = balance_node_tuples(input_data)
    
    v_flow = model_contents["variable"]["v_flow"]
    v_bid = model_contents["expression"]["v_bid"]
    v_flow_bal = model_contents["variable"]["v_flow_bal"]

    scenarios = collect(keys(input_data.scenarios))
    nodes = input_data.nodes
    markets = input_data.markets
    processes = input_data.processes
    temporals = input_data.temporals

    # Commodity costs and market costs
    commodity_costs = model_contents["expression"]["commodity_costs"] = OrderedDict()
    market_costs = model_contents["expression"]["market_costs"] = OrderedDict()
    for s in scenarios
        commodity_costs[s] = AffExpr(0.0)
        market_costs[s] = AffExpr(0.0)
        for n in keys(nodes)
            #Commodity costs:
            if nodes[n].is_commodity
                flow_tups = filter(x -> x[2] == n && x[4] == s, process_tuple)
                cost_ts = nodes[n].cost(s)
                # Add to expression for each t found in series
                for tup in flow_tups
                    add_to_expression!(commodity_costs[s], sum(v_flow[tup]) * cost_ts(tup[5]) * temporals(tup[5]))
                end
            end
            # Spot-Market costs and profits
            if nodes[n].is_market
                # bidding market with balance market
                if markets[n].is_bid
                    price_ts = markets[n].price(s)
                    price_up_ts = markets[n].up_price(s)
                    price_dw_ts = markets[n].down_price(s)
                    for t in temporals.t
                        tup = (nodes[n].name,s,t)
                        tup_up = (nodes[n].name,"up",s,t)
                        tup_dw = (nodes[n].name,"dw",s,t)
                        add_to_expression!(market_costs[s], -v_bid[tup] * price_ts(t) * temporals(t))
                        add_to_expression!(market_costs[s], v_flow_bal[tup_up] * price_up_ts(t) * temporals(t))
                        add_to_expression!(market_costs[s], -v_flow_bal[tup_dw] * price_dw_ts(t) * temporals(t))
                    end
                # non-bidding market
                else
                    flow_out = filter(x -> x[2] == n && x[4] == s, process_tuple)
                    flow_in = filter(x -> x[3] == n && x[4] == s, process_tuple)
                    price_ts = markets[n].price(s)

                    for tup in flow_out
                        add_to_expression!(market_costs[s], sum(v_flow[tup]) * price_ts(tup[5]) * temporals(tup[5]))
                    end
                    # Assuming what goes into the node is sold and has a negatuive cost
                    for tup in flow_in
                        add_to_expression!(market_costs[s],  - sum(v_flow[tup]) * price_ts(tup[5]) * temporals(tup[5]))
                    end
                end
            end
        end
    end

    # VOM_costs
    vom_costs = model_contents["expression"]["vom_costs"] = OrderedDict()
    for s in scenarios
        vom_costs[s] = AffExpr(0.0)
        for tup in unique(map(x->(x[1],x[2],x[3]),process_tuple))
            vom = filter(x->x.source == tup[2] && x.sink == tup[3], processes[tup[1]].topos)[1].VOM_cost
            if vom != 0
                flows = filter(x -> x[1:3] == tup && x[4] == s, process_tuple)
                for f in flows
                    add_to_expression!(vom_costs[s], sum(v_flow[f]) * vom * temporals(f[5]))
                end
            end
        end
    end

    # Start costs
    start_costs = model_contents["expression"]["start_costs"] = OrderedDict()
    for s in scenarios
        start_costs[s] = AffExpr(0.0)
    end
    if input_data.contains_online
        proc_online_tuple = online_process_tuples(input_data)
        for s in scenarios
            for p in keys(processes)
                start_tup = filter(x->x[1] == p && x[2]==s,proc_online_tuple)
                if !isempty(start_tup)
                    v_start = model_contents["variable"]["v_start"]
                    cost = processes[p].start_cost
                    add_to_expression!(start_costs[s], sum(v_start[start_tup]) * cost)
                end
            end
        end
    end

    # Reserve profits:
    reserve_costs = model_contents["expression"]["reserve_costs"] = OrderedDict()
    for s in scenarios
        reserve_costs[s] = AffExpr(0.0)
    end
    if input_data.contains_reserves
        v_res_final = model_contents["variable"]["v_res_final"]
        res_final_tuple = reserve_market_tuples(input_data)
        for s in scenarios
            for tup in filter(x -> x[2] == s, res_final_tuple)
                price = markets[tup[1]].price(s, tup[3])
                add_to_expression!(reserve_costs[s],-price*v_res_final[tup])
            end
        end
    end

    # Reserve fee costs:
    reserve_fees = model_contents["expression"]["reserve_fee_costs"] = OrderedDict()
    for s in scenarios
        reserve_fees[s] = AffExpr(0.0)
    end
    if input_data.contains_reserves
        v_reserve_online = model_contents["variable"]["v_reserve_online"]
        res_online_tuple = create_reserve_limits(input_data)
        for s in scenarios
            for tup in filter(x->x[2] == s, res_online_tuple)
                add_to_expression!(reserve_fees[s], markets[tup[1]].fee * v_reserve_online[tup])
            end
        end
    end

    # Setpoint deviation costs
    setpoint_deviation_costs = model_contents["expression"]["setpoint_deviation_costs"] = OrderedDict()
    v_set_up = model_contents["variable"]["v_set_up"]
    v_set_down = model_contents["variable"]["v_set_down"]
    for s in scenarios
        setpoint_deviation_costs[s] = AffExpr(0.0)
    end
    for c in collect(keys(input_data.gen_constraints))
        if input_data.gen_constraints[c].is_setpoint
            penalty = input_data.gen_constraints[c].penalty
            for s in scenarios
                c_tups = filter(tup -> tup[1] == c && tup[2] == s, setpoint_tuples(input_data))
                add_to_expression!(setpoint_deviation_costs[s], penalty * (sum(v_set_up[c_tups]) + sum(v_set_down[c_tups])))
            end
        end
    end

    # State residue costs
    state_residue_costs = model_contents["expression"]["state_residue_costs"] = OrderedDict()
    for s in scenarios
        state_residue_costs[s] = AffExpr(0.0)
    end
    if input_data.contains_states
        v_state = model_contents["variable"]["v_state"]
        state_node_tuple = state_node_tuples(input_data)
        for s in scenarios
            for tup in filter(x -> x[3] == temporals.t[end] && x[2] == s, state_node_tuple)
                add_to_expression!(state_residue_costs[s], -1 * nodes[tup[1]].state.residual_value * v_state[tup])
            end
        end
    end

    # Dummy variable costs
    vq_state_up = model_contents["variable"]["vq_state_up"]
    vq_state_dw = model_contents["variable"]["vq_state_dw"]
    dummy_costs = model_contents["expression"]["dummy_costs"] = OrderedDict()
    p = 1000000
    for s in scenarios
        dummy_costs[s] = AffExpr(0.0) 
        for tup in filter(x->x[2]==s,node_balance_tuple)
            add_to_expression!(dummy_costs[s], sum(vq_state_up[tup])*p + sum(vq_state_dw[tup])*p)
        end
    end
    

    # Total model costs
    total_costs = model_contents["expression"]["total_costs"] = OrderedDict()
    for s in scenarios
        total_costs[s] = sum(commodity_costs[s]) + sum(market_costs[s]) + sum(vom_costs[s]) + sum(reserve_costs[s]) + sum(start_costs[s]) + sum(state_residue_costs[s]) + sum(reserve_fees[s]) + sum(setpoint_deviation_costs[s]) + sum(dummy_costs[s])
    end
end


"""
    setup_cvar_element(model_contents::OrderedDict, input_data::Predicer.InputData)

Setup expressions used for calculating the cvar in the model. 

# Arguments
- `model_contents::OrderedDict`: Dictionary containing all data and structures used in the model. 
- `input_data::OrderedDict`: Dictionary containing data used to build the model. 
"""
function setup_cvar_element(model_contents::OrderedDict, input_data::Predicer.InputData)
    if input_data.contains_risk
        model = model_contents["model"]
        total_costs = model_contents["expression"]["total_costs"]
        v_var = model_contents["variable"]["v_var"]
        v_cvar_z = model_contents["variable"]["v_cvar_z"]
        scenarios = collect(keys(input_data.scenarios))
        scen_p = collect(values(input_data.scenarios))
        alfa = input_data.risk["alfa"]
        cvar_constraint = @constraint(model, cvar_constraint[s in scenarios], v_cvar_z[s] >= total_costs[s]-v_var)
        model_contents["constraint"]["cvar_constraint"] = cvar_constraint
        model_contents["expression"]["cvar"] = @expression(model, sum(v_var)+(1/(1-alfa))*sum(values(scen_p).*v_cvar_z[scenarios]))
    end
end


"""
    setup_objective_function(model_contents::OrderedDict, input_data::Predicer.InputData)

Sets up the objective function, which in this model aims to minimize the costs.
"""
function setup_objective_function(model_contents::OrderedDict, input_data::Predicer.InputData)
    model = model_contents["model"]
    total_costs = model_contents["expression"]["total_costs"]
    scen_p = collect(values(input_data.scenarios))
    if input_data.contains_risk
        beta = input_data.risk["beta"]
        cvar = model_contents["expression"]["cvar"]
        @objective(model, Min, (1-beta)*sum(values(scen_p).*values(total_costs))+beta*cvar)
    else
        @objective(model, Min, sum(values(scen_p).*values(total_costs)))
    end
end