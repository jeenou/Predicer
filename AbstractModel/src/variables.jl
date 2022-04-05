using JuMP
using DataStructures

"""
    create_variables(model_contents::OrderedDict)

Create the variables used in the model, and save them in the model_contents dict.

# Arguments
- `model_contents::OrderedDict`: Dictionary containing all data and structures used in the model. 
"""
function create_variables(model_contents::OrderedDict)
    create_v_flow(model_contents)
    create_v_online(model_contents)
    create_v_reserve(model_contents)
    create_v_state(model_contents)
    create_v_flow_op(model_contents)
end


"""
    create_v_flow(model_contents::OrderedDict)

Sets up v_flow, which is the variable symbolising flows between nodes/processes.

# Arguments
- `model_contents::OrderedDict`: Dictionary containing all data and structures used in the model. 
"""
function create_v_flow(model_contents::OrderedDict)
    process_tuple = model_contents["tuple"]["process_tuple"]
    model = model_contents["model"]
    v_flow = @variable(model, v_flow[tup in process_tuple] >= 0)
    model_contents["variable"]["v_flow"] = v_flow
end


"""
    create_v_online(model_contents::OrderedDict)

Sets up variables used for modelling functionality for processes with binary online variables, as well as starts/stops.

# Arguments
- `model_contents::OrderedDict`: Dictionary containing all data and structures used in the model. 
"""
function create_v_online(model_contents::OrderedDict)
    proc_online_tuple = model_contents["tuple"]["proc_online_tuple"]
    if !isempty(proc_online_tuple)
        model = model_contents["model"]
        v_online = @variable(model, v_online[tup in proc_online_tuple], Bin)
        v_start = @variable(model, v_start[tup in proc_online_tuple], Bin)
        v_stop = @variable(model, v_stop[tup in proc_online_tuple], Bin)
        model_contents["variable"]["v_online"] = v_online
        model_contents["variable"]["v_start"] = v_start
        model_contents["variable"]["v_stop"] = v_stop
    end
end


"""
    create_v_reserve(model_contents::OrderedDict)

Sets up the variables used for modelling reserves.

# Arguments
- `model_contents::OrderedDict`: Dictionary containing all data and structures used in the model. 
"""
function create_v_reserve(model_contents::OrderedDict)
    model = model_contents["model"]

    res_potential_tuple = model_contents["tuple"]["res_potential_tuple"]
    if !isempty(res_potential_tuple)
       v_reserve = @variable(model, v_reserve[tup in res_potential_tuple] >= 0)
       model_contents["variable"]["v_reserve"] = v_reserve
    end

    res_tuple = model_contents["tuple"]["res_tuple"]
    if !isempty(res_tuple)
        v_res = @variable(model, v_res[tup in res_tuple] >= 0)
        model_contents["variable"]["v_res"] = v_res
    end

    res_final_tuple = model_contents["tuple"]["res_final_tuple"]
    if !isempty(res_final_tuple)
        @variable(model, v_res_final[tup in res_final_tuple] >= 0)
        model_contents["variable"]["v_res_final"] = v_res_final
    end
end


"""
    create_v_state(model_contents::OrderedDict)

Sets up variables used for node state (storage) functionality.

# Arguments
- `model_contents::OrderedDict`: Dictionary containing all data and structures used in the model. 
"""
function create_v_state(model_contents::OrderedDict)
    model = model_contents["model"]
    node_state_tuple = model_contents["tuple"]["node_state_tuple"]
    node_balance_tuple = model_contents["tuple"]["node_balance_tuple"]


    # Node state variable
    v_state = @variable(model, v_state[tup in node_state_tuple] >= 0)
    model_contents["variable"]["v_state"] = v_state

    # Dummy variables for node_states
    vq_state_up = @variable(model, vq_state_up[tup in node_balance_tuple] >= 0)
    vq_state_dw = @variable(model, vq_state_dw[tup in node_balance_tuple] >= 0)
    model_contents["variable"]["vq_state_up"] = vq_state_up
    model_contents["variable"]["vq_state_dw"] = vq_state_dw
end


"""
    create_v_flow_op(model_contents::OrderedDict)

Sets up variables for processes with piecewise efficiency functionality.

# Arguments
- `model_contents::OrderedDict`: Dictionary containing all data and structures used in the model. 
"""
function create_v_flow_op(model_contents::OrderedDict)
    model = model_contents["model"]
    proc_op_balance_tuple = model_contents["tuple"]["proc_op_balance_tuple"]
    v_flow_op_in = @variable(model,v_flow_op_in[tup in proc_op_balance_tuple] >= 0)
    v_flow_op_out = @variable(model,v_flow_op_out[tup in proc_op_balance_tuple] >= 0)
    v_flow_op_bin = @variable(model,v_flow_op_bin[tup in proc_op_balance_tuple], Bin)
    model_contents["variable"]["v_flow_op_in"] = v_flow_op_in
    model_contents["variable"]["v_flow_op_out"] = v_flow_op_out
    model_contents["variable"]["v_flow_op_bin"] = v_flow_op_bin
end