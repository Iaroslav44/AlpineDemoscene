// Independent, development-only double-precision checks of the equations used
// by physics_simulation.hlsl. This is not linked into the MASM runtime.
#include <algorithm>
#include <array>
#include <cmath>
#include <iomanip>
#include <fstream>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>
constexpr double pi=3.14159265358979323846,g=9.81;
struct V {double x,y,z;};
V operator+(V a,V b){return {a.x+b.x,a.y+b.y,a.z+b.z};}
V operator-(V a,V b){return {a.x-b.x,a.y-b.y,a.z-b.z};}
V operator*(V a,double b){return {a.x*b,a.y*b,a.z*b};}
double dot(V a,V b){return a.x*b.x+a.y*b.y+a.z*b.z;}
double length(V a){return std::sqrt(dot(a,a));}
V normalize(V a){return a*(1.0/length(a));}
V cross(V a,V b){return {a.y*b.z-a.z*b.y,a.z*b.x-a.x*b.z,a.x*b.y-a.y*b.x};}
struct Flight{V p,v;double dissipated=0;};
struct Force{V acceleration,lift,drag;};
Force force(V p,V v,double cl=.75,double bank=.12,V wind={0,0,0}){
    v=v-wind;
    V forward=normalize(v),r=normalize(cross({0,1,0},forward)),u=cross(forward,r);
    u=u*std::cos(bank)-r*std::sin(bank);
    double q=.5*1.225*std::exp(-std::max(p.y,0.0)/8500.0)*dot(v,v);
    double cd=.012+cl*cl/(pi*(18.*18./11.)*.82);
    V lift=u*(q*11.*cl),drag=forward*(-q*11.*cd);
    return {(lift+drag)*(1./420.)+V{0,-g,0},lift,drag};
}
Flight flight(double dt,double duration){
    Flight f{{535,1100,2850},{0,-.82,32},0};
    int count=int(std::round(duration/dt));
    for(int i=0;i<count;i++){
        Force a=force(f.p,f.v);V mp=f.p+f.v*(dt*.5),mv=f.v+a.acceleration*(dt*.5);
        Force mid=force(mp,mv);f.p=f.p+mv*dt;f.v=f.v+mid.acceleration*dt;
        f.dissipated+=-dot(mid.drag,mv)*dt;
    }return f;
}
double energy(const Flight& f){return 420.*(g*f.p.y+.5*dot(f.v,f.v));}
V windAt(V p,double t){
    double a=2*pi*t/128.;
    double h0=std::sin(a*3+p.x*.0021+p.z*.0013),h1=std::sin(a*5-p.x*.0012+p.z*.0023),h2=std::sin(a*11+p.x*.004-p.z*.003);
    double thermal=1.6*std::exp(-((p.x+100)*(p.x+100)+(p.z-3000)*(p.z-3000))/(380.*380.))*(.9+.1*std::sin(a*2));
    return {3.2+1.1*h0-.18*h1+.25*h2,.08*h2+thermal,1.2+.25*h0+.75*h1+.18*h2};
}
struct ControlledMetrics{double minSpeed=1e30,maxSpeed=0,maxRadialError=0,minHeight=1e30;};
ControlledMetrics controlledFlight(int id){
    constexpr double dt=1./120.;double radius=560.+id*34.,phase=id*1.55;
    V p{-25+radius*std::cos(phase),1100.+id*45.,2850+radius*std::sin(phase)};
    V v=V{-std::sin(phase)*32.,-.82,std::cos(phase)*32.}+windAt(p,0);
    double bank=std::atan(32.*32./(g*radius)),cl=420*g/(.5*1.225*std::exp(-p.y/8500)*32.*32.*11.*std::cos(bank));
    ControlledMetrics m;
    for(int step=0;step<15360;step++){
        double t=step*dt;V air=v-windAt(p,t);double speed=length(air),horizontal=std::hypot(air.x,air.z);
        double dx=air.x/horizontal,dz=air.z/horizontal,rx=p.x+25,rz=p.z-2850,distance=std::hypot(rx,rz);rx/=distance;rz/=distance;
        double tx=-rz-rx*((distance-radius)/radius)*1.8,tz=rx-rz*((distance-radius)/radius)*1.8,tl=std::hypot(tx,tz);tx/=tl;tz/=tl;
        double error=std::atan2(tx*dz-tz*dx,tx*dx+tz*dz);
        double targetBank=std::clamp(std::atan(speed*speed/(g*radius))-.95*error,-.55,.55);
        bank+=std::clamp((targetBank-bank)/.75,-.55,.55)*dt;
        double load=std::clamp(1.+.085*(-.82-air.y)+.015*(speed-32.),.55,1.45);
        double targetCl=std::clamp(420*g*load/(.5*1.225*std::exp(-p.y/8500)*speed*speed*11.*std::max(std::cos(bank),.6)),.15,1.35);
        cl+=std::clamp((targetCl-cl)/.30,-1.5,1.5)*dt;
        Force a=force(p,v,cl,bank,windAt(p,t));V mp=p+v*(dt*.5),mv=v+a.acceleration*(dt*.5);
        p=p+mv*dt;v=v+force(mp,mv,cl,bank,windAt(mp,t+.5*dt)).acceleration*dt;
        m.minSpeed=std::min(m.minSpeed,speed);m.maxSpeed=std::max(m.maxSpeed,speed);
        m.maxRadialError=std::max(m.maxRadialError,std::abs(distance-radius));m.minHeight=std::min(m.minHeight,p.y);
    }return m;
}
struct Cell {double eta=0,u=0,v=0;};
struct Water {
    static constexpr int n=64;static constexpr double dx=7.0,dz=7.0;
    std::vector<double> depth;std::vector<Cell> state;
    Water(bool pulse):depth(n*n),state(n*n){
        for(int z=0;z<n;z++)for(int x=0;x<n;x++){
            double a=(x-31.5)/29.,b=(z-31.5)/26.;int i=z*n+x;
            depth[i]=(a*a+b*b<1 && !((x-44)*(x-44)+(z-29)*(z-29)<13))?18.:0.;
            if(pulse&&depth[i]>0)state[i].eta=.12*std::exp(-((x-24.)*(x-24.)+(z-32.)*(z-32.))/36.);
        }
    }
    double h(int x,int z)const{return x<0||x>=n||z<0||z>=n?0:depth[z*n+x];}
    Cell at(int x,int z)const{return x<0||x>=n||z<0||z>=n?Cell{}:state[z*n+x];}
    double face(int x,int z,int ax,int az,double dt)const{
        if(std::min(h(x,z),h(x+ax,z+az))<=0)return 0;
        Cell a=at(x,z),b=at(x+ax,z+az);double old=ax?a.u:a.v;
        return (old-dt*g*(b.eta-a.eta)/(ax?dx:dz))/(1.+.018*dt);
    }
    void step(double dt){
        std::vector<Cell> next(n*n);
        for(int z=0;z<n;z++)for(int x=0;x<n;x++){
            int i=z*n+x;if(depth[i]<=0)continue;
            double e=face(x,z,1,0,dt),w=face(x-1,z,1,0,dt);
            double a=face(x,z,0,1,dt),b=face(x,z-1,0,1,dt);
            double qx=std::min(h(x,z),h(x+1,z))*e-std::min(h(x-1,z),h(x,z))*w;
            double qz=std::min(h(x,z),h(x,z+1))*a-std::min(h(x,z-1),h(x,z))*b;
            next[i]={state[i].eta-dt*(qx/dx+qz/dz),e,a};
        }state.swap(next);
    }
    double volume()const{double sum=0;for(auto c:state)sum+=c.eta;return sum*dx*dz;}
    double energy()const{
        double sum=0;for(int z=0;z<n;z++)for(int x=0;x<n;x++){
            Cell c=at(x,z);sum+=g*c.eta*c.eta+std::min(h(x,z),h(x+1,z))*c.u*c.u+std::min(h(x,z),h(x,z+1))*c.v*c.v;
        }return .5*sum*dx*dz;
    }
};
void require(bool pass,const char* reason){if(!pass)throw std::runtime_error(reason);}
void validateGPUCache(const char* path){
    std::ifstream file(path);require(bool(file),"Cannot read GPU flight CSV");
    std::string line;std::getline(file,line);std::array<std::vector<std::array<double,18>>,4> tracks;
    while(std::getline(file,line)){
        std::istringstream row(line);std::string value;std::array<double,18> a{};int column=0;
        while(std::getline(row,value,',')){require(column<18,"Unexpected CSV columns");a[column++]=std::stod(value);}
        require(column==18&&a[0]>=0&&a[0]<4,"Invalid GPU cache row");tracks[int(a[0])].push_back(a);
    }
    double maxAccelerationError=0,maxEnergyResidual=0,maxBasisError=0,maxAirspeedError=0;
    for(const auto& track:tracks){
        require(track.size()==3841,"Unexpected GPU trajectory sample count");
        double work=0;
        auto from=[](const auto& a,int i){return V{a[i],a[i+1],a[i+2]};};
        auto aerodynamic=[&](const auto& a){
            double rho=1.225*std::exp(-std::max(a[3],0.)/8500.),q=.5*rho*a[9]*a[9];
            double cd=.012+a[13]*a[13]/(pi*(18.*18./11.)*.82);
            return from(a,14)*(q*11.*a[13])-from(a,10)*(q*11.*cd);
        };
        auto mechanical=[&](const auto& a){V v=from(a,6);return 420.*(g*a[3]+.5*dot(v,v));};
        for(size_t k=0;k<track.size();k++){
            const auto& a=track[k];V f=from(a,10),u=from(a,14),p=from(a,2),v=from(a,6);
            maxBasisError=std::max({maxBasisError,std::abs(dot(f,u)),std::abs(length(f)-1),std::abs(length(u)-1)});
            maxAirspeedError=std::max(maxAirspeedError,std::abs(length(v-windAt(p,double(k)/30.))-a[9]));
            if(k>0){const auto& b=track[k-1];work+=(dot(aerodynamic(a),v)+dot(aerodynamic(b),from(b,6)))/(2.*30.);}
            if(k>0&&k+1<track.size()){
                V derivative=(from(track[k+1],6)-from(track[k-1],6))*15.;
                V expected=aerodynamic(a)*(1./420.)+V{0,-g,0};
                maxAccelerationError=std::max(maxAccelerationError,length(derivative-expected));
            }
        }
        double residual=std::abs(mechanical(track.back())-mechanical(track.front())-work)/mechanical(track.front());
        maxEnergyResidual=std::max(maxEnergyResidual,residual);
    }
    require(maxBasisError<3e-6,"GPU flight basis is not orthonormal");
    require(maxAirspeedError<.001,"GPU velocity does not match air-relative speed");
    require(maxAccelerationError<.04,"GPU translation does not follow force balance");
    require(maxEnergyResidual<2e-5,"GPU trajectory fails integrated energy/work balance");
    std::cout<<"{\"gpu_cache_validation\":true,\"samples\":15364,\"max_basis_error\":"<<maxBasisError
        <<",\"max_airspeed_error_mps\":"<<maxAirspeedError<<",\"max_acceleration_residual_mps2\":"<<maxAccelerationError
        <<",\"max_relative_energy_work_residual\":"<<maxEnergyResidual<<"}\n";
}
int main(int argc,char** argv){try{
    double maxLiftWork=0,maxDragPower=-1e30;
    for(int i=0;i<1000;i++){
        V v{10.*std::sin(i*.137),-3.+6.*std::sin(i*.39),25.+9.*std::cos(i*.059)};
        Force f=force({0,800.+i,0},v,.15+1.2*(i%137)/137.,.5*std::sin(i*.21));
        maxLiftWork=std::max(maxLiftWork,std::abs(dot(f.lift,v))/(length(f.lift)*length(v)));
        maxDragPower=std::max(maxDragPower,dot(f.drag,v));
    }
    require(maxLiftWork<1e-12,"Lift performs work along relative velocity");
    require(maxDragPower<0,"Drag injects kinetic energy");
    Flight initial{{535,1100,2850},{0,-.82,32},0};
    Flight coarse=flight(1./60.,48),fine=flight(1./120.,48),finer=flight(1./240.,48);
    double coarseError=length(coarse.p-finer.p),fineError=length(fine.p-finer.p);
    double balance=std::abs(energy(initial)-energy(fine)-fine.dissipated)/energy(initial);
    require(energy(fine)<energy(initial),"Glider gains energy without wind or engine");
    require(fineError<.02&&fineError<coarseError*.4,"Midpoint flight timestep convergence failed");
    require(balance<1e-5,"Flight energy/work balance exceeds tolerance");
    double minControlledSpeed=1e30,maxControlledSpeed=0,maxRadialError=0;
    for(int id=0;id<4;id++){
        ControlledMetrics m=controlledFlight(id);
        minControlledSpeed=std::min(minControlledSpeed,m.minSpeed);maxControlledSpeed=std::max(maxControlledSpeed,m.maxSpeed);
        maxRadialError=std::max(maxRadialError,m.maxRadialError);
        require(m.minSpeed>20&&m.maxSpeed<50&&m.maxRadialError<180&&m.minHeight>800,"Closed-loop flight is unstable in reference valley");
    }
    Water rest(false),wave(true);double mass=wave.volume(),initialE=wave.energy(),maxVolumeError=0,maxEta=0;
    for(int step=0;step<1200;step++){
        rest.step(1./60.);wave.step(1./60.);
        maxVolumeError=std::max(maxVolumeError,std::abs(wave.volume()-mass));
        for(auto c:wave.state){require(std::isfinite(c.eta+c.u+c.v),"Non-finite water state");maxEta=std::max(maxEta,std::abs(c.eta));}
    }
    require(rest.energy()==0,"Lake-at-rest state moved");
    require(maxVolumeError<1e-8,"Water fluxes do not conserve perturbation volume");
    require(wave.energy()<initialE*.9,"Water drag did not dissipate energy");
    require(maxEta<.13,"Water perturbation is unstable");
    std::cout<<std::setprecision(12)
      <<"{\"passed\":true,\"force_samples\":1000,\"max_normalized_lift_work\":"<<maxLiftWork
      <<",\"max_drag_power_watts\":"<<maxDragPower<<",\"flight_coarse_position_error_m\":"<<coarseError
      <<",\"flight_fine_position_error_m\":"<<fineError<<",\"flight_relative_energy_residual\":"<<balance
      <<",\"controlled_min_airspeed_mps\":"<<minControlledSpeed<<",\"controlled_max_airspeed_mps\":"<<maxControlledSpeed
      <<",\"controlled_max_radial_error_m\":"<<maxRadialError
      <<",\"water_steps\":1200,\"lake_at_rest_energy\":"<<rest.energy()<<",\"water_max_volume_error_m3\":"<<maxVolumeError
      <<",\"water_initial_energy\":"<<initialE<<",\"water_final_energy\":"<<wave.energy()<<",\"water_max_abs_eta_m\":"<<maxEta<<"}\n";
    if(argc>1)validateGPUCache(argv[1]);
    return 0;
}catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 1;}}
