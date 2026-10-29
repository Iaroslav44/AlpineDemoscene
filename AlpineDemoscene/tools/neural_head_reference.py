"""Independent NumPy GANHead canonical geometry, normals and color reference."""
from __future__ import annotations
import argparse
import json
from pathlib import Path
import numpy as np
from neural_avatar_reference import ROOT, load_nav, adain, upsample, convolution, embed, sample_feature, softplus


def latent(tensors,seed):
    state=seed or 1;values=[]
    for _ in range(640):
        total=np.float32(0)
        for _ in range(12):
            state^=(state<<13)&0xffffffff;state^=state>>17;state^=(state<<5)&0xffffffff
            total=np.float32(total+np.float32((state>>8)/16777216-.5))
        values.append(total)
    mean=np.concatenate([tensors[f"latent.{kind}.mean"]for kind in("shape","detail","color")])
    std=np.concatenate([tensors[f"latent.{kind}.std"]for kind in("shape","detail","color")])
    return mean+np.asarray(values,np.float32)*std


def feature(tensors,codes):
    z=codes[:256]
    style=tensors["generator.lin_code.weight"]@z+tensors["generator.lin_code.bias"]
    h=adain(tensors["generator.shape_code"][0],style);h=np.maximum(h,h*.01)
    for layer in range(3):
        h=convolution(upsample(h),tensors[f"generator.enc{layer}.weight"],tensors[f"generator.enc{layer}.bias"])
        if layer<2:h=adain(h,tensors[f"generator.lin{layer}.weight"]@z+tensors[f"generator.lin{layer}.bias"])
        h=np.maximum(h,h*.01)
    return h


def geometry(tensors,volume,p):
    encoded=embed(p,4);h=np.concatenate((encoded,sample_feature(volume,p)),axis=1)
    for i in range(4):h=softplus(h@tensors[f"network.lin{i}.weight"].T+tensors[f"network.lin{i}.bias"])
    geom=h.copy();h=np.concatenate((h,encoded),axis=1)*np.float32(1/np.sqrt(2))
    return h@tensors["network.lin4.weight"].T+tensors["network.lin4.bias"],geom


def attributes(tensors,volume,p,codes):
    _,geom=geometry(tensors,volume,p);encoded=embed(p,6)
    h=np.concatenate((encoded,np.broadcast_to(codes[256:384],(len(p),128)),geom),axis=1)
    for i in range(9):
        if i==4:h=np.concatenate((h,encoded),axis=1)*np.float32(1/np.sqrt(2))
        h=h@tensors[f"norm_network.lin{i}.weight"].T+tensors[f"norm_network.lin{i}.bias"]
        if i<8:h=softplus(h)
        if i==7:normal_features=h.copy()
    normals=h/np.maximum(np.linalg.norm(h,axis=1,keepdims=True),1e-10)
    h=np.concatenate((encoded,np.broadcast_to(codes[384:640],(len(p),256)),np.zeros((len(p),65),np.float32),geom,normal_features),axis=1)
    for i in range(9):
        if i==4:h=np.concatenate((h,encoded),axis=1)*np.float32(1/np.sqrt(2))
        h=h@tensors[f"tex_network.lin{i}.weight"].T+tensors[f"tex_network.lin{i}.bias"]
        if i<8:h=softplus(h)
    color=np.clip(h*.5+.5,0,1)
    h=p
    for i in range(5):
        h=h@tensors[f"deformer.lbs_network.lin{i}.weight"].T+tensors[f"deformer.lbs_network.lin{i}.bias"]
        if i<4:h=softplus(h)
        if i==2:blend=h@tensors["deformer.lbs_network.blendshapes.weight"].T+tensors["deformer.lbs_network.blendshapes.bias"]
    ids=np.argsort(-h,axis=1)[:,:4];logits=np.take_along_axis(h,ids,axis=1)*20;w=np.exp(logits-logits[:,:1]);w/=w.sum(axis=1,keepdims=True)
    return normals,color,ids,w,blend


def main():
    ap=argparse.ArgumentParser();ap.add_argument("--seed",type=int,default=42);ap.add_argument("--reuse",action="store_true");ap.add_argument("--gpu-dir",type=Path);args=ap.parse_args()
    output=ROOT/"build/neural_head_reference";output.mkdir(exist_ok=True)
    tensors=load_nav(ROOT/"models/head/ganhead-faceverse.nah");codes=latent(tensors,args.seed)
    cache=output/f"feature-{args.seed}.npy"
    volume=np.load(cache)if args.reuse and cache.exists()else feature(tensors,codes);np.save(cache,volume)
    if not args.gpu_dir:
        # A coarse canonical volume for bounding-box/shape inspection only.
        n=65;x=np.linspace(-1,1,n,dtype=np.float32);z,y,xx=np.meshgrid(x,x,x,indexing="ij");p=np.stack((xx,y,z),axis=-1).reshape(-1,3)
        occ=np.concatenate([geometry(tensors,volume,p[i:i+1024])[0][:,0]for i in range(0,len(p),1024)])
        np.save(output/f"field-{args.seed}.npy",occ.reshape(n,n,n));inside=p[occ>0]
        print(json.dumps({"seed":args.seed,"bounds_min":inside.min(axis=0).tolist(),"bounds_max":inside.max(axis=0).tolist(),"positive_fraction":float(np.mean(occ>0))},indent=2))
    else:
        import hashlib
        read=lambda name:np.fromfile(args.gpu_dir/(name+".f32"),"<f4")
        fingerprint=lambda path:hashlib.file_digest(Path(path).open("rb"),"sha256").hexdigest()
        model=ROOT/"models/head/ganhead-faceverse.nah"
        report={"seed":args.seed,"model_sha256":fingerprint(model),"model_bytes":model.stat().st_size,"gpu_dir":str(args.gpu_dir.resolve())}
        report["gpu_dump_sha256"]={name:fingerprint(args.gpu_dir/(name+".f32"))for name in("latent","feature","field","positions","attributes","motion")}
        metrics_path=args.gpu_dir/"neural_head_metrics.json"
        if metrics_path.is_file():
            report["gpu_metrics_sha256"]=fingerprint(metrics_path)
            report["gpu_metrics"]=json.loads(metrics_path.read_text())
        report["latent_max_abs_error"]=float(np.max(np.abs(read("latent")-codes)))
        report["feature_max_abs_error"]=float(np.max(np.abs(read("feature").reshape(volume.shape)-volume)))
        field=read("field");sample=np.linspace(0,len(field)-1,1024,dtype=int)
        points=np.stack((sample%81,(sample//81)%97,sample//(81*97)),axis=1).astype(np.float32)
        points=points*np.array([2/80,2/96,2/80],np.float32)-1
        occupancy,_=geometry(tensors,volume,points)
        report["occupancy_max_abs_error"]=float(np.max(np.abs(field[sample]-occupancy[:,0])))
        pos=read("positions").reshape(-1,3);ids=np.linspace(0,len(pos)-1,min(1024,len(pos)),dtype=int)
        nn,cc,jj,ww,blend=attributes(tensors,volume,pos[ids],codes);actual=read("attributes").reshape(-1,32)[ids]
        report["normal_max_abs_error"]=float(np.max(np.abs(nn-actual[:,:3])))
        report["color_max_abs_error"]=float(np.max(np.abs(cc-actual[:,12:15])))
        report["joint_ids_equal"]=bool(np.array_equal(jj,actual[:,4:8].astype(np.uint32)))
        report["weights_max_abs_error"]=float(np.max(np.abs(ww-actual[:,8:12])))
        expected_morph=np.einsum("mj,ncj->nmc",tensors["motion.expression_basis"],blend[:,108:].reshape(-1,3,50))
        actual_morph=actual[:,16:].reshape(-1,4,4)[:,:,:3]
        report["morph_max_abs_error"]=float(np.max(np.abs(expected_morph-actual_morph)))
        report["motion_max_abs_error"]=float(np.max(np.abs(read("motion").reshape(-1,8)-tensors["motion.frames"])))
        report["passed"]=bool(report["latent_max_abs_error"]<1e-5 and report["feature_max_abs_error"]<.002 and report["occupancy_max_abs_error"]<.002 and report["normal_max_abs_error"]<.005 and report["color_max_abs_error"]<.005 and report["weights_max_abs_error"]<.002 and report["morph_max_abs_error"]<.002 and report["joint_ids_equal"] and report["motion_max_abs_error"]==0)
        (output/f"report-{args.seed}.json").write_text(json.dumps(report,indent=2)+"\n");print(json.dumps(report,indent=2))
        if not report["passed"]:raise SystemExit(1)


if __name__=="__main__":main()
