"""
    PuMaSModel

A model takes the following arguments
- `param`: a `ParamSet` detailing the parameters and their domain
- `random`: a mapping from a named tuple of parameters -> `DistSet`
- `pre`: a mapping from the (params, randeffs, subject) -> ODE params
- `init`: a mapping (col,t0) -> inital conditions
- `prob`: a DEProblem describing the dynamics (either exact or analytical)
- `derived`: the derived variables and error distributions (param, randeffs, data, ode vals) -> sampling dist
- `observed`: simulated values from the error model and post processing: (param, randeffs, data, ode vals, samples) -> vals
"""
mutable struct PuMaSModel{P,Q,R,S,T,V,W}
  param::P
  random::Q
  pre::R
  init::S
  prob::T
  derived::V
  observed::W
end
PuMaSModel(param,random,pre,init,prob,derived) =
    PuMaSModel(param,random,pre,init,prob,derived,(col,sol,obstimes,samples,subject)->samples)

init_param(m::PuMaSModel) = init(m.param)
init_randeffs(m::PuMaSModel, param) = init(m.random(param))

"""
    sample_randeffs(m::PuMaSModel, param)

Generate a random set of random effects for model `m`, using parameters `param`.
"""
sample_randeffs(m::PuMaSModel, param) = rand(m.random(param))


"""
    sol = pkpd_solve(m::PuMaSModel, subject::Subject, param,
                     randeffs=sample_randeffs(m, param),
                     args...; kwargs...)

Compute the ODE for model `m`, with parameters `param` and random effects
`randeffs`. `alg` and `kwargs` are passed to the ODE solver. If no `randeffs` are
given, then they are generated according to the distribution determined
in the model.

Returns a tuple containing the ODE solution `sol` and collation `col`.
"""
function DiffEqBase.solve(m::PuMaSModel, subject::Subject,
                          param = init_param(m),
                          randeffs = sample_randeffs(m, param),
                          args...; kwargs...)
  m.prob === nothing && return nothing
  col = m.pre(param, randeffs, subject)
  _solve(m,subject,col,args...;kwargs...)
end

@enum ParallelType Serial=1 Threading=2 Distributed=3 SplitThreads=4
function DiffEqBase.solve(m::PuMaSModel, pop::Population,
                          param = init_param(m),
                          args...; parallel_type = Threading,
                          kwargs...)
  time = @elapsed if parallel_type == Serial
    sols = [solve(m,subject,param,args...;kwargs...) for subject in pop]
  elseif parallel_type == Threading
    _sols = Vector{Any}(undef,length(pop))
    Threads.@threads for i in 1:length(pop)
      _sols[i] = solve(m,pop[i],param,args...;kwargs...)
    end
    sols = [sol for sol in _sols] # Make strict typed
  elseif parallel_type == Distributed
    sols = pmap((subject)->solve(m,subject,param,args...;kwargs...),pop)
  elseif parallel_type == SplitThreads
    error("SplitThreads is not yet implemented")
  end
  MonteCarloSolution(sols,time,true)
end

"""
This internal function is just so that the collation doesn't need to
be repeated in the other API functions
"""
function _solve(m::PuMaSModel, subject, col, args...;
                tspan=nothing, kwargs...)
  m.prob === nothing && return nothing
  if tspan === nothing
    _tspan = timespan(subject)
    if m.prob isa DiffEqBase.DEProblem && !(m.prob.tspan === (nothing, nothing))
      _tspan = (min(_tspan[1], m.prob.tspan[1]),
                max(_tspan[2], m.prob.tspan[2]))
    end
    tspan_tmp = :saveat in keys(kwargs) ? (min(_tspan[1], first(kwargs[:saveat])), max(_tspan[2], last(kwargs[:saveat]))) : _tspan
    tspan = float.(tspan_tmp)
  end
  u0  = m.init(col, tspan[1])
  if m.prob isa ExplicitModel
    return _solve_analytical(m, subject, u0, tspan, col, args...;kwargs...)
  else
    mtmp = PuMaSModel(m.param,
                     m.random,
                     m.pre,
                     m.init,
                     remake(m.prob; p=col, u0=u0, tspan=tspan),
                     m.derived,
                     m.observed)
    return _solve_diffeq(mtmp, subject, args...;kwargs...)
  end
end

#=
_rand(d)

Samples a random value from a distribution or if it's a number assumes it's the
constant distribution and passes it through.
=#
_rand(d::Distributions.Sampleable) = rand(d)
_rand(d::AbstractArray{<:Distributions.Sampleable}) = map(_rand,d)
_rand(d) = d


zval(d) = 0.0
zval(d::Distributions.Normal{T}) where {T} = zero(T)

"""
    simobs(m::PuMaSModel, subject::Subject, param[, randeffs, [args...]];
                  obstimes=observationtimes(subject),kwargs...)

Simulate random observations from model `m` for `subject` with parameters `param` at
`obstimes` (by default, use the times of the existing observations for the subject). If no
`randeffs` is provided, then random ones are generated according to the distribution
in the model.
"""
function simobs(m::PuMaSModel, subject::Subject,
                param = init_param(m),
                randeffs=sample_randeffs(m, param),
                args...;
                obstimes=observationtimes(subject),
                saveat=obstimes,kwargs...)
  col = m.pre(param, randeffs, subject)
  isempty(obstimes) && throw(ArgumentError("obstimes is empty."))
  sol = _solve(m, subject, col, args...; saveat=obstimes, kwargs...)
  derived = m.derived(col,sol,obstimes,subject)
  obs = m.observed(col,sol,obstimes,map(_rand,derived),subject)
  SimulatedObservations(subject,obstimes,obs)
end

function simobs(m::PuMaSModel, pop::Population, args...;
                parallel_type = Threading, kwargs...)
  time = @elapsed if parallel_type == Serial
    sims = [simobs(m,subject,args...;kwargs...) for subject in pop]
  elseif parallel_type == Threading
    _sims = Vector{Any}(undef,length(pop))
    Threads.@threads for i in 1:length(pop)
      _sims[i] = simobs(m,pop[i],args...;kwargs...)
    end
    sims = [sim for sim in _sims] # Make strict typed
  elseif parallel_type == Distributed
    sims = pmap((subject)->simobs(m,subject,args...;kwargs...),pop)
  elseif parallel_type == SplitThreads
    error("SplitThreads is not yet implemented")
  end
  SimulatedPopulation(sims)
end

"""
    pre(m::PuMaSModel, subject::Subject, param, randeffs)

Returns the parameters of the differential equation for a specific subject
subject to parameter and random effects choices. Intended for internal use
and debugging.
"""
function pre(m::PuMaSModel, subject::Subject, param, randeffs)
  m.pre(param, randeffs, subject)
end
