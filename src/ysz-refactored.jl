"""
YSZ example cloned from iliq.jl of the TwoPointFluxFVM package.
"""

using Printf
using TwoPointFluxFVM
using PyPlot


mutable struct YSZParameters <:FVMParameters
    number_of_species::Int64
    chi::Float64    # dielectric parameter [1]
    T::Float64      # Temperature [K]
    x_frac::Float64 # Y2O3 mol mixing, x [%] 
    vL::Float64     # volume of one FCC cell, v_L [m^3]
    nu::Float64    # ratio of immobile ions, \nu [1]
    ML::Float64   # averaged molar mass [kg]
    zL::Float64   # average charge number [1]
    DD::Float64   # diffusion coefficient [m^2/s]
    y0::Float64   # electroneutral value
    
    e0::Float64  
    eps0::Float64
    kB::Float64  
    N_A::Float64 
    zA::Float64  
    mO::Float64  
    mZr::Float64 
    mY::Float64 
    m_par::Float64
    
    YSZParameters()= YSZParameters( new())
end
    
function YSZParameters(this)
    this.number_of_species=2
    this.chi=1.e1
    this.T=1073
    this.x_frac=0.1
    this.vL=3.35e-29
    this.nu=0.1
    this.DD=1.0e-9
    this.e0   = 1.602176565e-19  #  [C]
    this.eps0 = 8.85418781762e-12 #  [As/(Vm)] 
    this.kB   = 1.3806488e-23  #  [J/K]  
    this.N_A   = 6.02214129e23  #  [#/mol]
    this.zA  = -2;
    this.mO  = 16/1000/this.N_A  #[kg/#]
    this.mZr = 91.22/1000/this.N_A #  [kg/#]
    this.mY  = 88.91/1000/this.N_A #  [kg/#]
    this.m_par = 2
    this.zL  = 4*(1-this.x_frac)/(1+this.x_frac) + 3*2*this.x_frac/(1+this.x_frac) - 2*this.m_par*this.nu
    this.y0  = -this.zL/(this.zA*this.m_par*(1-this.nu))
    this.ML  = (1-this.x_frac)/(1+this.x_frac)*this.mZr + 2*this.x_frac/(1+this.x_frac)*this.mY + this.m_par*this.nu*this.mO
    #       this.ML=1.77e-25
    # this.zL=1.8182
    # this.y0=0.9
    return this
end



function printfields(this)
    for name in fieldnames(typeof(this))
        @printf("%8s = ",name)
        println(getfield(this,name))
    end
end
    



const iphi=1
const iy=2


function run_ysz(;n=100,pyplot=false,flux=1, width=1.0)

    h=width/convert(Float64,n)
    geom=FVMGraph(collect(0:h:width))
    
    parameters=YSZParameters()
    printfields(parameters)


    function flux1!(this::YSZParameters,f,uk,ul)
        f[iphi]=this.eps0*(1+this.chi)*(uk[iphi]-ul[iphi])
        muk=-log(1-uk[iy])
        mul=-log(1-ul[iy])
        bp,bm=fbernoulli_pm(2*(uk[iphi]-ul[iphi])+(muk-mul))
        f[iy]=bm*uk[iy]-bp*ul[iy]
    end

    function flux2!(this::YSZParameters,f,uk,ul)
        f[iphi]=this.eps0*(1+this.chi)*(uk[iphi]-ul[iphi])
        muk=-log(1-uk[iy])
        mul=-log(1-ul[iy])
        bp,bm=fbernoulli_pm(2*(1.0+0.5*(uk[iy]+ul[iy]))*(uk[iphi]-ul[iphi])+(muk-mul))
        f[iy]=bm*uk[iy]-bp*ul[iy]
    end

    
    function flux3!(this::YSZParameters,f,uk,ul)
        f[iphi]=this.eps0*(1+this.chi)*(uk[iphi]-ul[iphi])
        muk=-log(1-uk[iy])
        mul=-log(1-ul[iy])
        bp,bm=fbernoulli_pm(
            1.0/this.ML/this.kB*(-this.zA*this.e0/this.T*(ul[iphi]-uk[iphi])*(
       this.ML + this.mO*this.m_par*(1-.0*this.nu)*0.5*(uk[iy]+ul[iy])
             )
      +this.kB*(this.mO*(1-this.m_par*this.nu) + this.ML)*(muk-mul)
      )*this.mO/this.DD/this.kB/this.vL*this.m_par*(1.0-this.nu)*this.mO
    )
        #print(bm,"  ", bp)
        f[iy]=this.DD*this.kB/this.mO*(bm*uk[iy]-bp*ul[iy])*this.vL/this.m_par/(1.0-this.nu)/this.mO
    end 



    function storage!(this::FVMParameters, f,u)
        f[iphi]=0
        f[iy]=u[iy]
    end

    function reaction!(this::FVMParameters, f,u)
        f[iphi]=(this.e0/this.vL)*(this.zA*u[iy]*this.m_par*(1-this.nu) + this.zL)
        f[iy]=0
    end

    if flux==1 
        fluxx=flux1!
    elseif flux==2 
        fluxx=flux2!
    elseif flux==3 
        fluxx=flux3!
    end

    sys=TwoPointFluxFVMSystem(geom,parameters=parameters, 
                              storage=storage!, 
                              flux=fluxx, 
                              reaction=reaction!
                              )
    sys.boundary_values[iphi,1]=1.0
    sys.boundary_values[iphi,2]=0.0e-3
    
    sys.boundary_factors[iphi,1]=Dirichlet
    sys.boundary_factors[iphi,2]=Dirichlet

    sys.boundary_values[iy,2]=parameters.y0
    sys.boundary_factors[iy,2]=Dirichlet
    
    inival=unknowns(sys)
    for inode=1:size(inival,2)
        inival[iphi,inode]=0.0e-3
        inival[iy,inode]=parameters.y0
    end
    #parameters.eps=1.0e-2
    #parameters.a=5
    control=FVMNewtonControl()
    control.verbose=true
    t=0.0
    tend=1.0
    tstep=1.0e-10
    while t<tend
        t=t+tstep
        U=solve(sys,inival,control=control,tstep=tstep)
        for i=1:size(inival,2)
            inival[iphi,i]=U[iphi,i]
            inival[iy,i]=U[iy,i]
        end
        @printf("time=%g\n",t)
        if pyplot
            PyPlot.clf()
            PyPlot.plot(geom.Nodes[1,:],U[iphi,:], label="Potential", color="g")
            PyPlot.plot(geom.Nodes[1,:],U[iy,:], label="y", color="b")
            PyPlot.grid()
            PyPlot.legend(loc="upper right")
            PyPlot.pause(1.0e-10)
        end
        tstep*=1.2
    end
end



if !isinteractive()
    @time run_ysz(n=100,pyplot=true)
    waitforbuttonpress()
end