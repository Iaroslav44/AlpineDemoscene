"""CPU reference for the calibrated stance/swing IK; no GPU or motion assets.

Checks analytic flat/sloped ground, then measures the actual generated foot
vertices after skinning. These checks do not claim full dynamic simulation.
"""
import argparse
import hashlib
import json
from pathlib import Path
import numpy as np

ROOT=Path(__file__).resolve().parents[1]
TAU=2*np.pi
PERIOD=1.28

def unit(v):return v/max(np.linalg.norm(v),1e-12)
def rz(a):
    c,s=np.cos(a),np.sin(a);return np.array([[c,-s,0],[s,c,0],[0,0,1]])
def rx(a):
    c,s=np.cos(a),np.sin(a);return np.array([[1,0,0],[0,c,-s],[0,s,c]])
def align(a,b):
    a,b=unit(a),unit(b);v=np.cross(a,b);c=a@b
    skew=np.array([[0,-v[2],v[1]],[v[2],0,-v[0]],[-v[1],v[0],0]])
    return np.eye(3)+skew+skew@skew/max(1+c,1e-8)
def smooth(a,b,x):
    q=np.clip((x-a)/(b-a),0,1);return q*q*(3-2*q)
def path(actor,t):
    angle=t*TAU/128
    if actor==0:return np.array([1.2*np.sin(2*angle),1750+10*np.sin(angle)]),np.array([2.4*np.cos(2*angle),10*np.cos(angle)])*TAU/128
    bases=[[-2,1804],[-2,1737],[2,1768],[-1.7,1781],[2,1792],[-2,1804]]
    rate=2+actor%3;phase=angle*rate+actor*1.37
    return np.array(bases[actor])+[np.sin(phase)*.45,np.cos(phase)*4],np.array([np.cos(phase)*.45,-np.sin(phase)*4])*rate*TAU/128
def basis(actor,t):
    centre,velocity=path(actor,t);f=unit(np.array([velocity[0]+.0001,0,velocity[1]+.0001]));r=np.array([f[2],0,-f[0]])
    return centre,velocity,r,f
def height(p,terrain):
    p=np.asarray(p)
    if terrain=='flat':return np.zeros(p.shape[:-1])
    if terrain=='slope':return .03*p[...,0]+.01*p[...,1]
    return .03*np.sin(p[...,0]/3)+.04*np.sin(p[...,1]/5)
def scale(actor):return 1.02 if actor==0 else .94+.02*(actor%5)
def plant(rig,actor,t,side,terrain):
    centre,_,r,f=basis(actor,t);hip=rig[1 if side>0 else 2,:3]
    ankle=hip+rz(-side*np.pi/6)@(rig[7 if side>0 else 8,:3]-hip)
    xz=centre+(r[[0,2]]*ankle[0]+f[[0,2]]*ankle[2])*scale(actor)
    return np.array([xz[0],height(xz,terrain)+rig[24 if side>0 else 25,0]*scale(actor),xz[1]])
def target(rig,actor,t,side,walking,terrain):
    offset=actor*1.37/TAU+(0 if side>0 else .5);cycle=t/PERIOD+offset;fraction=cycle%1
    start=(np.floor(cycle)-offset)*PERIOD;s=np.clip((fraction-.62)/.38,0,1)
    a=plant(rig,actor,start+.31*PERIOD,side,terrain);b=plant(rig,actor,start+1.31*PERIOD,side,terrain)
    blend=s**3*(s*(s*6-15)+10);foot=a+(b-a)*blend
    foot[1]=height(foot[[0,2]],terrain)+scale(actor)*(rig[24 if side>0 else 25,0]+.075*np.sin(np.pi*s)**2*walking)
    return foot,s,fraction<.62
def pose(rig,actor,t,terrain):
    centre,velocity,r,f=basis(actor,t);root=np.array([centre[0],height(centre,terrain)+.025,centre[1]])
    walking=smooth(.015,.25,np.linalg.norm(velocity));gait=t*TAU/PERIOD+actor*1.37
    pelvis=np.array([.006*np.sin(gait)*walking,-.010-.004*(1-np.cos(2*gait))*walking,0])
    feet=[]
    for leg,side in enumerate([1,-1]):
        foot,swing,stance=target(rig,actor,t,side,walking,terrain);d=foot-root
        a=np.array([d@r,d[1],d@f])/scale(actor);h,k,end=rig[[1+leg,4+leg,7+leg],:3]
        reach=np.linalg.norm(k-h)+np.linalg.norm(end-k)-.005;horizontal=a[[0,2]]-h[[0,2]]-pelvis[[0,2]]
        pelvis[1]=min(pelvis[1],a[1]+np.sqrt(max(reach*reach-horizontal@horizontal,.01))-h[1]);feet.append((foot,swing,stance,a))
    rotations=np.tile(np.eye(3),(24,1,1));translations=np.tile(pelvis,(24,1));checks=[]
    for leg,side in enumerate([1,-1]):
        foot,swing,stance,goal=feet[leg];h0=rig[1+leg,:3];canonical=rz(-side*np.pi/6)
        k0=h0+canonical@(rig[4+leg,:3]-h0);a0=h0+canonical@(rig[7+leg,:3]-h0);h=h0+pelvis
        l1,l2=np.linalg.norm(k0-h0),np.linalg.norm(a0-k0);axis=unit(goal-h);reach=np.clip(np.linalg.norm(goal-h),abs(l1-l2)+.02,l1+l2-.002)
        a=h+axis*reach;along=(l1*l1-l2*l2+reach*reach)/(2*reach)
        k=h+axis*along+unit(np.array([0,0,1])-axis*axis[2])*np.sqrt(max(l1*l1-along*along,0))
        upper,lower=align(k0-h0,k-h),align(a0-k0,a-k)
        xz=foot[[0,2]];ground=unit(np.array([height(xz-[.04,0],terrain)-height(xz+[.04,0],terrain),.08,height(xz-[0,.04],terrain)-height(xz+[0,.04],terrain)]))
        ground=np.array([ground@r,ground[1],ground@f]);sole=align([0,1,0],ground)@rx(.10*np.sin(np.pi*swing)*walking)
        rotations[1+leg]=upper@canonical;translations[1+leg]=h-rotations[1+leg]@h0
        rotations[4+leg]=lower@canonical;translations[4+leg]=k+lower@(h0-k0)-rotations[4+leg]@h0
        for j in [7+leg,10+leg]:rotations[j]=sole@canonical;translations[j]=a+sole@(h0-a0)-rotations[j]@h0
        ground_point=foot.copy();ground_point[1]=height(foot[[0,2]],terrain);d=ground_point-root
        ground_point=np.array([d@r,d[1],d@f])/scale(actor)
        checks.append({'reach_error':float(np.linalg.norm(a-goal)),'length_error':float(max(abs(np.linalg.norm(k-h)-l1),abs(np.linalg.norm(a-k)-l2))),
                       'stance':stance,'target':foot,'plane':np.append(ground,ground@ground_point)})
    return rotations,translations,root,r,f,checks,pelvis

def main():
    ap=argparse.ArgumentParser();ap.add_argument('--cache',type=Path,default=ROOT/'build/neural_refined_qa_cache42');ap.add_argument('--output',type=Path,default=ROOT/'build/neural_locomotion_reference.json');args=ap.parse_args()
    rig=np.fromfile(args.cache/'200.rig',dtype='<f4').reshape(32,4).astype(float)
    vertices=np.fromfile(args.cache/'200.vertices',dtype='<f4').reshape(-1,16);points,indices=np.unique(vertices[:,:3],axis=0,return_index=True);a=vertices[indices]
    ids=a[:,8:12].copy().view('<u4');w=a[:,12:16];foot_weight=np.where(np.isin(ids,[7,8,10,11]),w,0).sum(1);keep=foot_weight>.5
    points,ids,w=points[keep],ids[keep],w[keep];dominant=np.where(np.where(np.isin(ids,[7,10]),w,0).sum(1)>.25,0,1)
    report={'schema':1,'kind':'Independent CPU analytic contact reference, not GPU execution','rig_sha256':hashlib.sha256((args.cache/'200.rig').read_bytes()).hexdigest(),
            'shader_sha256':hashlib.sha256((ROOT/'src/neural_resident.hlsli').read_bytes()).hexdigest(),'foot_vertices':len(points),'terrains':{}}
    for terrain in ['flat','slope','wave']:
        reach_error=length_error=orthogonality=loop_error=contact_correction=0.;sole_errors=[];raw_sole_errors=[];pelvis_min=0.;samples=0
        for actor in range(6):
            for t in np.linspace(0,128,257):
                rotation,translation,root,right,forward,checks,pelvis=pose(rig,actor,t,terrain)
                reach_error=max(reach_error,max(c['reach_error']for c in checks));length_error=max(length_error,max(c['length_error']for c in checks))
                orthogonality=max(orthogonality,float(np.abs(rotation@rotation.transpose(0,2,1)-np.eye(3)).max()));pelvis_min=min(pelvis_min,pelvis[1])
                p=(np.einsum('vkij,vj->vki',rotation[ids],points)+translation[ids])*w[:,:,None];p=p.sum(1)
                raw_world=root+(p[:,0,None]*right+p[:,1,None]*np.array([0,1,0])+p[:,2,None]*forward)*scale(actor)
                for leg in [0,1]:
                    mask=dominant==leg;plane=checks[leg]['plane'];correction=np.clip(plane[3]-p[mask]@plane[:3],0,.025)
                    contact_correction=max(contact_correction,float(correction.max()));p[mask]+=correction[:,None]*plane[:3]
                world=root+(p[:,0,None]*right+p[:,1,None]*np.array([0,1,0])+p[:,2,None]*forward)*scale(actor)
                for leg in [0,1]:
                    if checks[leg]['stance']:
                        subset=world[dominant==leg];sole_errors.append(float((subset[:,1]-height(subset[:,[0,2]],terrain)).min()))
                        subset=raw_world[dominant==leg];raw_sole_errors.append(float((subset[:,1]-height(subset[:,[0,2]],terrain)).min()))
                samples+=1
            p0=pose(rig,actor,0,terrain);p1=pose(rig,actor,128,terrain)
            loop_error=max(loop_error,float(np.abs(p0[0]-p1[0]).max()),float(np.abs(p0[1]-p1[1]).max()))
        report['terrains'][terrain]={'pose_samples':samples,'max_target_reach_error_metres':reach_error,'max_bone_length_error_metres':length_error,'rotation_orthogonality_error':orthogonality,
            'loop_transform_error':loop_error,'lowest_pelvis_offset_metres':pelvis_min,'max_contact_projection_metres':contact_correction,
            'before_projection_lowest_stance_sole_error_metres':min(raw_sole_errors),
            'actual_skinned_stance_sole_error_metres':{'minimum':min(sole_errors),'median':float(np.median(sole_errors)),'p95':float(np.quantile(sole_errors,.95)),'maximum':max(sole_errors)}}
    report['limits']=['Surface-derived bind landmarks approximate skeleton joints.','Contact IK is kinematic; no force, balance or muscle solver.','Sole measurements include learned skinning distortion; zero ankle-target error does not imply every foot vertex lies on the ground.']
    args.output.write_text(json.dumps(report,indent=2,allow_nan=False)+'\n');print(json.dumps(report,indent=2))
if __name__=='__main__':main()
