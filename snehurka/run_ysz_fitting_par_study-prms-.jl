#!/usr/local/pkg/julia/1.0.3/bin/julia
#
#SBATCH --job-name=NYQ
#SBATCH -p express
#SBATCH --time=0-6


#module add julia
#module --ignore-cache load "julia"

include(string(pwd(),"/../examples/ysz_fitting.jl"))

ysz_fitting.par_study_script_wrap(ARGS[1], ARGS[2], ARGS[3], ARGS[4], ARGS[5], ARGS[6], ARGS[7])