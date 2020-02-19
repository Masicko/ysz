module ysz_experiments
### WHAT was done since last commit ###############
# * phi_out = (phi_previous + phi)/2.0
# * AreaEllyt added to EIS current computation
# 
# TODO !!!
# [x] ramp for EIS steady state
###################################################






using Printf
using VoronoiFVM
using PyPlot
using DataFrames
using CSV
using LeastSquaresOptim

##########################################
# internal import of YSZ repo ############
#model_label = "ysz_model_GAS_exp_ads"
model_label = "ysz_model_GAS_LoMA"

include("../src/models/$(model_label).jl")
include("../prototypes/timedomain_impedance.jl")

model_symbol = eval(Symbol(model_label))
bulk_species = model_symbol.bulk_species
surface_species = model_symbol.surface_species
surface_names = model_symbol.surface_names
iphi = model_symbol.iphi
iy = model_symbol.iy
ib = model_symbol.ib

# --------- end of YSZ import ---------- #
##########################################



function run_new(;physical_model_name="",
                test=false, print_bool=false, debug_print_bool=false, out_df_bool=false,
                verbose=false, pyplot=false, pyplot_finall=false, save_files=false,
                width=0.0005, dx_exp=-9,
                pO2=1.0, T=1073,
                prms_names_in=["A0", "R0", "DGA", "DGR", "betaR", "SR"],
                prms_values_in=[21.71975544711280, 20.606423236896422, 0.0905748, -0.708014, 0.6074566741435283, 0.1], 
                EIS_IS=false,  EIS_bias=0.0, omega_range=(0.9, 1.0e+5, 1.1),
                voltammetry=false, voltrate=0.010, upp_bound=0.95, low_bound=-0.95, sample=30, dlcap=false,
                EIS_TDS=false, tref=0
                 )

    
    # prms_in = [ A0, R0, DGA, DGR, beta, A ]

    # Geometry of the problem
    #AreaEllyt = 0.000201 * 0.6      # m^2   (geometrical area)*(1 - porosity)
    AreaEllyt = 0.018849556 * 0.7        # m^2 (geometrical area)*(1 - porosity)
    #width_Ellyt = 0.00045           # m     width of the half-cell
    #width_Ellyt = 0.0005           # m     width of the half-cell
    if dlcap
        AreaEllyt = 1.0      # m^2    
        if print_bool
            println("dlcap > area = 1")
        end
    end
    #
    dx_start = 10^convert(Float64,dx_exp)
    X=width*VoronoiFVM.geomspace(0.0,1.0,dx_start,1e-1)
    #println("X = ",X)
    #
    grid=VoronoiFVM.Grid(X)
    #
    
    # Physical condtions and parameters setting
    parameters=model_symbol.YSZParameters()
    

    
    parameters.pO2 = pO2
    parameters.T = T
    parameters.x_frac=0.13
    
    model_symbol.set_parameters!(parameters, prms_values_in, prms_names_in)
    if dlcap
        parameters.R0 = 0
        if print_bool 
            println("dlcap > R0= ",parameters.R0)
        end
    end
    

    
    # update the "computed" values in parameters
    parameters = model_symbol.YSZParameters_update!(parameters)

#     if debug_print_bool 
#         println("NEW ---- ")
#         println("prms = ",prms_in)
#         println("add_prms = (",parameters.DD,",",parameters.nu,",",parameters.nus,",",parameters.ms_par,")")
#         println("rest_prms = (",parameters.T,",",parameters.pO2,")")
#     end
    
    
    #model_symbol.printfields(parameters)
    
    
    physics=VoronoiFVM.Physics(
        data=parameters,
        num_species=size(bulk_species,1)+size(surface_species,1),
        storage=model_symbol.storage!,
        flux=model_symbol.flux!,
        reaction=model_symbol.reaction!,
        breaction=model_symbol.breaction!,
        bstorage=model_symbol.bstorage!
    )
    #
    if print_bool
        model_symbol.printfields(parameters)
    end

    #sys=VoronoiFVM.SparseSystem(grid,physics)
    sys=VoronoiFVM.DenseSystem(grid,physics)
    for idx in bulk_species
      enable_species!(sys, idx, [1])
    end
    for idx in surface_species
      enable_boundary_species!(sys, idx, [1])
    end

    # boundary conditions
    model_symbol.set_typical_boundary_conditions!(sys, parameters)
    
    # initial value of type unknows(sys)
    inival = model_symbol.get_typical_initial_conditions(sys, parameters)
    
    # equilibrium voltage
    phi0 = model_symbol.equil_phi(parameters)
    if dlcap
        phi0 = 0
    end


    #
    control=VoronoiFVM.NewtonControl()
    control.verbose=verbose
    control.tol_linear=1.0e-4
    control.tol_relative=1.0e-5
    #control.tol_absolute=1.0e-4
    #control.max_iterations=3
    control.max_lureuse=0
    control.damp_initial=1.0e-6
    control.damp_growth=1.3
    
    #####################################
    #####################################
    #####################################
    #####################################
    #####################################
    ######### EIS computation #############
    if EIS_IS || EIS_TDS
        #
        # Transient part of measurement functional 
        #
        function meas_tran(meas, u)
          model_symbol.meas_tran(meas, u, sys, parameters, AreaEllyt, X)
        end
        #
        # Steady part of measurement functional
        #
        function meas_stdy(meas, u)
          model_symbol.meas_stdy(meas, u, sys, parameters, AreaEllyt, X)
        end
        
        #
        # The overall measurement (in the time domain) is meas_stdy(u)+ d/dt meas_tran(u)
        #

        # Calculate steady state solution
        steadystate = unknowns(sys)
        phi_steady = phi0 + EIS_bias
        
        excited_spec=iphi
        excited_bc=1
        excited_bcval=phi_steady
        
        
        # relaxation (ramp to phi_steady)
        ramp_isok = false
        ramp_nodes_growth = 4 # each phi_step will be divided into $ parts
        ramp_max_nodes = 30   # number of refinement of phi_step
        steadystate_old = deepcopy(inival)
        for ramp_nodes in (0 : ramp_nodes_growth : ramp_max_nodes)
          steadystate_old = deepcopy(inival)
          
          for phi_ramp in (ramp_nodes == 0 ? phi_steady : collect(0.0 : phi_steady/ramp_nodes : phi_steady))
            # println("phi_steady / phi_ramp = ",phi_steady," / ",phi_ramp)
              try
                #@show phi_ramp
                sys.boundary_values[iphi,1] = phi_ramp
                solve!(steadystate, steadystate_old, sys, control=control)
                steadystate_old .= steadystate
                
                ramp_isok = true
                
              catch e
                if e isa InterruptException
                  rethrow(e)
                else
                  #println("fail")
                  ramp_isok=false
                  break
                end
              end
          end
          if ramp_isok
            break
          end
        end
        if !(ramp_isok)
          print("ERROR: run_new: ramp cannot reach the steady state") 
          throw(Exception)
        end

        # Create impedance system
        isys=VoronoiFVM.ImpedanceSystem(sys,steadystate,excited_spec, excited_bc)

        # Derivatives of measurement functionals
        # For the Julia magic behind this we need the measurement functionals
        # as mutating functions writing on vectors.
        dmeas_stdy=measurement_derivative(sys,meas_stdy,steadystate)
        dmeas_tran=measurement_derivative(sys,meas_tran,steadystate)


        
        # Impedance arrays
        z_timedomain=zeros(Complex{Float64},0)
        z_freqdomain=zeros(Complex{Float64},0)
        all_w=zeros(0)

        w = omega_range[1]

        # Frequency loop
        while w < omega_range[2]
            print_bool && @show w
            push!(all_w,w)
            if EIS_IS
                # Here, we use the derivatives of the measurement functional
                zfreq=freqdomain_impedance(isys,w,steadystate,excited_spec,excited_bc,excited_bcval,dmeas_stdy, dmeas_tran)
                inductance = im*parameters.L*w
                push!(z_freqdomain, inductance + 1.0/zfreq)
                print_bool && @show zfreq
            end
            
            if EIS_TDS
                # Similar API, but use the the measurement functional themselves    
                ztime=timedomain_impedance(sys,w,steadystate,excited_spec,excited_bc,excited_bcval,meas_stdy, meas_tran,
                                    tref=tref,
                                    fit=true)
                push!(z_timedomain,1.0/ztime)
                print_bool && @show ztime
            end


            
            # growth factor such that there are 10 points in every order of magnitude
            # (which is consistent with "freq" list below)
            #w=w*1.25892           
            w = w*omega_range[3]
        end


        if pyplot
            function positive_angle(z)
                ϕ=angle(z)
                if ϕ<0.0
                    ϕ=ϕ+2*π
                end
                return ϕ
            end

            PyPlot.clf()
            PyPlot.subplot(311)
            PyPlot.grid()

            if EIS_IS
                PyPlot.semilogx(all_w,positive_angle.(1.0/z_freqdomain)',label="\$i\\omega\$",color=:red)
            end
            if EIS_TDS
                PyPlot.semilogx(all_w,positive_angle.(1.0/z_timedomain)',label="\$\\frac{d}{dt}\$",color=:green)
            end
            PyPlot.xlabel("\$\\omega\$")
            PyPlot.ylabel("\$\\phi\$")
            PyPlot.legend(loc="upper left")


            PyPlot.subplot(312)
            PyPlot.grid()
            if EIS_IS
                PyPlot.loglog(all_w,abs.(1.0/z_freqdomain)',label="\$i\\omega\$",color=:red)
            end
            if EIS_TDS
                PyPlot.loglog(all_w,abs.(1.0/z_timedomain)',label="\$\\frac{d}{dt}\$",color=:green)
            end
            PyPlot.xlabel("\$\\omega\$")
            PyPlot.ylabel("a")
            PyPlot.legend(loc="lower left")

            
            ax=PyPlot.subplot(313)
            PyPlot.grid()
            ax.set_aspect(aspect=1.0)
            if EIS_IS
                plot(real(z_freqdomain),-imag(z_freqdomain),label="\$i\\omega\$", color=:red)
            end
            if EIS_TDS
                plot(real(z_timedomain),-imag(z_timedomain),label="\$\\frac{d}{dt}\$", color=:green)
            end
            PyPlot.xlabel("Re")
            PyPlot.ylabel("Im")
            PyPlot.legend(loc="lower center")
            PyPlot.tight_layout()
            pause(1.0e-10)
        end
        
        if out_df_bool
            EIS_df = DataFrame(f = all_w, Z = z_freqdomain)
            return EIS_df
        end
    end

    #########################################
    #########################################
    #########################################
    #########################################
    #########################################
    #########################################
    #########################################
    #########################################
    
    # code for performing CV
    if voltammetry
        istep=1
        phi=0
        phi_prev = 0
        phi_out = 0

        # inicializing storage lists
        y0_range=zeros(0)
        surface_species_range=Array{Float64}(undef, (size(surface_species,1), 0))
        yOs_range=zeros(0)
        phi_range=zeros(0)
        #
        Is_range=zeros(0)
        Ib_range=zeros(0)
        Ibb_range=zeros(0)
        Ir_range=zeros(0)
        
        if save_files || out_df_bool
            out_df = DataFrame(t = Float64[], U = Float64[], I = Float64[], Ib = Float64[], Is = Float64[], Ir = Float64[])
        end
        
        cv_cycles = 1
        relaxation_length = 1    # how many "(cv_cycle/4)" should relaxation last
        relax_counter = 0
        istep_cv_start = -1
        time_range = zeros(0)  # [s]

        if print_bool
            print("calculating linear potential sweep\n")
        end
        direction_switch_count = 0

        tstep=((upp_bound-low_bound)/2)/voltrate/sample   
        if print_bool
            @printf("tstep %g = \n", tstep)
        end
        if phi0 > 0
            dir=1
        else
            dir=-1
        end
        
        if pyplot
            PyPlot.close()
            PyPlot.ion()
            PyPlot.figure(figsize=(10,8))
            #PyPlot.figure(figsize=(5,5))
        end
        
        state = "ramp"
        if print_bool
            println("phi_equilibrium = ",phi0)
            println("ramp ......")
        end

        U = unknowns(sys)
        U0 = unknowns(sys)
        if test
            U .= inival
        end
        
        while state != "cv_is_off"
            if state=="ramp" && ((dir==1 && phi > phi0) || (dir==-1 && phi < phi0))
                phi = phi0
                state = "relaxation"
                if print_bool
                    println("relaxation ... ")
                end
            end            
            if state=="relaxation" && relax_counter == sample*relaxation_length
                relax_counter += 1
                state="cv_is_on"
                istep_cv_start = istep
                dir=1
                if print_bool
                    print("cv ~~~ direction switch: ")
                end
            end                            
            if state=="cv_is_on" && (phi <= low_bound-0.00000001+phi0 || phi >= upp_bound+0.00000001+phi0)
                dir*=(-1)
                # uncomment next line if phi should NOT go slightly beyond limits
                #phi+=2*voltrate*dir*tstep
            
                direction_switch_count +=1
                if print_bool
                    print(direction_switch_count,", ")
                end
            end       
            if state=="cv_is_on" && (dir > 0) && (phi > phi0 + voltrate*dir*tstep + 0.000001) && (direction_switch_count >=2*cv_cycles)
                state = "cv_is_off"
            end
            
            
            # tstep to potential phi
            sys.boundary_values[iphi,1]=phi
            solve!(U,inival,sys, control=control,tstep=tstep)
            Qb= - integrate(sys,model_symbol.reaction!,U) # \int n^F            
            dphi_end = U[iphi, end] - U[iphi, end-1]
            dx_end = X[end] - X[end-1]
            dphiB=parameters.eps0*(1+parameters.chi)*(dphi_end/dx_end)
            Qs= (parameters.e0/parameters.areaL)*parameters.zA*U[ib,1]*parameters.ms_par*(1-parameters.nus) # (e0*zA*nA_s)

                    
            # for faster computation, solving of "dtstep problem" is not performed
            U0 .= inival
            inival.=U
            Qb0 = - integrate(sys,model_symbol.reaction!,U0) # \int n^F
            dphi0_end = U0[iphi, end] - U0[iphi, end-1]
            dphiB0 = parameters.eps0*(1+parameters.chi)*(dphi0_end/dx_end)
            Qs0 = (parameters.e0/parameters.areaL)*parameters.zA*U0[ib,1]*parameters.ms_par*(1-parameters.nus) # (e0*zA*nA_s)


            
            # time derivatives
            Is  = - (Qs[1] - Qs0[1])/tstep                
            Ib  = - (Qb[iphi] - Qb0[iphi])/tstep 
            Ibb = - (dphiB - dphiB0)/tstep
            
            
            # reaction average
            reac = - 2*parameters.e0*model_symbol.electroreaction(parameters, U[:,1])
            reacd = - 2*parameters.e0*model_symbol.electroreaction(parameters,U0[:,1])
            Ir= 0.5*(reac + reacd)

            #############################################################
            #multiplication by area of electrode I = A * ( ... )
            Ibb = Ibb*AreaEllyt
            Ib = Ib*AreaEllyt
            Is = Is*AreaEllyt
            Ir = Ir*AreaEllyt
            #
            
            if debug_print_bool
                @printf("t = %g     U = %g   state = %s  ys = %g  ys0 = &g  Ir = %g  Is = %g  Ib = %g  \n", istep*tstep, phi, state, U[ib,1],  Ir, - (Qs[1] - Qs0[1])/tstep, - (Qb[iphi] - Qb0[iphi])/tstep)
            end
            
            # storing data
            append!(y0_range,U[iy,1])
            
            surface_species_to_append = []
            for (i, idx) in enumerate(surface_species)
              append!(surface_species_to_append,U[idx,1])
            end
            surface_species_range = hcat(surface_species_range, surface_species_to_append)
            
            append!(phi_range,phi_out)
            #
            append!(Ib_range,Ib)
            append!(Is_range,Is)
            append!(Ibb_range,Ibb)
            append!(Ir_range, Ir)
            #
            append!(time_range,tstep*istep)
            
            if state=="cv_is_on"
                if save_files || out_df_bool
                    if dlcap
                        push!(out_df,[(istep-istep_cv_start)*tstep   phi_out-phi0    (Ib+Is+Ir)/voltrate    Ib/voltrate    Is/voltrate    Ir/voltrate])
                    else
                        push!(out_df,[(istep-istep_cv_start)*tstep   phi_out-phi0    Ib+Is+Ir    Ib    Is    Ir])
                    end
                end
            end
            
            
            
            # plotting                  


            if pyplot && istep%2 == 0

                num_subplots=4
                ys_marker_size=6
                PyPlot.subplots_adjust(hspace=0.5)
            
                PyPlot.clf() 
                
                if num_subplots > 0
                    subplot(num_subplots*100 + 11)
                    plot((10^9)*X[:],U[iphi,:],label="phi (V)")
                    plot((10^9)*X[:],U[iy,:],label="y")
                    for (i, idx) in enumerate(surface_species)
                      plot(0,U[idx,1],"o", markersize=ys_marker_size, label=surface_names[i])
                    end
                    l_plot = 5.0
                    PyPlot.xlim(-0.01*l_plot, l_plot)
                    PyPlot.ylim(-0.5,1.1)
                    PyPlot.xlabel("x (nm)")
                    PyPlot.legend(loc="best")
                    PyPlot.grid()
                end
                
                if (long_domain_plot_bool=true)
                    if num_subplots > 1
                        subplot(num_subplots*100 + 12)
                        plot((10^3)*X[:],U[iphi,:],label="phi (V)")
                        plot((10^3)*X[:],U[iy,:],label="y")
                        for (i, idx) in enumerate(surface_species)
                          plot(0,U[idx,1],"o", markersize=ys_marker_size, label=surface_names[i])
                        end
                        PyPlot.ylim(-0.5,1.1)
                        PyPlot.xlabel("x (mm)")
                        PyPlot.legend(loc="best")
                        PyPlot.grid()
                    end
                else
                    if (num_subplots > 1) && (istep_cv_start > -1)
                        cv_range = (istep_cv_start+1):length(phi_range)
                        subplot(num_subplots*100 + 12)
                        plot(phi_range[cv_range].-phi0, ((Is_range + Ib_range + Ir_range + Ibb_range)[cv_range]) ,label="total current")
                        
                        PyPlot.xlabel(L"\eta \ (V)")
                        PyPlot.ylabel(L"I \ (A)")
                        PyPlot.legend(loc="best")
                        PyPlot.grid()
                    end
                end
                
                if num_subplots > 2
                    subplot(num_subplots*100 + 13)
                    plot(time_range,phi_range,label="phi_S (V)")
                    plot(time_range,y0_range,label="y(0)")
                    for (i, idx) in enumerate(surface_species)
                      plot(time_range,surface_species_range[i,:], label=surface_names[i])
                    end
                    PyPlot.xlabel("t (s)")
                    PyPlot.legend(loc="best")
                    PyPlot.grid()
                end
                
                if num_subplots > 3
                    subplot(num_subplots*100 + 14)
                    plot(time_range,Is_range + Ib_range + Ir_range + Ibb_range,label="total I (A)")
                    PyPlot.xlabel("t (s)")
                    PyPlot.legend(loc="best")
                    PyPlot.grid()
                end
                                
                pause(1.0e-10)
            end
            
            # preparing for the next step
            istep+=1
            if state=="relaxation"
                relax_counter += 1
                #println("relaxation ... ",relax_counter/sample*100,"%")
            else
                phi_prev = phi
                phi+=voltrate*dir*tstep
                phi_out = (phi_prev + phi)/2.0
            end
        end
        
        
        
        # the finall plot
        if pyplot || pyplot_finall
            if pyplot_finall
                PyPlot.figure(figsize=(10,8))
            else
                PyPlot.pause(5)
            end
            
            PyPlot.clf()
            #PyPlot.close()
            #PyPlot.figure(figsize=(5,5))
            
            cv_range = (istep_cv_start+1):length(phi_range)


            subplot(221)
            if dlcap
                plot(phi_range[cv_range].-phi0,( Ib_range[cv_range] )/voltrate,"blue", label="bulk")
                #plot(phi_range[cv_range].-phi0,( Ibb_range[cv_range])/voltrate,label="bulk_grad")
                plot(phi_range[cv_range].-phi0,( Is_range[cv_range] )/voltrate,"green", label="surf")
                plot(phi_range[cv_range].-phi0,( Ir_range[cv_range]  )/voltrate,"red", label="reac")
            else
                plot(phi_range[cv_range].-phi0, Ib_range[cv_range] ,"blue", label="bulk")
                #plot(phi_range[cv_range].-phi0, Ibb_range[cv_range] ,label="bulk_grad")
                plot(phi_range[cv_range].-phi0, Is_range[cv_range] ,"green",label="surf")
                plot(phi_range[cv_range].-phi0, Ir_range[cv_range] ,"red",label="reac")
            end
            if dlcap
                PyPlot.xlabel("nu (V)")
                PyPlot.ylabel(L"Capacitance (F/m$^2$)")  
                PyPlot.legend(loc="best")
                PyPlot.xlim(-0.5, 0.5)
                PyPlot.ylim(0, 5)
                PyPlot.grid()
                PyPlot.show()
                PyPlot.pause(5)
                
                PyPlot.clf()
                plot(phi_range[cv_range].-phi0,( (Ib_range+Is_range+Ir_range)[cv_range]  )/voltrate,"brown", label="total")
                PyPlot.xlabel("nu (V)")
                PyPlot.ylabel(L"Capacitance (F/m$^2$)") 
                PyPlot.legend(loc="best")
                PyPlot.xlim(-0.5, 0.5)
                PyPlot.ylim(0, 5)
                PyPlot.grid()
                PyPlot.show()
                #PyPlot.pause(10)
            else
                PyPlot.xlabel(L"\eta \ (V)")
                PyPlot.ylabel(L"I \ (A)")
                PyPlot.legend(loc="best")
                PyPlot.grid()
            end
            
            
            subplot(222)
            if dlcap
                cbl, cs = direct_capacitance(parameters, collect(float(low_bound):0.001:float(upp_bound)))
                plot(collect(float(low_bound):0.001:float(upp_bound)), (cbl+cs), label="tot CG") 
                plot(collect(float(low_bound):0.001:float(upp_bound)), (cbl), label="b CG") 
                plot(collect(float(low_bound):0.001:float(upp_bound)), (cs), label="s CG") 
                # rescaled by voltrate
                plot(phi_range[cv_range].-phi0, ((Is_range + Ib_range + Ir_range + Ibb_range)[cv_range])/voltrate ,label="rescaled total current")
            else
                plot(phi_range[cv_range].-phi0, ((Is_range + Ib_range + Ir_range + Ibb_range)[cv_range]) ,label="total current")
            end
            PyPlot.xlabel(L"\eta \ (V)")
            PyPlot.ylabel(L"I \ (A)")
            PyPlot.legend(loc="best")
            PyPlot.grid()
            
            
            subplot(223)
            #plot(phi_range, Ir_range ,label="spec1")
            plot(time_range,phi_range,label="phi_s (V)")        
            plot(time_range,y0_range,label="y(0)")
            for (i, idx) in enumerate(surface_species)
              plot(time_range,surface_species_range[i,:], label=surface_names[i])
            end
            PyPlot.xlabel("t (s)")
            PyPlot.legend(loc="best")
            PyPlot.grid()
            
            
            subplot(224, facecolor="w")
            height=0.0
            shift=0.0
            swtch=false
            for name in fieldnames(typeof(parameters))
                if (string(name) == "A0" || swtch)
                    swtch = true
                    value = @sprintf("%.6g", parse(Float64,string(getfield(parameters,name))))
                    linestring = @sprintf("%s: %s", name, value)
                    PyPlot.text(0.01+shift, 0.95+height, linestring, fontproperties="monospace")
                    height+=-0.05
                    if string(name) == "e0" 
                        shift+=0.5
                        height=0.0
                    end
                    if string(name) == "A"
                        PyPlot.text(0.01+shift, 0.95+height, " ", fontproperties="monospace")
                        height+=-0.05
                    end
                end
            end
            parn = ["verbose" ,"pyplot", "width", "voltammetry", "voltrate", "low_bound", "upp_bound", "sample", "phi0"]
            parv =[verbose ,pyplot, width, voltammetry, voltrate, low_bound, upp_bound, sample, @sprintf("%.6g",phi0)]
            for ii in 1:length(parn)
                    linestring=string(parn[ii],": ",parv[ii])
                    PyPlot.text(0.01+shift, 0.95+height, linestring, fontproperties="monospace")
                    height+=-0.05
            end
        end


        
        if save_files
            out_name=string(
            "A0",@sprintf("%.0f",prms_in[1]),
            "_R0",@sprintf("%.0f",prms_in[2]),
            "_GA",@sprintf("%.0f",prms_in[3]),
            "_GR",@sprintf("%.0f",prms_in[4]),
            "_be",@sprintf("%.0f",prms_in[5]),
            "_A",@sprintf("%.0f",prms_in[6]),
            "_vrate",@sprintf("%.2g",voltrate),
            )

            out_data_dir = "./results/CV_data/"
            
            if !ispath(out_data_dir)
                mkpath(out_data_dir)
            end

            CSV.write(string(out_data_dir, out_name,".csv"),out_df)
            
            
            if pyplot
                out_fig_dir = "./results/CV_images/"
            
                if !ispath(out_fig_dir)
                    mkpath(out_fig_dir)
                end
            
                PyPlot.savefig(string(out_fig_dir, out_name,".png"))
            end
        end
        if test
            I1 = integrate(sys, model_symbol.reaction!, U)
            #println(I1)
            return I1[1]
        end
        if out_df_bool
            return out_df
        end
    end
end


end
