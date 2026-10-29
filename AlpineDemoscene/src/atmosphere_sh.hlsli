#ifndef ALPINE_ATMOSPHERE_SH
#define ALPINE_ATMOSPHERE_SH
// Orthonormal real SH, z-polar convention. Used identically for projection
// and reconstruction; world Y remains vertical. Coefficients contain E/PI.
float AtmosphereSHBasis(uint k,float3 d)
{
    if(k==0)return .2820947918;
    if(k==1)return .4886025119*d.y;
    if(k==2)return .4886025119*d.z;
    if(k==3)return .4886025119*d.x;
    if(k==4)return 1.0925484306*d.x*d.y;
    if(k==5)return 1.0925484306*d.y*d.z;
    if(k==6)return .3153915653*(3*d.z*d.z-1);
    if(k==7)return 1.0925484306*d.x*d.z;
    return .5462742153*(d.x*d.x-d.y*d.y);
}
#endif
