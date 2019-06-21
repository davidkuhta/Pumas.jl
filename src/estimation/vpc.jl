#Structures to store the quantiles of the simulations per dv, stratification and quantile
struct VPC_QUANT
  Fiftieth
  Fifth_Ninetyfifth
  Simulation_Percentiles
end

struct OBS_QUANT
  Observation_Quantiles
end

struct VPC_STRAT
  vpc_quant::Vector{VPC_QUANT}
  strat
end

struct VPC_DV
  vpc_strat::Vector{VPC_STRAT}
  dv
end

struct VPC
  vpc_dv::Vector{VPC_DV}
	Observation_quantile
  Simulations
  idv
end

#Compute the quantiles of the stratification covariate
function get_strat(data::Population, stratify_on)
  strat_vals = []
  cov_vals = Float64[]
  for i in 1:length(data)
    push!(cov_vals, getproperty(data[i].covariates,stratify_on))
  end
  if length(unique(cov_vals)) <= 4
    return unique(cov_vals)
  else
    return quantile(cov_vals, [0.25,0.5,0.75,1.0])
  end
end

#Compute quantiles of the simulations for the population for a dv, idv and strata
function get_simulation_quantiles(sims, reps::Integer, dv_, idv_, quantiles, strat_quant, stratify_on)
  pop_quantiles = []
  for i in 1:reps
    sim = sims[i]
    quantiles_sim = []
    for t in 1:length(idv_)
      sims_t = [Float64[] for i in 1:length(strat_quant)]
      for j in 1:length(sim.sims)
        for strt in 1:length(strat_quant)
          if  stratify_on == nothing || (length(strat_quant)<4 && stratify_on != nothing && sim.sims[j].subject.covariates[stratify_on] <= strat_quant[strt])
            push!(sims_t[strt], getproperty(sim[j].observed,dv_)[t])
          elseif stratify_on != nothing && sim.sims[j].subject.covariates[stratify_on] <= strat_quant[strt]
            if strt > 1 && sim.sims[j].subject.covariates[stratify_on] > strat_quant[strt-1]
              push!(sims_t[strt], getproperty(sim[j].observed,dv_)[t])
            elseif strt == 1
              push!(sims_t[strt], getproperty(sim[j].observed,dv_)[t])
            end
          end
        end
      end
      push!(quantiles_sim, [quantile(sims_t[strt],quantiles) for strt in 1:length(strat_quant)])
    end 
    push!(pop_quantiles,quantiles_sim)
  end
  pop_quantiles
end

function get_observation_quantiles(data, dv_, idv_, quantiles, strat_quant, stratify_on)
  quantiles_obs = []
  obs_t = []
  for strt in 1:length(strat_quant)
    push!(obs_t, [Float64[] for i in 1:length(idv_)])
    for t in 1:length(idv_)
      for j in 1:length(data)
        if  stratify_on == nothing || (length(strat_quant)<4 && stratify_on != nothing && data[j].covariates[stratify_on] <= strat_quant[strt])
          push!(obs_t[strt][t], getproperty(data[j].observations,dv_)[t])
        elseif stratify_on != nothing && data[j].covariates[stratify_on] <= strat_quant[strt]
          if strt > 1 && data[j].covariates[stratify_on] > strat_quant[strt-1]
            push!(obs_t[strt][t], getproperty(data[j].observations,dv_)[t])
          elseif strt == 1
            push!(obs_t[strt][t], getproperty(data[j].observations,dv_)[t])
          end
        end
      end
    end
    push!(quantiles_obs, OBS_QUANT([quantile(obs_t[strt][t],quantiles[2]) for t in 1:length(idv_)]))
  end 
  quantiles_obs
end

#Compute quantiles of the quantiles to get the values for the ribbons 
function get_quant_quantiles(pop_quantiles, reps, idv_, quantiles, strat_quant)
  quantile_quantiles = []
  for strt in 1:length(strat_quant)
    quantile_strat = []
    for t in 1:length(idv_)
      quantile_time = []
      for j in 1:length(pop_quantiles[1][t][1])
        quantile_index = Float64[]
        for i in 1:reps
          push!(quantile_index,pop_quantiles[i][t][strt][j])
        end
        push!(quantile_time, quantile(quantile_index,quantiles))
      end
      push!(quantile_strat,quantile_time)
    end
    push!(quantile_quantiles,quantile_strat)
  end
  quantile_quantiles
end

#For each strata store it's quantiles of the quantiles
function get_vpc(quantile_quantiles, data, dv_, idv_, sims ,quantiles, strat_quant, stratify_on)
  vpc_strat = VPC_QUANT[]
  for strt in 1:length(strat_quant)
    fifty_percentiles = []
    fith_ninetyfifth = []
    for i in 1:3
      push!(fifty_percentiles,[j[i][2] for j in quantile_quantiles[strt]])
      push!(fith_ninetyfifth, [(j[i][1],j[i][3]) for j in quantile_quantiles[strt]])
    end
    push!(vpc_strat, VPC_QUANT(fifty_percentiles, fith_ninetyfifth, quantile_quantiles))
  end
  VPC_STRAT(vpc_strat, stratify_on)
end

#Main function for vpc to calculate the quantiles and get a VPC object with stratified quantiles per dv and idv
function vpc(m::PuMaSModel, data::Population, fixeffs::NamedTuple, reps::Integer;quantiles = [0.05,0.5,0.95], idv = :time, dv = [:dv], stratify_on = nothing)
  # rand_seed = rand()
  # Random.seed!(rand_seed)
  # println("Seed set as $rand_seed")
  vpcs = VPC_DV[]
  obs_vpc = []
  strat_quants = []
  if stratify_on != nothing
    for strt in stratify_on
      strat_quant = get_strat(data, strt)
      push!(strat_quants , strat_quant)
    end
  else
    push!(strat_quants, 1)
  end

  if idv == :time
    idv_ = getproperty(data[1], idv)
  else 
    idv_ = getproperty(data[1].covariates, idv)
  end

  sims = []
  for i in 1:reps
    sim = simobs(m, data, fixeffs)
    push!(sims, sim)
  end

  for dv_ in dv
    stratified_vpc = VPC_STRAT[]
    obs_vpc_dv = [] 
    for strat in 1:length(strat_quants)

      if stratify_on != nothing
        pop_quantiles = get_simulation_quantiles(sims, reps, dv_, idv_, quantiles, strat_quants[strat],stratify_on[strat])
        quantile_quantiles = get_quant_quantiles(pop_quantiles,reps,idv_,quantiles, strat_quants[strat])
        vpc_strat = get_vpc(quantile_quantiles, data, dv_, idv_, sims, quantiles, strat_quants[strat], stratify_on[strat])
        obs_quantiles = get_observation_quantiles(data, dv_, idv_, quantiles, strat_quants[strat], stratify_on[strat])
      else
        pop_quantiles = get_simulation_quantiles(sims, reps, dv_, idv_, quantiles, strat_quants[strat],nothing)
        quantile_quantiles = get_quant_quantiles(pop_quantiles,reps,idv_,quantiles, strat_quants[strat])
        vpc_strat = get_vpc(quantile_quantiles, data, dv_, idv_, sims, quantiles, strat_quants[strat], nothing)
        obs_quantiles = get_observation_quantiles(data, dv_, idv_, quantiles, strat_quants[strat], nothing)
      end

      push!(obs_vpc_dv, obs_quantiles)
      push!(stratified_vpc, vpc_strat)
    end
    push!(vpcs, VPC_DV(stratified_vpc, dv_))
    push!(obs_vpc, obs_vpc_dv) 
  end
  VPC(vpcs, obs_vpc, sims, idv)
end

#Use FittedPuMaSModel object for vpc
function vpc(fpm::FittedPuMaSModel, reps::Integer, data::Population=fpm.data;quantiles = [0.05,0.5,0.95], idv = :time, dv = [:dv], stratify_on = nothing)
  vpc(fpm.model, fpm.data, fpm.param, reps, quantiles=quantiles, idv=idv, dv=dv, stratify_on=stratify_on)
end

# #Use simulations from a previous vpc calculation for a different statification
function vpc(sims, data::Population;quantiles = [0.05,0.5,0.95], idv = :time, dv = [:dv], stratify_on = nothing)
  # rand_seed = rand()
  # Random.seed!(rand_seed)
  # println("Seed set as $rand_seed")
  if typeof(sims) == VPC
    sims = sims.Simulations
  end

  if idv == :time
    idv_ = getproperty(data[1], idv)
  else 
    idv_ = getproperty(data[1].covariates, idv)
  end

  vpcs = []
  obs_vpc = []
  strat_quants = []
  if stratify_on != nothing
    for strt in stratify_on
      strat_quant = get_strat(data, strt)
      push!(strat_quants, strat_quant)
    end
  else
    push!(strat_quants, 1)
  end

  for dv_ in dv
    stratified_vpc = VPC_STRAT[]
    obs_vpc_dv = [] 
    for strat in 1:length(strat_quants)

      if stratify_on != nothing
        pop_quantiles = get_simulation_quantiles(sims, reps, dv_, idv_, quantiles, strat_quants[strat],stratify_on[strat])
        quantile_quantiles = get_quant_quantiles(pop_quantiles,reps,idv_,quantiles, strat_quants[strat])
        vpc_strat = get_vpc(quantile_quantiles, data, dv_, idv_, sims, quantiles, strat_quants[strat], stratify_on[strat])
        obs_quantiles = get_observation_quantiles(data, dv_, idv_, quantiles, strat_quants[strat], stratify_on[strat])
      else
        pop_quantiles = get_simulation_quantiles(sims, reps, dv_, idv_, quantiles, strat_quants[strat],nothing)
        quantile_quantiles = get_quant_quantiles(pop_quantiles,reps,idv_,quantiles, strat_quants[strat])
        vpc_strat = get_vpc(quantile_quantiles, data, dv_, idv_, sims, quantiles, strat_quants[strat], nothing)
        obs_quantiles = get_observation_quantiles(data, dv_, idv_, quantiles, strat_quants[strat], nothing)
      end

      push!(obs_vpc_dv, obs_quantiles)
      push!(stratified_vpc, vpc_strat)
    end
    push!(vpcs, VPC_DV(stratified_vpc, dv_))
    push!(obs_vpc, obs_vpc_dv) 
  end
  VPC(vpcs, obs_vpc, sims, idv)
end

# function Base.show(io::IO, mime::MIME"text/plain", vpc::VPC)
  
# end

#Recipes for the VPC and subsequent objects that store the quantiles per dv, strata and quantiles
@recipe function f(vpc::VPC, data::Population)
  if vpc.idv == :time
    t = getproperty(data[1], vpc.idv)
  else 
    t = getproperty(data[1].covariates, vpc.idv)
  end
  for i in 1:length(vpc.vpc_dv)
    @series begin
      t, vpc.vpc_dv[i], vpc.Observation_quantile[i], vpc.idv
    end
  end
  
end

@recipe function f(t, vpc_dv::VPC_DV, data, idv=:time)
  for strt in 1:length(vpc_dv.vpc_strat)
    @series begin
      t, vpc_dv.vpc_strat[strt], data[strt], idv
    end
  end
end

@recipe function f(t, vpc_strt::VPC_STRAT, data, idv=:time)
  layout --> length(vpc_strt.vpc_quant)
  if vpc_strt.strat != nothing
    title --> "Stratified on:"*string(vpc_strt.strat)
  end
  for quant in 1:length(vpc_strt.vpc_quant)
    @series begin
      subplot := quant
      t, vpc_strt.vpc_quant[quant], data[quant], idv
    end
  end
end

@recipe function f(t, vpc_quant::VPC_QUANT, data, idv=:time)
  legend --> false
  lw --> 3
  ribbon := vpc_quant.Fifth_Ninetyfifth
  fillalpha := 0.2
  xlabel --> string(idv)
  ylabel --> "Observations"
  if data != nothing
    t, vpc_quant.Fiftieth, data
  else 
    t, vpc_quant.Fiftieth
  end
end

@recipe function f(data::OBS_QUANT)
  fiftieth = [quant[2] for quant in data.Observation_Quantiles]
  fiftieth
end