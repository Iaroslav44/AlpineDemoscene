#ifndef ALPINE_HUMAN_PROCEDURAL_HLSLI
#define ALPINE_HUMAN_PROCEDURAL_HLSLI

// Compact, texture-free animated adult for a fullscreen SDF ray marcher.
// Coordinate convention: root is between the feet, +Y is up and forward is
// the direction of the face.  scale=1 gives a person about 1.78 metres tall.
// personId and phase deliberately de-synchronise a crowd.

static const float HUM_PI = 3.14159265359;
static const float HUM_MAT_SKIN  = 21.0;
static const float HUM_MAT_EYE   = 22.0;
static const float HUM_MAT_HAIR  = 23.0;
static const float HUM_MAT_LIP   = 24.0;
static const float HUM_MAT_TOP   = 25.0;
static const float HUM_MAT_LEG   = 26.0;
static const float HUM_MAT_SHOE  = 27.0;
static const float HUM_MAT_MOUTH = 28.0;

struct HumanHit
{
    float distance;
    float material;
};

struct HumanSurface
{
    float distance;
    float material;
    float3 normal;
    float3 albedo;
    float roughness;
};

struct HumanPose
{
    float seed;
    float gait;
    float breath;
    float blink;
    float emotion;
    float headYaw;
    float headPitch;
    float2 gaze;
    float stride;
    float walking;
    float garmentDetail;
};

// Prepared once per intersected resident, not for every march/normal sample.
struct HumanPrepared
{
    float3 root;
    float3 right;
    float3 front;
    float scale;
    HumanPose pose;
};

float HumHash11(float n)
{
    return frac(sin(n * 127.17 + 19.19) * 43758.5453);
}

float HumHash31(float3 p)
{
    return frac(sin(dot(p, float3(17.17, 59.41, 113.53))) * 43758.5453);
}

float HumSdEllipsoid(float3 p, float3 r)
{
    float k0 = length(p / r);
    float k1 = length(p / (r * r));
    if(k1 < 1.0e-5) return -min(r.x,min(r.y,r.z));
    return k0 * (k0 - 1.0) / max(k1, 1.0e-5);
}

float HumSdCapsule(float3 p, float3 a, float3 b, float radius)
{
    float3 pa = p - a;
    float3 ba = b - a;
    float h = saturate(dot(pa, ba) / max(dot(ba, ba), 1.0e-6));
    return length(pa - ba * h) - radius;
}

float HumSmoothMin(float a, float b, float k)
{
    float h = saturate(0.5 + 0.5 * (b - a) / k);
    return lerp(b, a, h) - k * h * (1.0 - h);
}

float2 HumRot(float2 p, float a)
{
    float c = cos(a), s = sin(a);
    return float2(c * p.x - s * p.y, s * p.x + c * p.y);
}

float3 HumRotateHead(float3 p, float yaw, float pitch)
{
    p.xz = HumRot(p.xz, -yaw);
    p.yz = HumRot(p.yz, -pitch);
    return p;
}

void HumBasis(float3 requestedForward, out float3 right, out float3 up, out float3 front)
{
    up = float3(0.0, 1.0, 0.0);
    float2 flat = requestedForward.xz;
    if (dot(flat, flat) < 1.0e-8) flat = float2(0.0, 1.0);
    flat /= max(length(flat), 1.0e-4);
    front = float3(flat.x, 0.0, flat.y);
    right = normalize(cross(up, front));
}

float3 HumToLocal(float3 worldPosition, float3 root, float3 right,
                  float3 up, float3 front, float scale)
{
    float3 d = (worldPosition - root) / max(scale, 1.0e-4);
    return float3(dot(d, right), dot(d, up), dot(d, front));
}

float HumBlinkPulse(float time, float seed)
{
    // A short asymmetric blink, plus an occasional quieter follow-up blink.
    float rate = 0.155 + 0.035 * seed;
    float p0 = abs(frac(time * rate + seed * 0.73) - 0.5);
    float p1 = abs(frac(time * rate + seed * 0.73 + 0.075) - 0.5);
    float b0 = 1.0 - smoothstep(0.012, 0.048, p0);
    float b1 = (1.0 - smoothstep(0.008, 0.025, p1)) * step(0.72, HumHash11(floor(time * rate) + seed));
    return saturate(max(b0, b1 * 0.72));
}

HumanPose HumanAnimate(float time, float personId, float phase, float3 cameraLocal)
{
    HumanPose o;
    o.seed = HumHash11(personId * 9.73 + 2.61);
    float tempo = 4.65 + 0.55 * HumHash11(personId * 3.31 + 7.0);
    o.gait = time * tempo + phase + o.seed * 2.0 * HUM_PI;
    o.stride = 0.20;
    o.walking = 1.0;
    o.garmentDetail = 1.0;
    o.breath = sin(time * (1.05 + 0.17 * o.seed) + phase * 0.37);
    o.blink = HumBlinkPulse(time + phase * 0.19, o.seed);

    // Emotion moves slowly and continuously; the faster term keeps it alive
    // without turning the face into an exaggerated procedural mask.
    float mood = sin(time * (0.105 + 0.025 * o.seed) + phase + o.seed * 8.0);
    o.emotion = 0.68 * mood + 0.10 * sin(time * 0.73 + o.seed * 17.0);

    float3 toCamera = cameraLocal - float3(0.0, 1.62, 0.0);
    float cameraYaw = atan2(toCamera.x, toCamera.z);
    float cameraPitch = atan2(toCamera.y, max(length(toCamera.xz), 0.05));
    float attention = (1.0 - smoothstep(1.4, 8.0, length(toCamera)))
                    * smoothstep(-0.1,0.4,toCamera.z / max(length(toCamera),0.01));
    float idleYaw = 0.22 * sin(time * 0.21 + o.seed * 11.0) + 0.07 * sin(time * 0.83 + phase);
    float idlePitch = 0.035 * sin(time * 0.31 + o.seed * 5.0);
    o.headYaw = clamp(lerp(idleYaw, cameraYaw * 0.55, attention * 0.56), -0.62, 0.62);
    o.headPitch = clamp(lerp(idlePitch, cameraPitch * 0.36, attention * 0.42), -0.20, 0.18);

    // Piecewise-held targets with a very fast transition read as natural
    // saccades.  They are biased gently toward the camera when it is nearby.
    float eyeClock = time * (0.72 + 0.18 * o.seed) + phase * 0.31;
    float eyeCell = floor(eyeClock);
    float eyeBlend = smoothstep(0.02, 0.10, frac(eyeClock));
    float2 g0 = float2(HumHash11(eyeCell + personId * 13.1), HumHash11(eyeCell + personId * 7.7 + 4.0)) - 0.5;
    float2 g1 = float2(HumHash11(eyeCell + personId * 13.1 + 1.0), HumHash11(eyeCell + personId * 7.7 + 5.0)) - 0.5;
    float2 idleGaze = lerp(g0, g1, eyeBlend) * float2(0.90, 0.55);
    float2 cameraGaze = float2(cameraYaw - o.headYaw, cameraPitch - o.headPitch) * float2(0.80, 0.65);
    o.gaze = clamp(lerp(idleGaze, cameraGaze, attention * 0.58), -0.75, 0.75);
    return o;
}

void HumTake(inout float distance, inout float material, float candidate, float candidateMaterial)
{
    if (candidate < distance)
    {
        distance = candidate;
        material = candidateMaterial;
    }
}

float2 HumFootCycle(float gait, float stride)
{
    // 62% stance: the planted foot moves backwards at the actor's root speed.
    // The remainder is a smooth airborne recovery with zero endpoint velocity.
    float cycle=frac(gait/(2.0*HUM_PI));
    if(cycle<0.62)return float2(lerp(stride,-stride,cycle/0.62),0.0);
    float swing=(cycle-0.62)/0.38;
    return float2(lerp(-stride,stride,smoothstep(0.0,1.0,swing)),sin(swing*HUM_PI));
}

float3 HumKnee(float3 hip,float3 ankle)
{
    // Two-bone IK keeps the knee on the forward bending plane. Each leg uses
    // fixed 43.5 cm segments rather than independently oscillating joints.
    float3 delta=ankle-hip;
    float distance=max(length(delta),0.001);
    float3 axis=delta/distance;
    float along=min(distance*0.5,0.4349);
    float bend=sqrt(max(0.435*0.435-along*along,0.0));
    float3 pole=float3(0,0,1)-axis*axis.z;
    pole*=rsqrt(max(dot(pole,pole),0.0001));
    return hip+axis*along+pole*bend;
}

HumanHit HumanMapLocalPose(float3 p, HumanPose pose)
{
    HumanHit hit;
    hit.distance = 1000.0;
    hit.material = 0.0;

    float3 bounds=abs(p-float3(0,0.92,0.02))-float3(0.43,0.99,0.51);
    float bodyBound=length(max(bounds,0.0));
    if(bodyBound>0.025){hit.distance=bodyBound;return hit;}

    float stepL = sin(pose.gait)*pose.walking;
    float stepR = -stepL;
    float2 footCycleL=HumFootCycle(pose.gait,pose.stride);
    float2 footCycleR=HumFootCycle(pose.gait+HUM_PI,pose.stride);
    float liftL = footCycleL.y*pose.walking;
    float liftR = footCycleR.y*pose.walking;
    float bob = 0.012 * (1.0 - cos(pose.gait * 2.0))*pose.walking + 0.004 * pose.breath;
    float sway = 0.012 * sin(pose.gait)*pose.walking;

    // Contact-aware walking legs.  The knee advances before the lifted foot;
    // each person gets the same coherent gait at an independent phase.
    float3 hipL = float3(-0.105 + sway, 0.91 + bob, 0.0);
    float3 hipR = float3( 0.105 + sway, 0.91 + bob, 0.0);
    float3 ankleL = float3(-0.100, 0.098 + 0.075 * liftL, footCycleL.x);
    float3 ankleR = float3( 0.100, 0.098 + 0.075 * liftR, footCycleR.x);
    float3 kneeL=HumKnee(hipL,ankleL);
    float3 kneeR=HumKnee(hipR,ankleR);
    float legs = HumSdCapsule(p, hipL, kneeL, 0.073);
    legs = min(legs, HumSdCapsule(p, kneeL, ankleL, 0.057));
    legs = min(legs, HumSdCapsule(p, hipR, kneeR, 0.073));
    legs = min(legs, HumSdCapsule(p, kneeR, ankleR, 0.057));
    HumTake(hit.distance, hit.material, legs, HUM_MAT_LEG);

    float footL = HumSdEllipsoid(p - (ankleL + float3(0.0, -0.045, 0.065)), float3(0.080, 0.052, 0.145));
    float footR = HumSdEllipsoid(p - (ankleR + float3(0.0, -0.045, 0.065)), float3(0.080, 0.052, 0.145));
    HumTake(hit.distance, hit.material, min(footL, footR), HUM_MAT_SHOE);

    // Pelvis, rib cage and shoulders form one breathing cloth volume.
    float3 tp = p - float3(sway, bob, 0.0);
    tp.z /= 1.0 + 0.018 * pose.breath;
    float torso = HumSdEllipsoid(tp - float3(0.0, 1.18, 0.0), float3(0.205, 0.330, 0.125));
    torso = HumSmoothMin(torso, HumSdEllipsoid(tp - float3(0.0, 1.355, 0.0), float3(0.285, 0.115, 0.145)), 0.055);
    torso = HumSmoothMin(torso, HumSdEllipsoid(tp - float3(0.0, 0.955, 0.0), float3(0.195, 0.135, 0.120)), 0.050);
    // Millimetre-scale fabric displacement is attenuated before it becomes
    // subpixel. Its maximum derivative is below 0.28; the marcher uses 0.70.
    float foldGate=smoothstep(0.90,1.02,tp.y)*(1.0-smoothstep(1.27,1.42,tp.y));
    float folds=sin(tp.y*74.0+abs(tp.x)*26.0+0.30*pose.breath)
               *sin(tp.y*31.0-tp.x*18.0);
    torso+=folds*(0.0015*foldGate*pose.garmentDetail);
    HumTake(hit.distance, hit.material, torso, HUM_MAT_TOP);

    // A real raised hiking-jacket collar follows the same breathing transform
    // as the cloth volume. It stays inside the conservative whole-body bound.
    float collar=HumSdCapsule(tp,float3(-0.064,1.475,0.016),float3(-0.070,1.403,0.108),0.017);
    collar=min(collar,HumSdCapsule(tp,float3(0.064,1.475,0.016),float3(0.070,1.403,0.108),0.017));
    collar=min(collar,HumSdCapsule(tp,float3(-0.064,1.475,0.016),float3(0.064,1.475,0.016),0.013));
    HumTake(hit.distance,hit.material,collar,HUM_MAT_TOP);

    // Arms counter-swing against the legs.  A slight elbow bend prevents the
    // pendulum look common in cheap procedural walkers.
    float3 shoulderL = float3(-0.270 + sway, 1.355 + bob, 0.0);
    float3 shoulderR = float3( 0.270 + sway, 1.355 + bob, 0.0);
    float3 elbowL = float3(-0.302 + sway, 1.085 + bob, -0.095 * stepL + 0.025);
    float3 elbowR = float3( 0.302 + sway, 1.085 + bob, -0.095 * stepR + 0.025);
    float3 wristL = float3(-0.274 + sway, 0.855 + bob, -0.185 * stepL + 0.015 * liftR);
    float3 wristR = float3( 0.274 + sway, 0.855 + bob, -0.185 * stepR + 0.015 * liftL);
    float sleeves = HumSdCapsule(p, shoulderL, elbowL, 0.058);
    sleeves = min(sleeves, HumSdCapsule(p, shoulderR, elbowR, 0.058));
    HumTake(hit.distance, hit.material, sleeves, HUM_MAT_TOP);
    float forearms = HumSdCapsule(p, elbowL, wristL, 0.045);
    forearms = min(forearms, HumSdCapsule(p, elbowR, wristR, 0.045));
    forearms = min(forearms, HumSdEllipsoid(p - (wristL + float3(0.0, -0.045, 0.0)), float3(0.050, 0.075, 0.034)));
    forearms = min(forearms, HumSdEllipsoid(p - (wristR + float3(0.0, -0.045, 0.0)), float3(0.050, 0.075, 0.034)));
    HumTake(hit.distance, hit.material, forearms, HUM_MAT_SKIN);

    // The neck follows torso breathing while the complete head rotates around
    // its anatomical pivot.  All facial features share this transform.
    float neck = HumSdCapsule(p, float3(sway, 1.395 + bob, 0.0), float3(sway, 1.515 + bob, 0.0), 0.066);
    HumTake(hit.distance, hit.material, neck, HUM_MAT_SKIN);
    float3 pivot = float3(sway, 1.485 + bob, 0.0);
    float3 hp = HumRotateHead(p - pivot, pose.headYaw, pose.headPitch) + float3(0.0, 1.485, 0.0);

    // A conservative head sphere lets legs/torso skip the detailed face. Never
    // report its boundary as a surface: the detailed field takes over at 6 cm.
    float headBound=length(hp-float3(0,1.64,0.045))-0.29;
    if(headBound>0.06)
    {
        if(headBound<hit.distance){hit.distance=headBound;hit.material=0.0;}
        return hit;
    }

    float skin = HumSdEllipsoid(hp - float3(0.0, 1.655, -0.006), float3(0.113, 0.142, 0.106));
    skin = HumSmoothMin(skin, HumSdEllipsoid(hp - float3(0.0, 1.615, 0.038), float3(0.099, 0.124, 0.100)), 0.022);
    skin = HumSmoothMin(skin, HumSdEllipsoid(hp - float3(0.0, 1.565, 0.052), float3(0.080, 0.086, 0.082)), 0.018);
    skin = HumSmoothMin(skin, HumSdEllipsoid(hp - float3(0.0, 1.500, 0.069), float3(0.047, 0.041, 0.047)), 0.012);
    skin = min(skin, HumSdEllipsoid(hp - float3(-0.109, 1.626, -0.003), float3(0.022, 0.043, 0.014)));
    skin = min(skin, HumSdEllipsoid(hp - float3( 0.109, 1.626, -0.003), float3(0.022, 0.043, 0.014)));

    // Nose bridge, alae and tip have distinct volumes; tiny dark nostril
    // cavities break the wax-mask silhouette without a normal/albedo texture.
    skin = HumSmoothMin(skin, HumSdEllipsoid(hp - float3(0.0, 1.626, 0.132), float3(0.015, 0.055, 0.022)), 0.007);
    skin = HumSmoothMin(skin, HumSdEllipsoid(hp - float3(0.0, 1.585, 0.154), float3(0.020, 0.021, 0.026)), 0.006);
    skin = HumSmoothMin(skin, HumSdEllipsoid(hp - float3(-0.015, 1.580, 0.147), float3(0.010, 0.011, 0.016)), 0.004);
    skin = HumSmoothMin(skin, HumSdEllipsoid(hp - float3( 0.015, 1.580, 0.147), float3(0.010, 0.011, 0.016)), 0.004);

    // Eye sockets are true cavities, filled by procedural eyeballs and lids.
    float eyeY = 1.647;
    float eyeX = 0.043;
    float socketL = HumSdEllipsoid(hp - float3(-eyeX, eyeY, 0.113), float3(0.019, 0.014, 0.020));
    float socketR = HumSdEllipsoid(hp - float3( eyeX, eyeY, 0.113), float3(0.019, 0.014, 0.020));
    skin = max(skin, -min(socketL, socketR));

    float opening = lerp(0.0075, 0.0008, pose.blink);
    float eyeL = HumSdEllipsoid(hp - float3(-eyeX, eyeY, 0.111), float3(0.0165, 0.014, 0.018));
    float eyeR = HumSdEllipsoid(hp - float3( eyeX, eyeY, 0.111), float3(0.0165, 0.014, 0.018));
    eyeL = max(eyeL, abs(hp.y - eyeY) - opening);
    eyeR = max(eyeR, abs(hp.y - eyeY) - opening);
    HumTake(hit.distance, hit.material, min(eyeL, eyeR), HUM_MAT_EYE);

    float smile = pose.emotion * 0.0045;
    float lidUpper = eyeY + lerp(0.0068, 0.0007, pose.blink) + smile * 0.20;
    float lidLower = eyeY - lerp(0.0060, 0.0007, pose.blink);
    float lids = 100.0;
    lids = min(lids, HumSdCapsule(hp, float3(-eyeX - 0.0165, eyeY, 0.113), float3(-eyeX, lidUpper, 0.128), 0.0022));
    lids = min(lids, HumSdCapsule(hp, float3(-eyeX, lidUpper, 0.128), float3(-eyeX + 0.0165, eyeY, 0.113), 0.0022));
    lids = min(lids, HumSdCapsule(hp, float3( eyeX - 0.0165, eyeY, 0.113), float3( eyeX, lidUpper, 0.128), 0.0022));
    lids = min(lids, HumSdCapsule(hp, float3( eyeX, lidUpper, 0.128), float3( eyeX + 0.0165, eyeY, 0.113), 0.0022));
    lids = min(lids, HumSdCapsule(hp, float3(-eyeX - 0.0160, eyeY, 0.113), float3(-eyeX, lidLower, 0.127), 0.0017));
    lids = min(lids, HumSdCapsule(hp, float3(-eyeX, lidLower, 0.127), float3(-eyeX + 0.0160, eyeY, 0.113), 0.0017));
    lids = min(lids, HumSdCapsule(hp, float3( eyeX - 0.0160, eyeY, 0.113), float3( eyeX, lidLower, 0.127), 0.0017));
    lids = min(lids, HumSdCapsule(hp, float3( eyeX, lidLower, 0.127), float3( eyeX + 0.0160, eyeY, 0.113), 0.0017));
    if (pose.blink > 0.05)
    {
        float curtainL = HumSdEllipsoid(hp - float3(-eyeX, eyeY, 0.126), float3(0.018, 0.008 * pose.blink, 0.005));
        float curtainR = HumSdEllipsoid(hp - float3( eyeX, eyeY, 0.126), float3(0.018, 0.008 * pose.blink, 0.005));
        lids = min(lids, min(curtainL, curtainR));
    }
    skin = min(skin, lids);

    // Cheek compression, lips and the mouth gap communicate a restrained
    // emotion while preserving adult facial proportions.
    float cheekRaise = max(pose.emotion, 0.0) * 0.004;
    skin = HumSmoothMin(skin, HumSdEllipsoid(hp - float3(-0.060, 1.585 + cheekRaise, 0.099), float3(0.034, 0.028, 0.018)), 0.012);
    skin = HumSmoothMin(skin, HumSdEllipsoid(hp - float3( 0.060, 1.585 + cheekRaise, 0.099), float3(0.034, 0.028, 0.018)), 0.012);
    HumTake(hit.distance, hit.material, skin, HUM_MAT_SKIN);

    float mouthY = 1.539;
    float cornerY = mouthY + smile;
    float mouthGap = HumSdCapsule(hp, float3(-0.021, cornerY, 0.139), float3(0.021, cornerY, 0.139), 0.0020 + max(-pose.emotion, 0.0) * 0.0012);
    HumTake(hit.distance, hit.material, mouthGap, HUM_MAT_MOUTH);
    float lips = HumSdCapsule(hp, float3(-0.025, cornerY, 0.143), float3(0.0, mouthY + 0.003, 0.146), 0.0040);
    lips = min(lips, HumSdCapsule(hp, float3(0.0, mouthY + 0.003, 0.146), float3(0.025, cornerY, 0.143), 0.0040));
    lips = min(lips, HumSdCapsule(hp, float3(-0.024, cornerY - 0.0015, 0.143), float3(0.0, mouthY - 0.006, 0.145), 0.0042));
    lips = min(lips, HumSdCapsule(hp, float3(0.0, mouthY - 0.006, 0.145), float3(0.024, cornerY - 0.0015, 0.143), 0.0042));
    HumTake(hit.distance, hit.material, lips, HUM_MAT_LIP);

    // Eyebrows react in the opposite direction at their inner ends.  Hair is
    // a slightly irregular volumetric cap, never a sampled texture.
    float browInner = pose.emotion * 0.0045;
    float brows = HumSdCapsule(hp, float3(-0.064, 1.674, 0.102), float3(-0.022, 1.680 + browInner, 0.124), 0.0038);
    brows = min(brows, HumSdCapsule(hp, float3(0.022, 1.680 + browInner, 0.124), float3(0.064, 1.674, 0.102), 0.0038));
    float hair = HumSdEllipsoid(hp - float3(0.0, 1.700, -0.022), float3(0.119, 0.111, 0.111));
    float hairline = 1.675 + 0.012 * cos(hp.x * 34.0 + pose.seed * 5.0);
    hair = max(hair, hairline - hp.y);
    hair += 0.0018 * sin(dot(hp, float3(91.0, 137.0, 73.0)) + pose.seed * 19.0)*pose.garmentDetail;
    HumTake(hit.distance, hit.material, min(hair, brows), HUM_MAT_HAIR);

    // Two tiny nostril cavities are dark geometry, not painted pixels.
    float nostril = HumSdEllipsoid(hp - float3(-0.010, 1.576, 0.174), float3(0.0043, 0.0028, 0.0030));
    nostril = min(nostril, HumSdEllipsoid(hp - float3(0.010, 1.576, 0.174), float3(0.0043, 0.0028, 0.0030)));
    HumTake(hit.distance, hit.material, nostril, HUM_MAT_MOUTH);
    return hit;
}

HumanHit HumanMapLocal(float3 p, float time, float personId, float phase, float3 cameraLocal)
{
    return HumanMapLocalPose(p,HumanAnimate(time,personId,phase,cameraLocal));
}

HumanPrepared HumanPrepare(float time,float3 cameraPosition,float3 root,
                            float3 forward,float scale,float personId,float phase,float speed,float pixelFootprint)
{
    HumanPrepared context;
    float3 up;
    HumBasis(forward,context.right,up,context.front);
    context.root=root;context.scale=max(scale,0.0001);
    float3 cameraLocal=HumToLocal(cameraPosition,root,context.right,up,context.front,context.scale);
    context.pose=HumanAnimate(time,personId,phase,cameraLocal);
    float tempo=4.65+0.55*HumHash11(personId*3.31+7.0);
    context.pose.stride=min(0.28,max(speed,0.0)/context.scale*(2.0*HUM_PI/tempo)*0.31);
    context.pose.walking=saturate(speed/0.32);
    context.pose.garmentDetail=1.0-smoothstep(0.002,0.010,pixelFootprint/context.scale);
    return context;
}

float3 HumanPreparedLocal(float3 worldPosition,HumanPrepared context)
{
    float3 p=(worldPosition-context.root)/context.scale;
    return float3(dot(p,context.right),p.y,dot(p,context.front));
}

HumanHit HumanMapPrepared(float3 worldPosition,HumanPrepared context)
{
    HumanHit hit=HumanMapLocalPose(HumanPreparedLocal(worldPosition,context),context.pose);
    hit.distance*=context.scale;
    return hit;
}

float3 HumanNormalPrepared(float3 p,HumanPrepared context,float epsilon)
{
    float3 g=0.0;
    // A retained loop shares the expensive face field's bytecode across the
    // four tetrahedral samples (important for the one-megabyte executable).
    [loop]for(int i=0;i<4;++i)
    {
        float3 k=float3((i==0||i==3)?1.0:-1.0,i>=2?1.0:-1.0,(i&1)?1.0:-1.0);
        g+=k*HumanMapPrepared(p+k*epsilon,context).distance;
    }
    return g*rsqrt(max(dot(g,g),1.0e-16));
}

// Cheap function intended for every ray-march step.
HumanHit HumanMap(float3 worldPosition, float time, float3 cameraPosition,
                  float3 root, float3 forward, float scale,
                  float personId, float phase)
{
    float3 right, up, front;
    HumBasis(forward, right, up, front);
    float3 p = HumToLocal(worldPosition, root, right, up, front, scale);
    float3 cameraLocal = HumToLocal(cameraPosition, root, right, up, front, scale);
    HumanHit h = HumanMapLocal(p, time, personId, phase, cameraLocal);
    h.distance *= max(scale, 1.0e-4);
    return h;
}

float HumanDistance(float3 worldPosition, float time, float3 cameraPosition,
                    float3 root, float3 forward, float scale,
                    float personId, float phase)
{
    return HumanMap(worldPosition, time, cameraPosition, root, forward, scale, personId, phase).distance;
}

float3 HumanNormal(float3 worldPosition, float time, float3 cameraPosition,
                   float3 root, float3 forward, float scale,
                   float personId, float phase)
{
    float cameraDistance = length(cameraPosition - worldPosition);
    float e = clamp(max(scale, 1.0e-4) * 0.00065 + cameraDistance * 0.000015, 0.00025, 0.0025);
    // Tetrahedral gradient: four map evaluations instead of the six required
    // by a central axis stencil.  It is rotationally balanced and materially
    // cheaper in the portrait shot, where HumanMap contains the full face.
    float3 k0 = float3( 1.0, -1.0, -1.0);
    float3 k1 = float3(-1.0, -1.0,  1.0);
    float3 k2 = float3(-1.0,  1.0, -1.0);
    float3 k3 = float3( 1.0,  1.0,  1.0);
    float3 g = k0 * HumanDistance(worldPosition + k0 * e, time, cameraPosition, root, forward, scale, personId, phase)
             + k1 * HumanDistance(worldPosition + k1 * e, time, cameraPosition, root, forward, scale, personId, phase)
             + k2 * HumanDistance(worldPosition + k2 * e, time, cameraPosition, root, forward, scale, personId, phase)
             + k3 * HumanDistance(worldPosition + k3 * e, time, cameraPosition, root, forward, scale, personId, phase);
    return normalize(g);
}

float HumDetailAttenuation(float angularFrequency,float footprint)
{
    float w=angularFrequency*footprint;
    return exp2(-0.08*w*w);
}

float HumLineMask(float distance,float halfWidth,float footprint)
{
    float aa=max(footprint,0.0003);
    return 1.0-smoothstep(halfWidth-aa,halfWidth+aa,abs(distance));
}

float HumRectMask(float2 p,float2 halfSize,float footprint)
{
    float2 d=abs(p)-halfSize;
    float aa=max(footprint,0.0003);
    return 1.0-smoothstep(-aa,aa,max(d.x,d.y));
}

void HumanMaterialLocal(float3 p, HumanPose pose, float personId,
                        float material, float footprint, out float3 albedo, out float roughness)
{
    float seed2 = HumHash11(personId * 5.31 + 11.0);
    float skinTone = saturate(0.12 + 0.78 * pose.seed);
    float3 skinDark = float3(0.105, 0.038, 0.021);
    float3 skinLight = float3(0.64, 0.315, 0.205);
    float bob=0.012*(1.0-cos(pose.gait*2.0))*pose.walking+0.004*pose.breath;
    float sway=0.012*sin(pose.gait)*pose.walking;
    float3 hp=HumRotateHead(p-float3(sway,1.485+bob,0),pose.headYaw,pose.headPitch)+float3(0,1.485,0);
    float3 tp=p-float3(sway,bob,0);
    tp.z/=1.0+0.018*pose.breath;
    float faceMask=smoothstep(1.46,1.52,p.y)*smoothstep(0.045,0.10,hp.z);
    float3 surfaceP=lerp(p,hp,smoothstep(1.43,1.50,p.y));
    float pores = (HumHash31(floor(surfaceP * 360.0 + pose.seed * 23.0)) - 0.5)
                * (1.0-smoothstep(0.0007,0.003,footprint));
    albedo = lerp(skinDark, skinLight, skinTone) * (1.0 + pores * 0.045);
    roughness = 0.43 + pores * 0.035;

    // Broad chromatic zones survive low resolution; pores are never substituted
    // for face structure. All features remain attached to the articulated head.
    float2 cheek=(float2(abs(hp.x),hp.y)-float2(0.063,1.588))/float2(0.032,0.027);
    float cheekFlush=exp2(-dot(cheek,cheek)*1.6)*faceMask;
    float2 underEye=(float2(abs(hp.x),hp.y)-float2(0.043,1.626))/float2(0.027,0.012);
    float eyeShade=exp2(-dot(underEye,underEye)*1.7)*faceMask;
    albedo*=lerp(float3(1,1,1),float3(1.07,0.88,0.83),cheekFlush*0.65);
    albedo*=1.0-eyeShade*0.15;
    float beardMask=faceMask*(1.0-smoothstep(1.555,1.593,hp.y))
                   *smoothstep(0.026,0.072,abs(hp.x)+max(0.0,1.55-hp.y));
    float stubble=0.30+0.10*sin(hp.x*1320.0+hp.y*140.0)*sin(hp.y*1170.0)
                              *HumDetailAttenuation(1350.0,footprint);
    albedo*=1.0-beardMask*stubble;
    roughness=lerp(roughness,0.54,beardMask*0.7);
    float noseOil=faceMask*exp2(-hp.x*hp.x*2300.0-pow((hp.y-1.60)*24.0,2.0));
    roughness=lerp(roughness,0.35,noseOil*0.65);

    if (abs(material - HUM_MAT_EYE) < 0.5)
    {
        float eyeSide = (hp.x < 0.0) ? -0.043 : 0.043;
        float2 irisPoint = float2(eyeSide, 1.647) + pose.gaze * float2(0.0045, 0.0030);
        float irisRadius = length((hp.xy - irisPoint) / float2(1.0, 0.92));
        float3 irisA = lerp(float3(0.035, 0.090, 0.075), float3(0.13, 0.075, 0.028), seed2);
        float irisDetail=HumDetailAttenuation(1600.0,footprint);
        float radial = 0.78 + 0.22 * sin(irisRadius * 1250.0 + atan2(hp.y - irisPoint.y, hp.x - irisPoint.x) * 9.0)*irisDetail;
        float eyeAA=max(footprint*0.5,0.00025);
        albedo = float3(0.61, 0.59, 0.55);
        float irisMask=1.0-smoothstep(0.0058-eyeAA,0.0058+eyeAA,irisRadius);
        float limbal=HumLineMask(irisRadius-0.0055,0.0005,footprint);
        albedo = lerp(albedo, irisA * radial*(1.0-0.45*limbal),irisMask);
        albedo = lerp(albedo, float3(0.004, 0.003, 0.002), 1.0 - smoothstep(0.0024-eyeAA,0.0024+eyeAA,irisRadius));
        roughness = 0.075;
    }
    else if (abs(material - HUM_MAT_HAIR) < 0.5)
    {
        float strand = 0.86 + 0.14 * sin(dot(hp, float3(83.0, 121.0, 49.0)) + pose.seed * 13.0)
                                       *HumDetailAttenuation(155.0,footprint);
        float brow=saturate((1.705-hp.y)*60.0)*smoothstep(0.08,0.13,hp.z);
        strand*=1.0+0.08*brow*sin(hp.x*1700.0+hp.y*300.0)*HumDetailAttenuation(1725.0,footprint);
        albedo = lerp(float3(0.012, 0.008, 0.006), float3(0.16, 0.065, 0.020), seed2) * strand;
        roughness = 0.46;
    }
    else if (abs(material - HUM_MAT_LIP) < 0.5)
    {
        albedo = lerp(float3(0.24, 0.055, 0.045), float3(0.42, 0.11, 0.085), skinTone);
        float grooves=sin(hp.x*1350.0+sin(hp.y*180.0))*HumDetailAttenuation(1400.0,footprint);
        albedo*=1.0+0.035*grooves;
        roughness = 0.34+0.025*grooves;
    }
    else if (abs(material - HUM_MAT_TOP) < 0.5)
    {
        float weave = 0.96 + 0.04 * sin(tp.x * 330.0) * sin(tp.y * 310.0)
                            * HumDetailAttenuation(455.0,footprint);
        albedo = lerp(float3(0.025, 0.075, 0.105), float3(0.30, 0.055, 0.032), seed2) * weave;
        float front=smoothstep(0.015,0.085,tp.z)*(1.0-smoothstep(0.21,0.25,abs(tp.x)));
        float shoulder=smoothstep(1.305,1.330,tp.y)*smoothstep(0.095,0.15,abs(tp.x));
        float sleeve=smoothstep(0.225,0.255,abs(tp.x));
        float collar=smoothstep(1.405,1.44,tp.y);
        albedo*=lerp(1.0,0.46,max(collar,max(shoulder,sleeve*0.6)));
        roughness = 0.78;

        // A broad zipper tape and panel seams remain readable. Fine teeth and
        // stitching dissolve to their mean when smaller than a pixel.
        float tape=HumRectMask(tp.xy-float2(0,1.185),float2(0.010,0.205),footprint)*front;
        albedo=lerp(albedo,albedo*0.28,tape);
        float zipLine=HumRectMask(tp.xy-float2(0,1.185),float2(0.0025,0.198),footprint)*front;
        float teeth=0.72+0.28*sin(tp.y*1650.0)*HumDetailAttenuation(1650.0,footprint);
        albedo=lerp(albedo,float3(0.22,0.24,0.25)*teeth,zipLine);
        roughness=lerp(roughness,0.29,zipLine);
        float pull=HumRectMask(tp.xy-float2(0,1.285),float2(0.006,0.013),footprint)*front;
        albedo=lerp(albedo,float3(0.31,0.33,0.34),pull);
        roughness=lerp(roughness,0.24,pull);

        float2 pocket=float2(abs(tp.x)-0.114,tp.y-1.085-0.18*abs(tp.x));
        float pocketFace=HumRectMask(pocket,float2(0.044,0.052),footprint)*front;
        albedo*=1.0-0.09*pocketFace;
        float pocketEdge=HumRectMask(pocket,float2(0.047,0.055),footprint)
                         -HumRectMask(pocket,float2(0.043,0.051),footprint);
        float pocketZip=HumRectMask(pocket-float2(0,0.041),float2(0.043,0.003),footprint);
        float seam=max(pocketEdge,pocketZip)*front;
        albedo*=1.0-0.58*seam;
        float stitching=0.65+0.35*sin((abs(tp.x)+tp.y)*1380.0)*HumDetailAttenuation(1900.0,footprint);
        float hem=HumLineMask(tp.y-0.967,0.004,footprint)*front;
        albedo*=1.0-0.28*hem*stitching;
        float button=1.0-smoothstep(0.005-footprint,0.005+footprint,
                                   length(float2(abs(tp.x)-0.066,tp.y-1.415)));
        button*=smoothstep(0.075,0.10,tp.z);
        albedo=lerp(albedo,float3(0.10,0.11,0.12),button);
        roughness=lerp(roughness,0.32,button);
    }
    else if (abs(material - HUM_MAT_LEG) < 0.5)
    {
        albedo = lerp(float3(0.018, 0.025, 0.032), float3(0.075, 0.095, 0.12), pose.seed);
        float sideSeam=HumLineMask(abs(p.x)-0.158,0.003,footprint);
        float denim=sin(p.y*610.0+p.x*430.0)*HumDetailAttenuation(750.0,footprint);
        albedo*=1.0-0.22*sideSeam+0.025*denim;
        roughness = 0.76;
    }
    else if (abs(material - HUM_MAT_SHOE) < 0.5)
    {
        albedo = lerp(float3(0.010, 0.012, 0.014), float3(0.12, 0.045, 0.022), seed2);
        float side=p.x<0.0?-1.0:1.0;
        float2 footCycle=HumFootCycle(pose.gait+(side>0.0?HUM_PI:0.0),pose.stride);
        float3 shoe=p-float3(side*0.100,0.053+0.075*footCycle.y*pose.walking,footCycle.x+0.065);
        float sole=1.0-smoothstep(-0.025-footprint,-0.025+footprint,shoe.y);
        float welt=HumLineMask(shoe.y+0.024,0.0025,footprint);
        albedo=lerp(albedo,float3(0.018,0.019,0.020),sole);
        albedo=lerp(albedo,float3(0.18,0.15,0.11),welt*0.65);
        float laceArea=HumRectMask(shoe.xz-float2(0,-0.015),float2(0.035,0.045),footprint)
                      *smoothstep(0.012,0.030,shoe.y);
        float laces=0.35+0.35*sin(shoe.z*620.0)*HumDetailAttenuation(620.0,footprint);
        albedo=lerp(albedo,float3(0.22,0.19,0.15),laceArea*laces);
        roughness = 0.58;
    }
    else if (abs(material - HUM_MAT_MOUTH) < 0.5)
    {
        albedo = float3(0.018, 0.0035, 0.0030);
        roughness = 0.50;
    }
}

void HumanMaterial(float3 worldPosition, float time, float3 cameraPosition,
                   float3 root, float3 forward, float scale,
                   float personId, float phase, float material,
                   out float3 albedo, out float roughness)
{
    float3 right, up, front;
    HumBasis(forward,right,up,front);
    float3 p=HumToLocal(worldPosition,root,right,up,front,scale);
    float3 cameraLocal=HumToLocal(cameraPosition,root,right,up,front,scale);
    HumanPose pose=HumanAnimate(time,personId,phase,cameraLocal);
    HumanMaterialLocal(p,pose,personId,material,0.0005,albedo,roughness);
}

HumanSurface HumanSurfacePrepared(float3 p,HumanPrepared context,float personId,float footprint)
{
    HumanSurface surface;
    HumanHit hit=HumanMapPrepared(p,context);
    surface.distance=hit.distance;surface.material=hit.material;
    surface.normal=HumanNormalPrepared(p,context,clamp(footprint*0.4,0.0004,0.002));
    HumanMaterialLocal(HumanPreparedLocal(p,context),context.pose,personId,hit.material,
                       footprint/context.scale,surface.albedo,surface.roughness);
    return surface;
}

// Full result for the final hit only.  The camera affects gaze, head attention,
// normal precision and hence the returned appearance, but no sampled assets are
// involved anywhere in the module.
HumanSurface HumanEvaluateSurface(float3 worldPosition, float time, float3 cameraPosition,
                                  float3 root, float3 forward, float scale,
                                  float personId, float phase)
{
    HumanSurface s;
    HumanHit h = HumanMap(worldPosition, time, cameraPosition, root, forward, scale, personId, phase);
    s.distance = h.distance;
    s.material = h.material;
    s.normal = HumanNormal(worldPosition, time, cameraPosition, root, forward, scale, personId, phase);
    HumanMaterial(worldPosition, time, cameraPosition, root, forward, scale,
                  personId, phase, h.material, s.albedo, s.roughness);
    return s;
}

#endif
