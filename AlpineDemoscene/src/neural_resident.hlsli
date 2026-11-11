// Geometry is extracted at launch from the pretrained gDNA occupancy field.
// Four strongest predicted skinning influences accompany each generated vertex.
// This small authored rig is a prototype: it is not a learned motion controller
// or a full muscle/cloth simulator. No template mesh or source scan is stored.
StructuredBuffer<float4> NeuralResidentVertices : register(t16);
StructuredBuffer<float4> NeuralHeadVertices : register(t17);
StructuredBuffer<float4> NeuralHeadMotion : register(t18);
StructuredBuffer<float4> NeuralBodyRig : register(t23);

float3 NeuralResidentShirtColor(float seed)
{
    if(seed>=.78)return lerp(float3(.185,.052,.025),float3(.235,.074,.033),saturate((seed-.78)/.22));
    if(seed>=.62)return float3(.205,.120,.026);
    if(seed>=.46)return float3(.026,.060,.035);
    if(seed>=.30)return float3(.132,.026,.038);
    if(seed>=.15)return float3(.042,.072,.112);
    return float3(.024,.044,.088);
}

float NeuralHeadClothingCoverage(float3 source)
{
    // Lower neck tucks cleanly inside the body's 3D stand-collar below 1.445m.
    return 1.0-smoothstep(1.434,1.444,source.y);
}

float NeuralHeadCropCoverage(float3 source)
{
    // The independent head generator includes a broad scanner shoulder/collar crop.
    // Trim the captured T-shirt collar flare around the cylindrical neck column
    // (|x| <= 5.5cm below 1.505m, widening to the full cranium above 1.568m) while
    // preserving the forward chin/jaw ellipsoid and clipping below the stand-collar.
    float bottomClip=source.y-1.436;
    float headBlend=smoothstep(1.505,1.568,source.y);
    float2 neckRadius=lerp(float2(.055,.068),float2(.170,.170),headBlend);
    float2 qNeck=(source.xz-float2(0,-.016))/neckRadius;
    float neckCranium=1.0-dot(qNeck,qNeck);
    float3 qJaw=(source-float3(0,1.522,.036))/float3(.068,.082,.096);
    float jaw=1.0-dot(qJaw,qJaw);
    return min(bottomClip,max(source.y-1.568,max(neckCranium,jaw)));
}

static const uint NEURAL_RIG_BASE=118016;
float3x3 NeuralRotationX(float a){float s=sin(a),c=cos(a);return float3x3(1,0,0,0,c,-s,0,s,c);}
float3x3 NeuralRotationY(float a){float s=sin(a),c=cos(a);return float3x3(c,0,s,0,1,0,-s,0,c);}
float3x3 NeuralRotationZ(float a){float s=sin(a),c=cos(a);return float3x3(c,-s,0,s,c,0,0,0,1);}
float3x3 NeuralAlign(float3 source,float3 target)
{
    float3 a=normalize(source),b=normalize(target),v=cross(a,b);float c=dot(a,b);
    float3x3 skew=float3x3(0,-v.z,v.y,v.z,0,-v.x,-v.y,v.x,0);
    // IK limbs stay within the reachable forward hemisphere; this safeguard
    // also makes the helper well-defined for an antiparallel diagnostic input.
    if(c<-.9999)
    {
        float3 axis=normalize(cross(a,abs(a.y)<.9?float3(0,1,0):float3(1,0,0)));
        return float3x3(2*axis.x*axis.x-1,2*axis.x*axis.y,2*axis.x*axis.z,
                        2*axis.y*axis.x,2*axis.y*axis.y-1,2*axis.y*axis.z,
                        2*axis.z*axis.x,2*axis.z*axis.y,2*axis.z*axis.z-1);
    }
    return float3x3(1,0,0,0,1,0,0,0,1)+skew+mul(skew,skew)/max(1+c,.0001);
}
void NeuralStoreBone(uint id,uint joint,float3x3 rotation,float3 translation)
{
    uint first=NEURAL_RIG_BASE+id*96+joint*4;
    FrameOutput[first]=float4(rotation[0],translation.x);
    FrameOutput[first+1]=float4(rotation[1],translation.y);
    FrameOutput[first+2]=float4(rotation[2],translation.z);
    FrameOutput[first+3]=float4(0,0,0,1);
}
float3 NeuralPlantPoint(uint id,float time,float side)
{
    float2 velocity=PeopleVelocity(id,time);
    float2 forward=normalize(velocity+float2(.0001,.0001)),right=float2(forward.y,-forward.x);
    float scale=PeopleScale(id);
    uint hipJoint=side>0?1u:2u,ankleJoint=side>0?7u:8u;
    float3 hip=NeuralBodyRig[hipJoint].xyz;
    float3 ankle=hip+mul(NeuralRotationZ(-side*PI/6),NeuralBodyRig[ankleJoint].xyz-hip);
    float soleHeight=NeuralBodyRig[side>0?24:25].x;
    float2 xz=PeopleCentre(id,time)+(right*ankle.x+forward*ankle.z)*scale;
    return float3(xz.x,Terrain(xz)+soleHeight*scale,xz.y);
}
float3 NeuralFootWorld(uint id,float time,float side,float walking,out float swing)
{
    const float period=1.28,stance=.62;
    float offset=id*1.37/TAU+(side<0?.5:0),cycle=time/period+offset;
    float fraction=frac(cycle),start=(floor(cycle)-offset)*period;
    float3 plant=NeuralPlantPoint(id,start+stance*.5*period,side);
    float3 next=NeuralPlantPoint(id,start+(1+stance*.5)*period,side);
    swing=saturate((fraction-stance)/(1-stance));
    float blend=swing*swing*swing*(swing*(swing*6-15)+10);
    float3 foot=lerp(plant,next,blend);float scale=PeopleScale(id);
    // World-space stance anchors remain stationary while the pelvis passes.
    // During swing the foot clears the actual generated terrain, not Y=0.
    float soleHeight=NeuralBodyRig[side>0?24:25].x;
    foot.y=Terrain(foot.xz)+scale*(soleHeight+.075*sin(PI*swing)*sin(PI*swing)*walking);
    return foot;
}
void NeuralWriteLeg(uint id,float time,float side,float3 pelvis,float3 root,float3 right,float3 forward,float walking)
{
    float swing;float3 foot=NeuralFootWorld(id,time,side,walking,swing);float scale=PeopleScale(id);
    float3 d=foot-root;
    float3 ankleTarget=float3(dot(d,right),d.y,dot(d,forward))/scale;
    uint hipJoint=side>0?1u:2u,kneeJoint=side>0?4u:5u,ankleJoint=side>0?7u:8u,toeJoint=side>0?10u:11u;
    float3x3 canonical=NeuralRotationZ(-side*PI/6.0);
    float3 bindHip=NeuralBodyRig[hipJoint].xyz;
    float3 bindKnee=bindHip+mul(canonical,NeuralBodyRig[kneeJoint].xyz-bindHip);
    float3 bindAnkle=bindHip+mul(canonical,NeuralBodyRig[ankleJoint].xyz-bindHip);
    float3 hip=bindHip+pelvis,axis=ankleTarget-hip;
    float upperLength=length(bindKnee-bindHip),lowerLength=length(bindAnkle-bindKnee);
    float reach=clamp(length(axis),abs(upperLength-lowerLength)+.02,upperLength+lowerLength-.002);
    axis=normalize(axis);float3 ankle=hip+axis*reach;
    float along=(upperLength*upperLength-lowerLength*lowerLength+reach*reach)/(2*reach);
    float bend=sqrt(max(upperLength*upperLength-along*along,0));
    float3 kneeDirection=normalize(float3(0,0,1)-axis*axis.z);
    float3 knee=hip+axis*along+kneeDirection*bend;
    float3x3 upper=NeuralAlign(bindKnee-bindHip,knee-hip),lower=NeuralAlign(bindAnkle-bindKnee,ankle-knee);
    float2 dx=float2(.04,0),dz=float2(0,.04);
    float3 ground=normalize(float3(Terrain(foot.xz-dx)-Terrain(foot.xz+dx),.08,Terrain(foot.xz-dz)-Terrain(foot.xz+dz)));
    ground=float3(dot(ground,right),ground.y,dot(ground,forward));
    float3x3 sole=mul(NeuralAlign(float3(0,1,0),ground),NeuralRotationX(.10*sin(PI*swing)*walking));
    float3x3 rotation=mul(upper,canonical);
    NeuralStoreBone(id,hipJoint,rotation,hip-mul(rotation,bindHip));
    rotation=mul(lower,canonical);
    NeuralStoreBone(id,kneeJoint,rotation,knee+mul(lower,bindHip-bindKnee)-mul(rotation,bindHip));
    rotation=mul(sole,canonical);
    float3 translation=ankle+mul(sole,bindHip-bindAnkle)-mul(rotation,bindHip);
    NeuralStoreBone(id,ankleJoint,rotation,translation);NeuralStoreBone(id,toeJoint,rotation,translation);
    float3 groundPoint=foot;groundPoint.y=Terrain(foot.xz);d=groundPoint-root;
    groundPoint=float3(dot(d,right),d.y,dot(d,forward))/scale;
    float4 contact=float4(ground,dot(ground,groundPoint));
    // Fourth records of foot bones carry a contact plane, not a matrix row.
    FrameOutput[NEURAL_RIG_BASE+id*96+ankleJoint*4+3]=contact;
    FrameOutput[NEURAL_RIG_BASE+id*96+toeJoint*4+3]=contact;
}
void NeuralWriteResidentRig(uint id,float time)
{
    float2 velocity=PeopleVelocity(id,time);float speed=length(velocity),walking=smoothstep(.015,.25,speed);
    float3 forward=normalize(float3(velocity.x,0,velocity.y)+float3(.0001,0,.0001)),right=float3(forward.z,0,-forward.x);
    float gait=time*(TAU/1.28)+id*1.37;
    float3 pelvis=float3(.006*sin(gait)*walking,-.010-.004*(1-cos(2*gait))*walking,0);
    float3 root=PeopleRoot(id,time);
    // Lower the common pelvis only as much as required for both feet to remain
    // inside their calibrated reach. Otherwise clamping the IK silently slides
    // or floats a supposedly planted foot at long strides or on slopes.
    [unroll]for(uint leg=0;leg<2;++leg)
    {
        float side=leg==0?1:-1,swing;float3 foot=NeuralFootWorld(id,time,side,walking,swing),d=foot-root;
        float3 target=float3(dot(d,right),d.y,dot(d,forward))/PeopleScale(id);
        float3 h=NeuralBodyRig[leg==0?1:2].xyz,k=NeuralBodyRig[leg==0?4:5].xyz,a=NeuralBodyRig[leg==0?7:8].xyz;
        float reach=length(k-h)+length(a-k)-.005;
        float2 horizontal=target.xz-h.xz-pelvis.xz;
        float highestHip=target.y+sqrt(max(reach*reach-dot(horizontal,horizontal),.01));
        pelvis.y=min(pelvis.y,highestHip-h.y);
    }
    float breathing=.0025*sin(time*(TAU*29.0/128.0)+id*1.37);
    [unroll]for(uint joint=0;joint<24;++joint)
    {
        float3x3 rotation=float3x3(1,0,0,0,1,0,0,0,1);float3 translation=pelvis;
        bool leftArm=joint==16||joint==18||joint==20||joint==22;
        bool rightArm=joint==17||joint==19||joint==21||joint==23;
        if(joint==13||joint==14)
        {
            float side=joint==13?1:-1;float3 clav=float3(side*.085,1.335,-.022);
            rotation=NeuralRotationZ(-side*.15);
            translation=pelvis+clav-mul(rotation,clav);
        }
        else if(leftArm||rightArm)
        {
            // Symmetric anatomical glenohumeral pivot prevents the lateral bind
            // landmark from levering the inner deltoid/armpit upward when lowered.
            float side=leftArm?1:-1;
            float3 shoulder=float3(side*.180,1.314,NeuralBodyRig[leftArm?16:17].z);
            float3x3 shoulderRotation=mul(NeuralRotationX(-side*sin(gait)*.18*walking-.05),NeuralRotationZ(-side*1.31));
            rotation=shoulderRotation;
            float3 localTranslation=0;
            bool lower=joint==18||joint==19||joint==20||joint==21||joint==22||joint==23;
            if(lower)
            {
                float3 elbow=NeuralBodyRig[leftArm?18:19].xyz;
                float3x3 elbowRotation=mul(NeuralRotationY(-side*(.16+.09*max(0,-side*sin(gait))*walking)),NeuralRotationZ(-side*.06));
                localTranslation=mul(rotation,elbow-mul(elbowRotation,elbow));rotation=mul(rotation,elbowRotation);
            }
            translation=pelvis+shoulder-mul(shoulderRotation,shoulder)+localTranslation+float3(-side*.016,-.012,0);
        }
        else if(joint==12||joint==15)
        {
            float yaw=.12*sin(time*(TAU*6.0/128.0)+id*1.37),pitch=.025*sin(time*(TAU*12.0/128.0)+id*1.37);
            rotation=mul(NeuralRotationY(yaw),NeuralRotationX(pitch));float3 neck=NeuralBodyRig[15].xyz;
            translation=pelvis+neck-mul(rotation,neck);
        }
        if(joint>=3&&joint!=4&&joint!=5&&joint!=7&&joint!=8&&joint!=10&&joint!=11)translation.y+=breathing;
        NeuralStoreBone(id,joint,rotation,translation);
    }
    NeuralWriteLeg(id,time,1,pelvis,root,right,forward,walking);
    NeuralWriteLeg(id,time,-1,pelvis,root,right,forward,walking);
}
void NeuralBone(uint joint,float3 source,float3 sourceNormal,uint id,out float3 p,out float3 n)
{
    uint first=NEURAL_RIG_BASE+id*96+joint*4;
    float4 a=SceneInstanceData[first],b=SceneInstanceData[first+1],c=SceneInstanceData[first+2];
    p=float3(dot(a.xyz,source)+a.w,dot(b.xyz,source)+b.w,dot(c.xyz,source)+c.w);
    n=float3(dot(a.xyz,sourceNormal),dot(b.xyz,sourceNormal),dot(c.xyz,sourceNormal));
}

Geometry NeuralPersonGeometry(uint vertex,uint id)
{
    Geometry g=(Geometry)0;
    float3 rawSource=NeuralResidentVertices[vertex*4].xyz;
    float3 source=rawSource;
    float3 sourceNormal=NeuralResidentVertices[vertex*4+1].xyz;
    uint4 joints=asuint(NeuralResidentVertices[vertex*4+2]);
    float4 weights=NeuralResidentVertices[vertex*4+3];
    float2 velocity=PeopleVelocity(id,G.z);
    float speed=length(velocity),walking=saturate(speed*1.8);
    float handSpan=max(0.0,abs(source.x)-.680);
    if(handSpan>0.0)
    {
        source.y-=handSpan*handSpan*1.6;
        source.z-=max(0.0,source.z+.010)*smoothstep(.680,.735,abs(source.x))*.42;
    }
    float3 p=0,n=0;
    [unroll]for(uint k=0;k<4;++k)
    {
        float3 posedPosition,normal;
        NeuralBone(joints[k],source,sourceNormal,id,posedPosition,normal);
        p+=weights[k]*posedPosition;n+=weights[k]*normal;
    }
    float2 footInfluence=0;
    [unroll]for(uint influenceSlot=0;influenceSlot<4;++influenceSlot)
    {
        if(joints[influenceSlot]==7||joints[influenceSlot]==10)footInfluence.x+=weights[influenceSlot];
        if(joints[influenceSlot]==8||joints[influenceSlot]==11)footInfluence.y+=weights[influenceSlot];
    }
    if(max(footInfluence.x,footInfluence.y)>.45)
    {
        uint ankle=footInfluence.x>footInfluence.y?7u:8u;
        float4 contact=SceneInstanceData[NEURAL_RIG_BASE+id*96+ankle*4+3];
        // Learned skin blending can move sole vertices below an otherwise
        // correct ankle target. Enforce the measured ground plane locally.
        float penetration=max(0,contact.w-dot(contact.xyz,p));
        p+=contact.xyz*min(penetration,.025);
    }
    else
    {
        // 3D quilted down-jacket baffle loft, elastic cuffs, waist hem & stand-collar.
        float3 posedDir=normalize(n+1e-6);
        float skinMask=smoothstep(.668,.676,abs(rawSource.x));
        float hemY=.858-.010*saturate(rawSource.z*8.0);
        float jacketMask=(1.0-skinMask)*smoothstep(hemY-.006,hemY+.006,rawSource.y)*(1.0-smoothstep(1.444,1.454,rawSource.y));
        float sleeveMask=smoothstep(.195,.235,abs(rawSource.x));
        float bafflePhase=lerp(rawSource.y*9.5,abs(rawSource.x)*10.2,sleeveMask);
        float baffleWave=abs(sin(bafflePhase*PI));
        float baffleLoft=(1.0-pow(1.0-baffleWave,2.2))*.0042;
        float cuffBand=exp(-pow((abs(rawSource.x)-.656)/.012,2.0))*.0026;
        float hemBand=exp(-pow((rawSource.y-(hemY+.012))/.014,2.0))*.0032;
        float collarBand=smoothstep(1.402,1.425,rawSource.y)*(1.0-smoothstep(1.442,1.455,rawSource.y))*.0038;
        p+=posedDir*((baffleLoft+cuffBand+hemBand)*jacketMask+collarBand*(1.0-skinMask));
    }
    float3 forward=normalize(float3(velocity.x,0,velocity.y)+float3(.0001,0,.0001));
    float3 right=float3(forward.z,0,-forward.x);
    float scale=PeopleScale(id);
    g.local=rawSource;g.uv=rawSource.xy;
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
    // and relative jaw pose. Keep morph weights within subtle anatomical range.
    float4 expression=lerp(NeuralHeadMotion[first*2],NeuralHeadMotion[second*2],frac(frame))*float4(.18,.28,.28,.28);
    [unroll]for(uint k=0;k<4;++k)local+=NeuralHeadVertices[vertex*9+5+k].xyz*expression[k];
    // Sculpt 3D oral fissure parting crease at y=0.1222 (true junction between
    // upward-facing lower lip and downward-facing upper lip) and tuck lower lip.
    float mouthX=saturate(1.0-abs(local.x)/.025);
    float mouthFront=smoothstep(.082,.095,local.z);
    float dyLip=local.y-(.1222-3.5*local.x*local.x);
    float fissure=exp(-pow(dyLip/.0016,2.0))*mouthX*mouthFront;
    float lowerTuck=exp(-pow((local.y-.108)/.009,2.0))*mouthX*mouthFront;
    local.z-=.0016*fissure+.0022*lowerTuck;
    float lipNormalY=(dyLip/.0024)*exp(-pow(dyLip/.0032,2.0))*mouthX*mouthFront;
    normal=normalize(normal+float3(0,-lipNormalY*.26,-.14*fissure));
    float3 source=local+float3(0,1.42,0);
    float3 posed,posedNormal;
    NeuralBone(15,source,normal,id,posed,posedNormal);
    // The trained head skin field identifies the lower neck/collar as root
    // tissue. Attach that influence to the torso, not the moving head: rotating
    // the entire crop used to pull the captured collar away from the shirt.
    uint4 joints=asuint(NeuralHeadVertices[vertex*9+2]);
    float4 weights=NeuralHeadVertices[vertex*9+3];float rootInfluence=0;
    [unroll]for(uint j=0;j<4;++j)if(joints[j]==0)rootInfluence+=weights[j];
    float3 torso,torsoNormal;NeuralBone(9,source,normal,id,torso,torsoNormal);
    posed=lerp(posed,torso,saturate(rootInfluence));
    posedNormal=normalize(lerp(posedNormal,torsoNormal,saturate(rootInfluence)));
    float2 velocity=PeopleVelocity(id,G.z);
    float3 forward=normalize(float3(velocity.x,0,velocity.y)+float3(.0001,0,.0001));
    float3 right=float3(forward.z,0,-forward.x);
    g.p=PeopleRoot(id,G.z)+(right*posed.x+float3(0,posed.y,0)+forward*posed.z)*PeopleScale(id);
    g.n=normalize(right*posedNormal.x+float3(0,posedNormal.y,0)+forward*posedNormal.z);
    g.local=source;g.uv=local.xy;g.material=51;g.seed=Hash21(float2(id,953));g.moving=1;
    g.learnedColor=NeuralHeadVertices[vertex*9+4].rgb;
    return g;
}
