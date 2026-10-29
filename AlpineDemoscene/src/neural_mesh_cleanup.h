// Remove disconnected occupancy islands before computing the actor's scale.
// A tiny floating triangle must not determine head height / skeletal pivots.
// Included after Mesh inside neural_avatar_runtime.cpp's private namespace.
// This changes only mesh extraction, never pretrained network parameters.
static uint32_t NeuralComponentRoot(uint32_t* parent,uint32_t id)
{
    while(parent[id]!=id){parent[id]=parent[parent[id]];id=parent[id];}
    return id;
}

static bool KeepLargestSurface(Mesh& mesh,int(*pump)())
{
    if(!mesh.vertexCount||!mesh.indexCount)return false;
    const uint32_t count=mesh.vertexCount;
    uint32_t* parent=Allocate<uint32_t>(count);
    uint32_t* sizes=Allocate<uint32_t>(count);
    uint32_t* remap=Allocate<uint32_t>(count);
    if(!parent||!sizes||!remap){Free(parent);Free(sizes);Free(remap);return false;}
    for(uint32_t i=0;i<count;++i){parent[i]=i;sizes[i]=1;}
    bool ok=true;
    for(uint32_t i=0;i<mesh.indexCount;i+=3)
    {
        if((i&4095)==0&&pump&&!pump()){ok=false;break;}
        for(uint32_t edge=1;edge<3;++edge)
        {
            uint32_t a=NeuralComponentRoot(parent,mesh.indices[i]);
            uint32_t b=NeuralComponentRoot(parent,mesh.indices[i+edge]);
            if(a==b)continue;
            if(sizes[a]<sizes[b]){uint32_t tmp=a;a=b;b=tmp;}
            parent[b]=a;sizes[a]+=sizes[b];
        }
    }
    uint32_t largest=0;
    if(ok)
    {
        for(uint32_t i=0;i<count;++i)
            if(parent[i]==i&&sizes[i]>sizes[largest])largest=i;
        uint32_t kept=0;
        for(uint32_t i=0;i<count;++i)
        {
            if(NeuralComponentRoot(parent,i)!=largest){remap[i]=0xffffffffu;continue;}
            remap[i]=kept;
            mesh.positions[kept]=mesh.positions[i];
            mesh.normals[kept]=mesh.normals[i];
            ++kept;
        }
        uint32_t indices=0;
        for(uint32_t i=0;i<mesh.indexCount;i+=3)
        {
            uint32_t a=remap[mesh.indices[i]],b=remap[mesh.indices[i+1]],c=remap[mesh.indices[i+2]];
            if(a==0xffffffffu||b==0xffffffffu||c==0xffffffffu)continue;
            mesh.indices[indices++]=a;mesh.indices[indices++]=b;mesh.indices[indices++]=c;
        }
        mesh.vertexCount=kept;mesh.indexCount=indices;
        ok=kept>0&&indices>0;
    }
    Free(parent);Free(sizes);Free(remap);
    return ok;
}

// Mesh-local adjacency, never proximity welding: nearby fingers, lips and
// opposite sides of a thin surface must not exchange positions or skin weights.
struct NeuralMeshTopology
{
    uint32_t* offsets=0;uint32_t* neighbours=0;unsigned char* boundary=0;
    ~NeuralMeshTopology(){Free(offsets);Free(neighbours);Free(boundary);}
    bool Build(const Mesh& mesh,int(*pump)())
    {
        uint32_t count=mesh.vertexCount;
        offsets=Allocate<uint32_t>(count+1);neighbours=Allocate<uint32_t>(mesh.indexCount*2);boundary=Allocate<unsigned char>(count);
        uint32_t* cursor=Allocate<uint32_t>(count);
        if(!offsets||!neighbours||!boundary||!cursor){Free(cursor);return false;}
        for(uint32_t i=0;i<mesh.indexCount;++i)offsets[mesh.indices[i]+1]+=2;
        for(uint32_t i=1;i<=count;++i)offsets[i]+=offsets[i-1];
        Copy(cursor,offsets,count*sizeof(uint32_t));
        for(uint32_t i=0;i<mesh.indexCount;i+=3)for(uint32_t j=0;j<3;++j)
        {
            uint32_t v=mesh.indices[i+j];
            neighbours[cursor[v]++]=mesh.indices[i+(j+1)%3];
            neighbours[cursor[v]++]=mesh.indices[i+(j+2)%3];
        }
        Free(cursor);uint32_t start=0,written=0;
        for(uint32_t i=0;i<count;++i)
        {
            if((i&2047)==0&&pump&&!pump())return false;
            uint32_t end=offsets[i+1];
            // Small one-ring lists; sorting also gives deterministic summation.
            for(uint32_t j=start+1;j<end;++j){uint32_t v=neighbours[j],k=j;while(k>start&&neighbours[k-1]>v){neighbours[k]=neighbours[k-1];--k;}neighbours[k]=v;}
            offsets[i]=written;
            for(uint32_t j=start;j<end;)
            {
                uint32_t v=neighbours[j],next=j+1;while(next<end&&neighbours[next]==v)++next;
                if(v!=i){neighbours[written++]=v;if(next-j!=2)boundary[i]=1;}
                j=next;
            }
            start=end;
        }
        offsets[count]=written;return true;
    }
};

static bool NeuralAreaNormals(Mesh& mesh,int(*pump)())
{
    Zero(mesh.normals,mesh.vertexCount*sizeof(F3));
    for(uint32_t i=0;i<mesh.indexCount;i+=3)
    {
        if((i&4095)==0&&pump&&!pump())return false;
        uint32_t a=mesh.indices[i],b=mesh.indices[i+1],c=mesh.indices[i+2];
        F3 n=Cross(Sub(mesh.positions[b],mesh.positions[a]),Sub(mesh.positions[c],mesh.positions[a]));
        mesh.normals[a]=Add(mesh.normals[a],n);mesh.normals[b]=Add(mesh.normals[b],n);mesh.normals[c]=Add(mesh.normals[c],n);
    }
    for(uint32_t i=0;i<mesh.vertexCount;++i)mesh.normals[i]=Normal(mesh.normals[i]);
    return true;
}

static float NeuralNeighbourWeight(F3 a,F3 b,F3 na,F3 nb,float grid)
{
    float agreement=Maximum(0,Dot(na,nb));agreement*=agreement;agreement*=agreement;
    return (.03f+.97f*agreement)/(Root(Dot(Sub(a,b),Sub(a,b)))+grid*.15f);
}

static bool RefineNeuralGeometry(Mesh& mesh,bool head,int(*pump)())
{
    NeuralMeshTopology topology;if(!topology.Build(mesh,pump)||!NeuralAreaNormals(mesh,pump))return false;
    uint32_t count=mesh.vertexCount;F3* anchor=Allocate<F3>(count);F3* guide=Allocate<F3>(count);F3* next=Allocate<F3>(count);
    unsigned char* freeze=Allocate<unsigned char>(count);
    if(!anchor||!guide||!next||!freeze){Free(anchor);Free(guide);Free(next);Free(freeze);return false;}
    Copy(anchor,mesh.positions,count*sizeof(F3));Copy(guide,mesh.normals,count*sizeof(F3));
    float grid=Minimum(mesh.step.x,Minimum(mesh.step.y,mesh.step.z));
    float limit=grid*(head?.32f:.90f);bool ok=true;
    // Paired positive/negative Laplacians suppress tessellation-scale noise
    // without the systematic shrinkage of repeated ordinary Laplacian steps.
    // Fixed bilateral guides preserve creases; a source-relative displacement
    // limit and pinned open boundaries protect thin parts and the neck crop.
    for(uint32_t pass=0;pass<(head?4u:12u)&&ok;++pass)
    {
        float coefficient=(pass&1)?-.53f:.50f;
        for(uint32_t i=0;i<count;++i)
        {
            if((i&2047)==0&&pump&&!pump()){ok=false;break;}
            F3 p=mesh.positions[i];F3 sum={};float total=0;
            for(uint32_t k=topology.offsets[i];k<topology.offsets[i+1];++k)
            {
                uint32_t j=topology.neighbours[k];
                float w=NeuralNeighbourWeight(anchor[i],anchor[j],guide[i],guide[j],grid);
                sum=Add(sum,Mul(Sub(mesh.positions[j],p),w));total+=w;
            }
            F3 candidate=Add(p,Mul(sum,coefficient/Maximum(total,1e-10f)));
            F3 delta=Sub(candidate,anchor[i]);float distance=Root(Dot(delta,delta));
            if(distance>limit)candidate=Add(anchor[i],Mul(delta,limit/distance));
            next[i]=topology.boundary[i]?anchor[i]:candidate;
        }
        // Skinny tetrahedral triangles can invert even under a tiny bounded
        // move. Locally reject the offending updates; do not silently trade
        // lower roughness for folded or zero-area geometry.
        bool safe=false;
        for(uint32_t repair=0;repair<12&&ok;++repair)
        {
            Zero(freeze,count);uint32_t bad=0;
            for(uint32_t i=0;i<mesh.indexCount;i+=3)
            {
                uint32_t a=mesh.indices[i],b=mesh.indices[i+1],c=mesh.indices[i+2];
                F3 oldNormal=Cross(Sub(anchor[b],anchor[a]),Sub(anchor[c],anchor[a]));float magnitude=Dot(oldNormal,oldNormal);
                if(magnitude<1e-20f)continue;
                F3 newNormal=Cross(Sub(next[b],next[a]),Sub(next[c],next[a]));
                if(Dot(oldNormal,newNormal)<magnitude*.01f){freeze[a]=freeze[b]=freeze[c]=1;++bad;}
            }
            if(!bad){safe=true;break;}
            if(pump&&!pump()){ok=false;break;}
            for(uint32_t i=0;i<count;++i)if(freeze[i])next[i]=mesh.positions[i];
        }
        if(ok&&safe)Copy(mesh.positions,next,count*sizeof(F3));
    }
    Free(anchor);Free(guide);Free(next);Free(freeze);
    return ok&&NeuralAreaNormals(mesh,pump);
}

static bool RefineNeuralAttributes(Mesh& mesh,float* attributes,bool head,int(*pump)())
{
    NeuralMeshTopology topology;if(!topology.Build(mesh,pump))return false;
    uint32_t count=mesh.vertexCount,stride=head?32:12,jointCount=head?5:24;
    F3* detail=Allocate<F3>(count);F3* filtered=Allocate<F3>(count);
    float* weights=Allocate<float>(count*jointCount);float* nextWeights=Allocate<float>(count*jointCount);
    if(!detail||!filtered||!weights||!nextWeights){Free(detail);Free(filtered);Free(weights);Free(nextWeights);return false;}
    bool ok=true;float grid=Minimum(mesh.step.x,Minimum(mesh.step.y,mesh.step.z));
    for(uint32_t i=0;i<count;++i)
    {
        float* a=attributes+i*stride;F3 n={a[0],a[1],a[2]};n=Normal(n);
        if(Dot(n,mesh.normals[i])<0)n=Mul(n,-1);detail[i]=n;
        for(uint32_t j=0;j<4;++j)
        {
            if(!Finite(a[4+j])||a[4+j]<0||a[4+j]>=jointCount||!Finite(a[8+j])||a[8+j]<0){ok=false;break;}
            weights[i*jointCount+(uint32_t)a[4+j]]+=a[8+j];
        }
    }
    // Keep only the portion of learned detail supported by the extracted mesh
    // bandwidth. Topological filtering avoids importing a neighbour across a
    // narrow gap, and the final normal cone prevents flipped shading lobes.
    for(uint32_t pass=0;pass<2&&ok;++pass)
    {
        for(uint32_t i=0;i<count;++i)
        {
            if((i&1023)==0&&pump&&!pump()){ok=false;break;}
            F3 sum={};float total=0;float neighbourWeights[24]={};
            for(uint32_t k=topology.offsets[i];k<topology.offsets[i+1];++k)
            {
                uint32_t j=topology.neighbours[k];
                float w=NeuralNeighbourWeight(mesh.positions[i],mesh.positions[j],mesh.normals[i],mesh.normals[j],grid);
                sum=Add(sum,Mul(detail[j],w));total+=w;
                for(uint32_t joint=0;joint<jointCount;++joint)neighbourWeights[joint]+=weights[j*jointCount+joint]*w;
            }
            float inv=1/Maximum(total,1e-10f);
            filtered[i]=Normal(Add(Mul(detail[i],.55f),Mul(sum,.45f*inv)));
            for(uint32_t joint=0;joint<jointCount;++joint)
                nextWeights[i*jointCount+joint]=weights[i*jointCount+joint]*.75f+neighbourWeights[joint]*(.25f*inv);
        }
        if(ok){Copy(detail,filtered,count*sizeof(F3));Copy(weights,nextWeights,count*jointCount*sizeof(float));}
    }
    for(uint32_t i=0;i<count&&ok;++i)
    {
        F3 base=mesh.normals[i],n=detail[i];float projection=Dot(n,base);
        F3 tangent=Sub(n,Mul(base,projection));float length=Root(Dot(tangent,tangent));
        // At most 20 degrees body / 30 degrees head of residual detail.
        float detailAmount=head?.55f:.32f,cone=head?.57735027f:.36397023f;
        tangent=Mul(tangent,detailAmount);length*=detailAmount;
        if(length>cone)tangent=Mul(tangent,cone/length);
        n=Normal(Add(base,tangent));float* a=attributes+i*stride;a[0]=n.x;a[1]=n.y;a[2]=n.z;
        float* w=weights+i*jointCount;float sum=0;
        for(uint32_t k=0;k<4;++k)
        {
            uint32_t best=0;for(uint32_t j=1;j<jointCount;++j)if(w[j]>w[best])best=j;
            a[4+k]=(float)best;a[8+k]=w[best];sum+=w[best];w[best]=-1;
        }
        for(uint32_t k=0;k<4;++k)a[8+k]/=Maximum(sum,1e-10f);
    }
    Free(detail);Free(filtered);Free(weights);Free(nextWeights);return ok;
}

static bool NeuralBindLandmarks(const Mesh& mesh,const float* attributes,float scale,float minimumY,float* output,int(*pump)())
{
    const uint32_t parents[24]={0,0,0,0,1,2,3,4,5,6,7,8,9,9,9,12,13,14,16,17,18,19,20,21};
    F3 sums[24]={};float mass[24]={};Zero(output,32*16);
    for(uint32_t i=0;i<mesh.vertexCount;++i)
    {
        if((i&2047)==0&&pump&&!pump())return false;
        const float* a=attributes+i*12;float weights[24]={};
        for(uint32_t k=0;k<4;++k)weights[(uint32_t)a[4+k]]+=a[8+k];
        F3 p=mesh.positions[i];p={p.x*scale,(p.y-minimumY)*scale,p.z*scale};
        for(uint32_t j=0;j<24;++j)
        {
            float w=j?weights[j]*weights[parents[j]]:weights[0];w*=w;
            sums[j]=Add(sums[j],Mul(p,w));mass[j]+=w;
        }
    }
    for(uint32_t j=0;j<24;++j)
    {
        // No template or skeleton asset: every landmark must be supported by
        // the generated skin field. A missing required limb is a failed model.
        if(mass[j]<1e-8f)return false;
        F3 p=Mul(sums[j],1/mass[j]);output[j*4]=p.x;output[j*4+1]=p.y;output[j*4+2]=p.z;output[j*4+3]=mass[j];
    }
    for(uint32_t side=0;side<2;++side)
    {
        uint32_t hip=side?2:1,ankle=side?8:7,toe=side?11:10;float sign=side?-1.f:1.f;
        F3 h={output[hip*4],output[hip*4+1],output[hip*4+2]};
        F3 a={output[ankle*4],output[ankle*4+1],output[ankle*4+2]};
        float ankleY=h.y-sign*.5f*(a.x-h.x)+.8660254038f*(a.y-h.y),sole=1e20f;
        for(uint32_t i=0;i<mesh.vertexCount;++i)
        {
            const float* attr=attributes+i*12;float influence=0;
            for(uint32_t k=0;k<4;++k)if((uint32_t)attr[4+k]==ankle||(uint32_t)attr[4+k]==toe)influence+=attr[8+k];
            if(influence<.45f)continue;
            F3 p=mesh.positions[i];p={p.x*scale,(p.y-minimumY)*scale,p.z*scale};
            float y=h.y-sign*.5f*(p.x-h.x)+.8660254038f*(p.y-h.y);sole=Minimum(sole,y);
        }
        if(sole>1e10f)return false;
        output[(24+side)*4]=Maximum(.005f,ankleY-sole);
        output[(24+side)*4+1]=sole;
    }
    return true;
}

struct NeuralDistanceNode{double distance;uint32_t vertex;};
static bool NeuralDistanceLess(const NeuralDistanceNode& a,const NeuralDistanceNode& b)
{
    return a.distance<b.distance||(a.distance==b.distance&&a.vertex<b.vertex);
}

static bool FilterNeuralClothingNormals(Mesh& mesh,float* attributes,bool head,int(*pump)())
{
    if(head)return true;
    NeuralMeshTopology topology;if(!topology.Build(mesh,pump))return false;
    uint32_t count=mesh.vertexCount,capacity=topology.offsets[count]+1;
    float* area=Allocate<float>(count);double* distance=Allocate<double>(count);uint32_t* seen=Allocate<uint32_t>(count);
    NeuralDistanceNode* heap=Allocate<NeuralDistanceNode>(capacity);
    if(!area||!distance||!seen||!heap){Free(area);Free(distance);Free(seen);Free(heap);return false;}
    for(uint32_t i=0;i<mesh.indexCount;i+=3)
    {
        uint32_t a=mesh.indices[i],b=mesh.indices[i+1],c=mesh.indices[i+2];
        F3 cross=Cross(Sub(mesh.positions[b],mesh.positions[a]),Sub(mesh.positions[c],mesh.positions[a]));
        float share=Root(Dot(cross,cross))/6;area[a]+=share;area[b]+=share;area[c]+=share;
    }
    float minimumY=1e20f,maximumY=-1e20f;
    for(uint32_t i=0;i<count;++i){minimumY=Minimum(minimumY,mesh.positions[i].y);maximumY=Maximum(maximumY,mesh.positions[i].y);}
    float scale=1.75f/Maximum(maximumY-minimumY,.1f);double radius=.025/(double)scale;bool ok=true;
    for(uint32_t vertex=0;vertex<count&&ok;++vertex)
    {
        if((vertex&31)==0&&pump&&!pump()){ok=false;break;}
        float* attr=attributes+vertex*12;F3 p=mesh.positions[vertex];float foot=0;
        for(uint32_t k=0;k<4;++k){uint32_t j=(uint32_t)attr[4+k];if(j==7||j==8||j==10||j==11)foot+=attr[8+k];}
        if(p.x*scale<=-.68f||p.x*scale>=.68f||(p.y-minimumY)*scale>=1.44f||foot>=.45f)continue;
        uint32_t stamp=vertex+1,queued=1,popped=0;heap[0]={0,vertex};distance[vertex]=0;seen[vertex]=stamp;
        double sx=0,sy=0,sz=0;
        while(queued&&ok)
        {
            NeuralDistanceNode current=heap[0],last=heap[--queued];uint32_t slot=0;
            while(slot*2+1<queued)
            {
                uint32_t child=slot*2+1;if(child+1<queued&&NeuralDistanceLess(heap[child+1],heap[child]))++child;
                if(!NeuralDistanceLess(heap[child],last))break;heap[slot]=heap[child];slot=child;
            }
            if(queued)heap[slot]=last;
            uint32_t id=current.vertex;if(current.distance!=distance[id])continue;
            if((++popped&127)==0&&pump&&!pump()){ok=false;break;}
            double q=current.distance/radius,kernel=Maximum(.1f,Dot(mesh.normals[id],mesh.normals[vertex]));
            kernel=kernel*kernel*(1-q*q)*(1-q*q)*area[id];
            sx+=mesh.normals[id].x*kernel;sy+=mesh.normals[id].y*kernel;sz+=mesh.normals[id].z*kernel;
            for(uint32_t k=topology.offsets[id];k<topology.offsets[id+1];++k)
            {
                uint32_t neighbour=topology.neighbours[k];F3 edge=Sub(mesh.positions[neighbour],mesh.positions[id]);
                double next=current.distance+Root(Dot(edge,edge));
                if(next>radius||(seen[neighbour]==stamp&&next>=distance[neighbour]))continue;
                if(queued==capacity){ok=false;break;}
                seen[neighbour]=stamp;distance[neighbour]=next;NeuralDistanceNode value={next,neighbour};uint32_t pos=queued++;
                while(pos){uint32_t parent=(pos-1)/2;if(!NeuralDistanceLess(value,heap[parent]))break;heap[pos]=heap[parent];pos=parent;}heap[pos]=value;
            }
        }
        if(ok)
        {
            F3 n=Normal({(float)sx,(float)sy,(float)sz});attr[0]=n.x;attr[1]=n.y;attr[2]=n.z;
        }
    }
    Free(area);Free(distance);Free(seen);Free(heap);return ok;
}
