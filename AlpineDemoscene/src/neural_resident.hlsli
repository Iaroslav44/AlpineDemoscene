// Geometry is extracted at launch from the pretrained gDNA occupancy field.
// Four strongest predicted skinning influences accompany each generated vertex.
// This small authored rig is a prototype: it is not a learned motion controller
// or a full muscle/cloth simulator. No template mesh or source scan is stored.
StructuredBuffer<float4> NeuralResidentVertices : register(t16);
StructuredBuffer<float4> NeuralHeadVertices : register(t17);
StructuredBuffer<float4> NeuralHeadMotion : register(t18);

float3 NeuralResidentShirtColor(float seed)
{
    return lerp(float3(.045,.085,.105),float3(.09,.11,.085),seed);
}

float NeuralHeadClothingCoverage(float3 source)
{
    // GANHead's neck crop includes the captured shirt collar. Match that
    // generated surface to the body's authored shirt without tinting the face.
    // The lower neckline stays below the chin; it rises at the shoulders.
    float neckline=1.455+.060*smoothstep(.025,.065,abs(source.x));
    return 1.0-smoothstep(neckline-.012,neckline+.012,source.y);
}

float3 NeuralRotateX(float3 p, float a)
{
    float s=sin(a),c=cos(a);
    return float3(p.x,c*p.y-s*p.z,s*p.y+c*p.z);
}

void NeuralBone(uint joint,float3 source,float3 sourceNormal,float time,float phase,float walking,
                out float3 p,out float3 n)
{
    p=source;n=sourceNormal;
    bool leftLeg=joint==1||joint==4||joint==7||joint==10;
    bool rightLeg=joint==2||joint==5||joint==8||joint==11;
    // Clavicle joints13/14 belong to the torso. Rotating those with the upper
    // arms pulls the collar into spikes instead of lowering the shoulder chain.
    bool leftArm=joint==16||joint==18||joint==20||joint==22;
    bool rightArm=joint==17||joint==19||joint==21||joint==23;
    float gait=time*(TAU*80.0/128.0)+phase;
    if(leftLeg||rightLeg)
    {
        float side=leftLeg?1.0:-1.0;
        float3 hip=float3(side*.105,.91,0);
        // Undo gDNA's spread-leg canonical pose before the walking swing.
        p=hip+RotateZ(p-hip,-side*PI/6.0);
        n=RotateZ(n,-side*PI/6.0);
        float swing=sin(gait+(leftLeg?0:PI))*.22*walking;
        bool lower=joint==4||joint==5||joint==7||joint==8||joint==10||joint==11;
        if(lower)
        {
            float knee=-max(0.0,-sin(gait+(leftLeg?0:PI)))*.40*walking;
            float3 pivot=float3(side*.105,.50,.015);
            p=pivot+NeuralRotateX(p-pivot,knee);n=NeuralRotateX(n,knee);
        }
        p=hip+NeuralRotateX(p-hip,swing);n=NeuralRotateX(n,swing);
    }
    else if(leftArm||rightArm)
    {
        float side=leftArm?1.0:-1.0;
        float3 shoulder=float3(side*.18,1.39,0);
        float down=-side*1.30;
        p=shoulder+RotateZ(p-shoulder,down);n=RotateZ(n,down);
        float swing=-side*sin(gait)*.18*walking;
        p=shoulder+NeuralRotateX(p-shoulder,swing);n=NeuralRotateX(n,swing);
    }
    else if(joint==12||joint==15)
    {
        float yaw=.12*sin(time*(TAU*6.0/128.0)+phase),pitch=.025*sin(time*(TAU*12.0/128.0)+phase);
        float3 neck=float3(0,1.48,0);
        p=neck+RotateY(NeuralRotateX(p-neck,pitch),yaw);
        n=RotateY(NeuralRotateX(n,pitch),yaw);
    }
    float breathing=.0025*sin(time*(TAU*29.0/128.0)+phase);
    p.y+=breathing*smoothstep(.85,1.45,source.y);
}

Geometry NeuralPersonGeometry(uint vertex,uint id)
{
    Geometry g=(Geometry)0;
    float3 source=NeuralResidentVertices[vertex*4].xyz;
    float3 sourceNormal=NeuralResidentVertices[vertex*4+1].xyz;
    uint4 joints=asuint(NeuralResidentVertices[vertex*4+2]);
    float4 weights=NeuralResidentVertices[vertex*4+3];
    float2 velocity=PeopleVelocity(id,G.z);
    float speed=length(velocity),walking=saturate(speed*1.8);
    float3 p=0,n=0;
    [unroll]for(uint k=0;k<4;++k)
    {
        float3 posedPosition,normal;
        NeuralBone(joints[k],source,sourceNormal,G.z,id*1.37,walking,posedPosition,normal);
        p+=weights[k]*posedPosition;n+=weights[k]*normal;
    }
    float3 forward=normalize(float3(velocity.x,0,velocity.y)+float3(.0001,0,.0001));
    float3 right=float3(forward.z,0,-forward.x);
    float scale=PeopleScale(id);
    g.local=source;g.uv=source.xy;
    g.p=PeopleRoot(id,G.z)+(right*p.x+float3(0,p.y,0)+forward*p.z)*scale;
    g.n=normalize(right*n.x+float3(0,n.y,0)+forward*n.z);
    g.seed=Hash21(float2(id,953));g.material=50;g.moving=1;
    return g;
}

Geometry NeuralHeadGeometry(uint vertex,uint id)
{
    Geometry g=(Geometry)0;
    float3 local=NeuralHeadVertices[vertex*9].xyz;
    float3 normal=NeuralHeadVertices[vertex*9+1].xyz;
    uint count=max(Batch.z,1u);
    float frame=frac(G.z/128.0+id*.137)*count;
    uint first=(uint)floor(frame),second=(first+1)%count;
    // Two float4 records per captured-control frame: expression coefficients
    // and relative jaw pose. The latter is retained for future full jaw LBS.
    float4 expression=lerp(NeuralHeadMotion[first*2],NeuralHeadMotion[second*2],frac(frame));
    [unroll]for(uint k=0;k<4;++k)local+=NeuralHeadVertices[vertex*9+5+k].xyz*expression[k];
    float3 source=local+float3(0,1.42,0);
    float3 posed,posedNormal;
    NeuralBone(15,source,normal,G.z,id*1.37,0,posed,posedNormal);
    float2 velocity=PeopleVelocity(id,G.z);
    float3 forward=normalize(float3(velocity.x,0,velocity.y)+float3(.0001,0,.0001));
    float3 right=float3(forward.z,0,-forward.x);
    g.p=PeopleRoot(id,G.z)+(right*posed.x+float3(0,posed.y,0)+forward*posed.z)*PeopleScale(id);
    g.n=normalize(right*posedNormal.x+float3(0,posedNormal.y,0)+forward*posedNormal.z);
    g.local=source;g.uv=local.xy;g.material=51;g.seed=Hash21(float2(id,953));g.moving=1;
    g.learnedColor=NeuralHeadVertices[vertex*9+4].rgb;
    return g;
}
