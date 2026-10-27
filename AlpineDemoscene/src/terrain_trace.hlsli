#ifndef ALPINE_TERRAIN_TRACE
#define ALPINE_TERRAIN_TRACE
Texture2D<float> TerrainMaxHeight : register(t14);

// A bilinear patch evaluated along a straight ray is a quadratic. Solve its
// first root inside this cell, including rays that enter and leave above a
// narrow ridge. This avoids the missed crossings of a fixed-step height march.
float IntersectTerrainCell(float3 p,float3 rd,int2 cell,float span)
{
    int2 q=min(cell+1,int2(4095,4095));
    float h00=ProceduralHeight.Load(int3(cell,0));
    float h10=ProceduralHeight.Load(int3(q.x,cell.y,0));
    float h01=ProceduralHeight.Load(int3(cell.x,q.y,0));
    float h11=ProceduralHeight.Load(int3(q,0));
    float2 f=(p.xz-float2(-6000,-1500))/TERRAIN_TEXEL-float2(cell);
    float2 v=rd.xz/TERRAIN_TEXEL;
    float hx=h10-h00,hz=h01-h00,hxz=h11-h10-h01+h00;
    float a=-hxz*v.x*v.y;
    float b=rd.y-hx*v.x-hz*v.y-hxz*(f.x*v.y+f.y*v.x);
    float c=p.y-(h00+hx*f.x+hz*f.y+hxz*f.x*f.y);
    if(c<=.0005)return 0.0;
    float root=1e20;
    if(abs(a)<1e-8)
    {
        if(b<-.0000001)root=-c/b;
    }
    else
    {
        float disc=b*b-4*a*c;
        if(disc>=0)
        {
            // Stable quadratic formula: the second root follows from their
            // product, avoiding catastrophic cancellation near a shallow hit.
            float s=sqrt(disc),qv=-.5*(b+(b<0?-s:s));
            float r0=qv/a,r1=abs(qv)>1e-12?c/qv:1e20;
            if(r0>=0)root=r0;
            if(r1>=0)root=min(root,r1);
        }
    }
    // An out-of-cell root belongs to a different bilinear patch. Clamping it
    // to this boundary invents a surface when neighbouring slopes disagree.
    return root<=span?root:-1.0;
}

float TraceTerrain(float3 ro,float3 rd,float maxT)
{
    const float2 worldMin=float2(-6000,-1500),worldMax=float2(6000,10500);
    float2 safe=lerp(-1.0,1.0,step(0.0,rd.xz))*max(abs(rd.xz),1e-8);
    float2 ta=(worldMin-ro.xz)/safe,tb=(worldMax-ro.xz)/safe;
    float2 entry=min(ta,tb),leave=max(ta,tb);
    float t=max(.025,max(entry.x,entry.y));
    float end=min(maxT,min(leave.x,leave.y));
    if(t>=end)return maxT+1.0;
    int level=10;
    // A ray crosses at most 2*4096 base cells. Each advancing iteration raises
    // the level by at most one, so descents cost at most another such count.
    // A small fixed budget silently dropped long grazing rays under loose
    // bounds. This grid-derived bound preserves those rays while ordinary
    // rays still leave the loop as soon as they hit or exit the domain.
    [loop]for(int iteration=0;iteration<16416;++iteration)
    {
        if(t>=end)return maxT+1.0;
        float3 p=ro+rd*t;
        float scale=exp2((float)level);
        uint size=max(1u,4096u>>level);
        float2 grid=(p.xz-worldMin)/TERRAIN_TEXEL;
        // Evaluate the actual containing cell. A fixed directional bias could
        // select a low neighbouring bound before leaving the current patch.
        float2 gridCell=grid/scale,whole=floor(gridCell);
        int2 before=int2(rd.x<0&&gridCell.x==whole.x?1:0,rd.z<0&&gridCell.y==whole.y?1:0);
        int2 cell=clamp(int2(whole)-before,int2(0,0),int2(size-1,size-1));
        float2 edge=worldMin+(float2(cell)+step(0.0,rd.xz))*scale*TERRAIN_TEXEL;
        edge=clamp(edge,worldMin,worldMax);
        float2 delta=(edge-p.xz)/safe;
        delta=lerp(delta,float2(1e20,1e20),step(abs(rd.xz),1e-8));
        float span=max(.0001,min(min(delta.x,delta.y),end-t));
        float maximum=TerrainMaxHeight.Load(int3(cell,level));
        float minimumRayY=min(p.y,p.y+rd.y*span);
        if(minimumRayY>maximum)
        {
            // Move one representable float beyond the boundary. A constant
            // .0002 increment rounds to zero beyond8192m and can stall.
            t=asfloat(asuint(t+span)+1u);level=min(level+1,12);continue;
        }
        if(level>0){--level;continue;}
        float hit=IntersectTerrainCell(p,rd,cell,span);
        if(hit>=0)return t+hit;
        t=asfloat(asuint(t+span)+1u);level=1;
    }
    // Exhaustion is a miss, never an invented surface. The diagnostic probe
    // compares this traversal with dense reference rays before release.
    return maxT+1.0;
}
#endif
