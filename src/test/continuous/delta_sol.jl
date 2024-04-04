_symbolic_subset(a, b) = all(av->any(bv->isequal(av, bv), b), a) 

function namespace_symbol(prefix, sym)
    return Symbol(string(prefix) * "/" * string(sym))
end

function make_cols(names, rows)
    cols = []
    for (i, name) in enumerate(names)
        col = zeros(length(rows))
        for (j, row) in enumerate(rows)
            col[j] = row[i]
        end
        push!(cols, name=>col)
    end
    return cols
end

function compare_solutions(
    (ref_name, reference)::Pair{Symbol, <:SciMLBase.AbstractTimeseriesSolution},
    sols::Vector{<:Pair{Symbol, <:SciMLBase.AbstractTimeseriesSolution}};
    knots=nothing)
    if isnothing(knots)
        knots = reference.t
    end
    results = Dict{Symbol, Any}()
    reference_container = symbolic_container(reference)
    containers = symbolic_container.(last.(sols))

    measured_reference = measured_values(reference_container)
    sols_measured = measured_values.(containers)
    @assert all(_symbolic_subset.((measured_reference,), sols_measured)) "Test solutions must expose a superset of the reference's variables for comparison"
    @assert length(measured_reference) > 0 "Compared solutions must share at least one measured variable"
    measured = measured_reference

    if knots != reference.t && !reference.dense
        @assert reference.dense "Interpolated evaluation points require a dense reference solution"
    end

    ref_t_vars = independent_variable_symbols(reference_container)
    if length(ref_t_vars) > 1
        @error "PDE solutions not currently supported; only one iv is allowed"
    end
    ref_t_var = first(ref_t_vars)
    if knots == reference.t
        ref_soln = reference[measured]
        cols = make_cols([Symbol(ref_t_var); namespace_symbol.((ref_name,), measured)], reference[[ref_t_var; measured]])
    else 
        ref_soln = reference(knots, idxs=measured)
        cols = make_cols([Symbol(ref_t_var); namespace_symbol.((ref_name,), measured)], reference(knots, idxs=[ref_t_var; measured]))
    end
    testsols = Dict{Symbol, Any}()
    results[:metrics] = testsols
    for (name, test) in sols 
        test_results = Dict{Symbol, Any}()
        if test.dense
            test_soln = test(knots, idxs=measured)
        elseif knots == sol.t
            test_soln = test[measured]
        else 
            @warn "Comparison of $ref_name to $name is invalid (cannot match timebases); only computing final state error"
            continue
        end
        test_results[:final] = recursive_mean(abs.(ref_soln[end] - test_soln[end]))
        compute_error_metrics(test_results, ref_soln, test_soln)
        append!(cols, make_cols(namespace_symbol.((name,), measured), test_soln))
        testsols[name] = test_results
    end
    results[:data] = DataFrame(cols)
    return results
end
export compare_solutions

function compare_dense_solutions(
    (ref_name, reference)::Pair{Symbol, <:SciMLBase.AbstractTimeseriesSolution},
    sols::Vector{<:Pair{Symbol, <:SciMLBase.AbstractTimeseriesSolution}};
    integrator=Tsit5(),
    metric=abs
)
    results = Dict{Symbol, Any}()
    reference_container = symbolic_container(reference)
    containers = symbolic_container.(last.(sols))

    measured_reference = measured_values(reference_container)
    sols_measured = measured_values.(containers)
    @assert all(_symbolic_subset.((measured_reference,), sols_measured)) "Test solutions must expose a superset of the reference's variables for comparison"
    @assert length(measured_reference) > 0 "Compared solutions must share at least one measured variable"
    measured = measured_reference

    timebounds(sol) = (sol.t[1], sol.t[end])
    @assert reference.dense "Dense (integrated) comparision requires a dense reference solution"
    for (test_name, test_sol) in sols
        @assert test_sol.dense "Test solution $(test_name) must be dense in order to use continous-time comparison"
        @assert timebounds(test_sol) == timebounds(reference) "Test solution $(test_name) has time range $(timebounds(test_sol)) which differs from the reference $(timebounds(reference))"
    end


    ref_t_vars = independent_variable_symbols(reference_container)
    if length(ref_t_vars) > 1
        @error "PDE solutions not currently supported; only one iv is allowed"
    end
    ref_t_var = first(ref_t_vars) 

    state_size = length(measured)
    function compare!(du, u, p, t) 
        offs = 1
        for (test_name, test_sol) in sols
            du[offs:offs+state_size-1] .= abs.(reference(t, idxs=measured) .- test_sol(t, idxs=measured))
            offs += state_size
        end
    end
    func = ODEFunction(compare!; sys = SymbolCache(collect(Iterators.flatten([namespace_symbol.((test_name, ), measured) for (test_name, _) in sols])), [], ref_t_var))
    prob = ODEProblem(func, zeros(length(sols) * length(measured)), timebounds(reference))
    soln = solve(prob, integrator)
    return soln
end
export compare_dense_solutions

function compute_error_metrics(
    output_results, 
    ref_soln, test_soln)
    delta = ref_soln - test_soln
    output_results[:l∞] = maximum(vecvecapply((x) -> abs.(x), delta))
    output_results[:l2] = sqrt(recursive_mean(vecvecapply((x) -> float(x) .^ 2, delta)))
end