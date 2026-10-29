"""Independent NumPy implementation of the exported gDNA inference graph.

Used only for numeric verification; the Windows demo executes its own D3D11
decoder. Files written by this tool live in ignored build/ and are not assets.
"""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import struct
import time
import numpy as np

ROOT = Path(__file__).resolve().parents[1]


def load_nav(path):
    raw = Path(path).read_bytes()
    magic, version, count, _ = struct.unpack_from("<4s3I", raw)
    if magic not in (b"NAV1", b"NAH1") or version != 1:
        raise ValueError("NAV1/NAH1 expected")
    tensors = {}
    for i in range(count):
        values = struct.unpack_from("<80s12I", raw, 16 + 128 * i)
        name = values[0].split(b"\0")[0].decode()
        rank, shape = values[1], values[2:7]
        offset, length, kind = values[7:10]
        if kind != 1 or offset + length > len(raw):
            raise ValueError("Invalid tensor")
        tensors[name] = np.frombuffer(raw, "<f4", length // 4, offset).reshape(shape[:rank]).copy()
    return tensors


def latent(tensors, seed):
    state = seed or 1
    values = []
    for _ in range(128):
        total = np.float32(0)
        for _ in range(12):
            state ^= (state << 13) & 0xffffffff
            state ^= state >> 17
            state ^= (state << 5) & 0xffffffff
            total = np.float32(total + np.float32((state >> 8) / 16777216 - .5))
        values.append(total)
    mean = np.concatenate((tensors["latent.shape.mean"], tensors["latent.detail.mean"]))
    std = np.concatenate((tensors["latent.shape.std"], tensors["latent.detail.std"]))
    return mean + np.asarray(values, np.float32) * std


def adain(feature, style):
    mean = feature.mean(axis=(1,2,3), keepdims=True)
    variance = feature.var(axis=(1,2,3), ddof=1, keepdims=True)
    channels = len(feature)
    return (feature-mean)/np.sqrt(variance+np.float32(1e-5))*style[channels:,None,None,None]+style[:channels,None,None,None]


def upsample(feature):
    result = feature
    for axis in (1,2,3):
        old = result.shape[axis]
        position = np.linspace(0, old-1, old*2, dtype=np.float32)
        lo = np.floor(position).astype(np.int32)
        hi = np.minimum(lo+1,old-1)
        fshape = [1]*4
        fshape[axis] = old*2
        fraction = (position-lo).astype(np.float32).reshape(fshape)
        result = np.take(result,lo,axis=axis)*(1-fraction)+np.take(result,hi,axis=axis)*fraction
    return result


def convolution(feature, weight, bias):
    channels, depth, height, width = feature.shape
    padded = np.pad(feature, ((0,0),(1,1),(1,1),(1,1)))
    result = np.broadcast_to(bias[:,None], (len(bias),depth*height*width)).copy()
    for z in range(3):
        for y in range(3):
            for x in range(3):
                patch = padded[:,z:z+depth,y:y+height,x:x+width].reshape(channels,-1)
                result += weight[:,:,z,y,x] @ patch
    return result.reshape(len(bias),depth,height,width)


def generate_feature(tensors, codes):
    z = codes[:64]
    style = tensors["generator.lin_code.weight"] @ z + tensors["generator.lin_code.bias"]
    feature = adain(tensors["generator.shape_code"][0], style)
    feature = np.maximum(feature, feature*np.float32(.01))
    for layer in range(3):
        start=time.perf_counter()
        feature=upsample(feature)
        feature=convolution(feature,tensors[f"generator.enc{layer}.weight"],tensors[f"generator.enc{layer}.bias"])
        if layer<2:
            style=tensors[f"generator.lin{layer}.weight"] @ z+tensors[f"generator.lin{layer}.bias"]
            feature=adain(feature,style)
        feature=np.maximum(feature,feature*np.float32(.01))
        print(f"feature stage {layer}: {feature.shape}, {time.perf_counter()-start:.2f}s",flush=True)
    return feature


def sample_feature(feature, positions):
    channels, depth, height, width=feature.shape
    p=(positions*np.float32(.5)+np.float32(.5))*np.array([width-1,height-1,depth-1],np.float32)
    lo=np.floor(p).astype(np.int32)
    fraction=p-lo
    values=np.zeros((len(p),channels),np.float32)
    for z in range(2):
        for y in range(2):
            for x in range(2):
                q=lo+np.array([x,y,z]);mask=np.all(q>=0,axis=1)&np.all(q<np.array([width,height,depth]),axis=1)
                w=(fraction[:,0] if x else 1-fraction[:,0])*(fraction[:,1] if y else 1-fraction[:,1])*(fraction[:,2] if z else 1-fraction[:,2])
                qq=q[mask]
                values[mask]+=feature[:,qq[:,2],qq[:,1],qq[:,0]].T*w[mask,None]
    return values


def embed(p, levels):
    return np.concatenate([p]+[f(p*np.float32(2**level)) for level in range(levels) for f in (np.sin,np.cos)],axis=1)


def softplus(x):
    # Identical threshold and beta to the checkpoint implementation.
    return np.where(x>.2,x,np.log1p(np.exp(np.clip(x*100,-80,20)))*np.float32(.01))


def geometry(tensors, feature, positions):
    p=positions.copy();p[:,1]+=np.float32(.28);p[:,2]*=4
    encoded=embed(p,4)
    hidden=np.concatenate((encoded,sample_feature(feature,p)),axis=1)
    for layer in range(4):
        hidden=softplus(hidden@tensors[f"network.lin{layer}.weight"].T+tensors[f"network.lin{layer}.bias"])
    detail_features=hidden.copy()
    hidden=np.concatenate((hidden,encoded),axis=1)*np.float32(1/np.sqrt(2))
    return hidden@tensors["network.lin4.weight"].T+tensors["network.lin4.bias"],detail_features


def attributes(tensors, feature, positions, codes):
    _,detail=geometry(tensors,feature,positions)
    encoded=embed(positions,6)
    hidden=np.concatenate((encoded,np.broadcast_to(codes[64:],(len(positions),64)),detail),axis=1)
    for layer in range(9):
        if layer==4:hidden=np.concatenate((hidden,encoded),axis=1)*np.float32(1/np.sqrt(2))
        hidden=hidden@tensors[f"norm_network.lin{layer}.weight"].T+tensors[f"norm_network.lin{layer}.bias"]
        if layer<8:hidden=softplus(hidden)
    normals=hidden/np.maximum(np.linalg.norm(hidden,axis=1,keepdims=True),1e-10)
    hidden=np.concatenate((positions,np.broadcast_to(codes[:64],(len(positions),64))),axis=1)
    for layer in range(5):
        hidden=hidden@tensors[f"deformer.lbs_network.lin{layer}.weight"].T+tensors[f"deformer.lbs_network.lin{layer}.bias"]
        if layer<4:hidden=softplus(hidden)
    indices=np.argsort(-hidden,axis=1)[:,:4]
    logits=np.take_along_axis(hidden,indices,axis=1)*20
    weights=np.exp(logits-logits[:,:1]);weights/=weights.sum(axis=1,keepdims=True)
    return normals,indices,weights


def main():
    ap=argparse.ArgumentParser()
    ap.add_argument("--model",type=Path,default=ROOT/"models/avatar/gdna-thuman.nav")
    ap.add_argument("--output",type=Path,default=ROOT/"build/neural_reference")
    ap.add_argument("--gpu-dir",type=Path)
    ap.add_argument("--seed",type=int,default=42)
    ap.add_argument("--reuse",action="store_true")
    args=ap.parse_args();args.output.mkdir(parents=True,exist_ok=True)
    tensors=load_nav(args.model);codes=latent(tensors,args.seed)
    cache=args.output/f"feature-{args.seed}.npy"
    feature=np.load(cache) if args.reuse and cache.exists() else generate_feature(tensors,codes)
    np.save(cache,feature)
    points=np.random.default_rng(721).uniform([-1,-1.3,-.35],[1,.9,.35],(256,3)).astype(np.float32)
    occ,_=geometry(tensors,feature,points)
    fingerprint=lambda path:hashlib.file_digest(Path(path).open("rb"),"sha256").hexdigest()
    report={"seed":args.seed,"model_sha256":fingerprint(args.model),"model_bytes":args.model.stat().st_size,"feature_shape":list(feature.shape),"feature_finite":bool(np.isfinite(feature).all()),"feature_min":float(feature.min()),"feature_max":float(feature.max()),"occupancy_min":float(occ.min()),"occupancy_max":float(occ.max())}
    np.savez(args.output/f"reference-{args.seed}.npz",latent=codes,points=points,occupancy=occ)
    if args.gpu_dir:
        report["gpu_dir"]=str(args.gpu_dir.resolve())
        report["gpu_dump_sha256"]={name:fingerprint(args.gpu_dir/(name+".f32")) for name in ("latent","feature","field","positions","attributes")}
        metrics_path=args.gpu_dir/"neural_avatar_metrics.json"
        if metrics_path.is_file():
            report["gpu_metrics_sha256"]=fingerprint(metrics_path)
            report["gpu_metrics"]=json.loads(metrics_path.read_text())
        gpu=lambda name:np.fromfile(args.gpu_dir/(name+".f32"),dtype="<f4")
        report["latent_max_abs_error"]=float(np.max(np.abs(gpu("latent")-codes)))
        actual=gpu("feature").reshape(feature.shape)
        report["feature_max_abs_error"]=float(np.max(np.abs(actual-feature)))
        report["feature_rms_error"]=float(np.sqrt(np.mean((actual-feature)**2)))
        field=gpu("field");ids=np.linspace(0,len(field)-1,1024,dtype=int)
        p=np.stack((ids%65,(ids//65)%129,ids//(65*129)),axis=1).astype(np.float32)
        p=p*np.array([2/64,2.2/128,.7/48],np.float32)+np.array([-1,-1.3,-.35],np.float32)
        expected,_=geometry(tensors,feature,p)
        report["occupancy_max_abs_error"]=float(np.max(np.abs(field[ids]-expected[:,0])))
        positions=gpu("positions").reshape(-1,3);ids=np.linspace(0,len(positions)-1,min(1024,len(positions)),dtype=int)
        nn,jj,ww=attributes(tensors,feature,positions[ids],codes)
        actual=gpu("attributes").reshape(-1,12)[ids]
        report["normal_max_abs_error"]=float(np.max(np.abs(actual[:,:3]-nn)))
        actual_ids=actual[:,4:8].astype(np.uint32)
        report["joint_ids_equal"]=bool(np.array_equal(actual_ids,jj))
        report["weights_max_abs_error"]=float(np.max(np.abs(actual[:,8:12]-ww)))
        # Near-zero/tied influences may exchange order after FP32 rounding.
        # Compare their actual distribution over the 24 named joints instead.
        reference_weights=np.zeros((len(ids),24),np.float32)
        actual_weights=np.zeros_like(reference_weights)
        rows=np.arange(len(ids))[:,None]
        reference_weights[rows,jj]=ww
        actual_weights[rows,actual_ids]=actual[:,8:12]
        report["joint_distribution_max_abs_error"]=float(np.max(np.abs(reference_weights-actual_weights)))
        report["passed"]=bool(report["latent_max_abs_error"]<1e-5 and report["feature_max_abs_error"]<.002 and report["occupancy_max_abs_error"]<.002 and report["normal_max_abs_error"]<.005 and report["joint_distribution_max_abs_error"]<.002)
    (args.output/f"report-{args.seed}.json").write_text(json.dumps(report,indent=2)+"\n")
    print(json.dumps(report,indent=2))
    if report.get("passed") is False:raise SystemExit(1)


if __name__=="__main__":main()
