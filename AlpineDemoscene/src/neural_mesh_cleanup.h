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
