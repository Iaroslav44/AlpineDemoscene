"""Export pretrained GANHead neural parameters; excludes every FLAME template.

The public author checkpoint is read with the same strict non-executing parser
as gDNA. This is a local research export, not a claim of redistribution rights.
"""
from __future__ import annotations
import argparse
import collections
import io
import json
from pathlib import Path
import re
import struct
import urllib.parse
import urllib.request
import zipfile
import zlib
import numpy as np
from neural_avatar_export import RestrictedCheckpointReader, TensorDescriptor, digest, write_nav

ROOT=Path(__file__).resolve().parents[1]
SOURCE_ID="1ztHGU9GdCoMkAlQB7ynoztIFewVaILlQ"
SOURCE_HASH="03ef6010ee1b2a81d64c0728d32b578eb1170a05aabc672a4b2f60a5d10e86ce"
SOURCE_BYTES=82158734
SOURCE_MEMBER="model_and_data/stage2_model/checkpoints/last.ckpt"
MOTION_HASH="80a048a1abc7340612e84691e358cc8723d1c9091234e0623713a06c78254a76"


def download(path):
    if path.is_file() and path.stat().st_size==SOURCE_BYTES and digest(path)==SOURCE_HASH:return
    path.parent.mkdir(parents=True,exist_ok=True)
    # Google's ordinary large-file download confirmation is public and does not
    # require login or acceptance of a dataset agreement.
    page=urllib.request.urlopen(f"https://drive.google.com/uc?export=download&id={SOURCE_ID}").read().decode()
    match=re.search(r'name="uuid" value="([^"]+)"',page)
    if not match:raise RuntimeError("Public checkpoint download form changed")
    url="https://drive.usercontent.google.com/download?"+urllib.parse.urlencode({"id":SOURCE_ID,"export":"download","confirm":"t","uuid":match.group(1)})
    offset=216442180
    response=urllib.request.urlopen(urllib.request.Request(url,headers={"Range":f"bytes={offset}-{offset+511}"}))
    if response.status!=206:raise RuntimeError("Server did not honour Range")
    raw=response.read();header=struct.unpack("<4s5H3L2H",raw[:30])
    if header[0]!=b"PK\x03\x04" or raw[30:30+header[9]].decode()!=SOURCE_MEMBER or header[3]!=8:
        raise RuntimeError("Public checkpoint archive changed")
    start=offset+30+header[9]+header[10];length=header[7]
    response=urllib.request.urlopen(urllib.request.Request(url,headers={"Range":f"bytes={start}-{start+length-1}"}))
    if response.status!=206:raise RuntimeError("Server did not honour Range")
    decoder=zlib.decompressobj(-15);temporary=path.with_suffix(".download")
    with temporary.open("wb") as output:
        while chunk:=response.read(1024*1024):output.write(decoder.decompress(chunk))
        output.write(decoder.flush())
    if not decoder.eof or temporary.stat().st_size!=SOURCE_BYTES or digest(temporary)!=SOURCE_HASH:
        raise RuntimeError("Pinned checkpoint checksum mismatch")
    temporary.replace(path)


def download_motion(path):
    """Range-fetch only the author's fitted numeric motion, never its images."""
    if path.is_file() and digest(path)==MOTION_HASH:return
    page=urllib.request.urlopen(f"https://drive.google.com/uc?export=download&id={SOURCE_ID}").read().decode()
    match=re.search(r'name="uuid" value="([^"]+)"',page)
    if not match:raise RuntimeError("Public checkpoint download form changed")
    url="https://drive.usercontent.google.com/download?"+urllib.parse.urlencode({"id":SOURCE_ID,"export":"download","confirm":"t","uuid":match.group(1)})
    def fetch(start,end=None):
        value=f"bytes={start}-{end}"if end is not None else f"bytes={start}"
        response=urllib.request.urlopen(urllib.request.Request(url,headers={"Range":value}))
        if response.status!=206:raise RuntimeError("Server did not honour Range")
        return response.read()
    tail=fetch("-65536")
    offset=tail.rfind(b"PK\x05\x06")
    if offset<0:raise RuntimeError("ZIP central directory missing")
    end=struct.unpack_from("<4s4H2LH",tail,offset)
    directory=fetch(end[6],end[6]+end[5]-1)
    entries=[];cursor=0
    while cursor<len(directory):
        header=struct.unpack_from("<4s6H3L5H2L",directory,cursor)
        name=directory[cursor+46:cursor+46+header[10]].decode()
        if name.startswith("model_and_data/yufeng_1812/seqs/")and name.endswith(".npy"):
            entries.append({"name":name,"compressed":header[8],"offset":header[16],"crc32":header[7]})
        cursor+=46+header[10]+header[11]+header[12]
    if len(entries)!=1825:raise RuntimeError("Published motion member count changed")
    entries.sort(key=lambda entry:int(Path(entry["name"]).stem))
    lo=min(entry["offset"]for entry in entries)
    hi=max(entry["offset"]+30+len(entry["name"])+100+entry["compressed"]for entry in entries)
    raw=fetch(lo,hi-1);frames=[]
    for entry in entries:
        local=entry["offset"]-lo;header=struct.unpack_from("<4s5H3L2H",raw,local)
        start=local+30+header[9]+header[10]
        payload=zlib.decompress(raw[start:start+entry["compressed"]],-15)
        if zlib.crc32(payload)!=entry["crc32"]:raise RuntimeError("Motion member CRC mismatch")
        frame=np.load(io.BytesIO(payload),allow_pickle=False)
        if frame.shape!=(169,)or not np.isfinite(frame).all():raise RuntimeError("Invalid motion frame")
        frames.append(frame)
    path.parent.mkdir(parents=True,exist_ok=True)
    temporary=path.with_suffix(".download")
    with temporary.open("wb")as stream:np.save(stream,np.asarray(frames,dtype="<f4"))
    if digest(temporary)!=MOTION_HASH:raise RuntimeError("Pinned numeric motion checksum mismatch")
    temporary.replace(path)


def read(path):
    if digest(path)!=SOURCE_HASH:raise ValueError("Pinned source checksum mismatch")
    result=collections.OrderedDict()
    prefixes=("network.","generator.","norm_network.","tex_network.","deformer.lbs_network.","deformer.disp_network.","z_shapes.","z_details.","z_colors.")
    with zipfile.ZipFile(path) as archive:
        source=RestrictedCheckpointReader(io.BytesIO(archive.read("archive/data.pkl"))).load()["state_dict"]
        for name,descriptor in source.items():
            if not name.startswith(prefixes):continue
            if not isinstance(descriptor,TensorDescriptor) or descriptor.storage[1]!="FloatStorage":raise ValueError(name)
            raw=archive.read("archive/data/"+descriptor.storage[2])
            tensor=np.ndarray(descriptor.shape,dtype="<f4",buffer=raw,offset=descriptor.offset*4,strides=tuple(x*4 for x in descriptor.stride)).copy()
            if not np.isfinite(tensor).all():raise ValueError(name)
            result[name]=tensor
    return result


def export(state):
    output=collections.OrderedDict()
    for name,value in state.items():
        if name.startswith("z_") or name.endswith(".weight_g") or name.startswith("generator.lin2."):continue
        if name.endswith(".weight_v"):
            value=value*(state[name[:-8]+"weight_g"]/np.sqrt(np.sum(value*value,axis=tuple(range(1,value.ndim)),keepdims=True)))
            name=name[:-8]+"weight"
        output[name]=np.asarray(value,dtype="<f4")
    for source,target in (("z_shapes.weight","shape"),("z_details.weight","detail"),("z_colors.weight","color")):
        output[f"latent.{target}.mean"]=state[source].mean(axis=0,dtype=np.float32)
        output[f"latent.{target}.std"]=state[source].std(axis=0,ddof=1,dtype=np.float32)
    return output


def add_motion(tensors,path):
    if digest(path)!=MOTION_HASH:raise ValueError("Pinned motion checksum mismatch")
    frames=np.load(path,allow_pickle=False)
    if frames.shape!=(1825,169)or not np.isfinite(frames).all():raise ValueError("Unexpected motion array")
    expression=frames[:,-50:]
    mean=expression.mean(axis=0,dtype=np.float32)
    centered=expression-mean
    _,singular,basis=np.linalg.svd(centered,full_matrices=False)
    basis=basis[:4].copy()
    for row in basis:
        if row[np.argmax(np.abs(row))]<0:row*=-1
    coefficients=centered@basis.T
    motion=np.zeros((len(frames),8),np.float32);motion[:,:4]=coefficients
    motion[:,4:7]=frames[:,10:13]-np.array([.2,0,0],np.float32)
    # Endpoint retiming changes only the transition; the interior is the actual
    # projected captured expression sequence. Identity-fitting mean is omitted.
    center=(motion[0]+motion[-1])*.5
    for i in range(24):
        t=np.float32(i/23);t=t*t*(3-2*t)
        motion[i]=center*(1-t)+motion[i]*t
        motion[-1-i]=center*(1-t)+motion[-1-i]*t
    weight=tensors["deformer.lbs_network.blendshapes.weight"][108:].reshape(3,50,128)
    bias=tensors["deformer.lbs_network.blendshapes.bias"][108:].reshape(3,50)
    tensors["morph.expression.weight"]=np.einsum("mj,cjk->mck",basis,weight).reshape(12,128).astype(np.float32)
    tensors["morph.expression.bias"]=np.einsum("mj,cj->mc",basis,bias).reshape(12).astype(np.float32)
    tensors["motion.expression_basis"]=basis.astype(np.float32)
    tensors["motion.expression_mean"]=mean
    tensors["motion.frames"]=motion
    tensors["motion.duration"]=np.array([128.0],np.float32)
    return {"source":"IMavatar yufeng_1812 fitted sequence distributed with GANHead", "source_numeric_array_sha256":MOTION_HASH,"frames":len(frames),"pca_modes":4,"retained_expression_variance":float(np.sum(singular[:4]**2)/np.sum(singular**2)),"endpoint_blend_frames":24,"playback_seconds":128,"interpretation":"Centered captured expression variations projected onto four PCA modes; source identity-fitting mean omitted; no invented semantic meaning assigned to PCA modes","jaw":"relative axis-angle stored separately; not included in expression PCA"}


def main():
    ap=argparse.ArgumentParser();ap.add_argument("--checkpoint",type=Path,default=ROOT/"build/neural_source/ganhead-stage2.ckpt");ap.add_argument("--motion",type=Path,default=ROOT/"build/neural_source/ganhead-motion.npy");ap.add_argument("--output",type=Path,default=ROOT/"models/head/ganhead-faceverse.nah");ap.add_argument("--download",action="store_true");args=ap.parse_args()
    if args.download:
        download(args.checkpoint)
        download_motion(args.motion)
    tensors=export(read(args.checkpoint));motion=add_motion(tensors,args.motion);entries=write_nav(args.output,tensors,magic=b"NAH1")
    manifest={"schema":1,"model":"GANHead FaceVerse pretrained stage2 (CVPR2023)","source_repository":"https://github.com/wsj-sjtu/GANHead","source_repository_commit":"76c98ce18f940caf6aec4cf620df8f8d2bc788b6","source_checkpoint_url":f"https://drive.google.com/file/d/{SOURCE_ID}/view","source_checkpoint_member":SOURCE_MEMBER,"source_checkpoint_sha256":SOURCE_HASH,"source_checkpoint_bytes":SOURCE_BYTES,"training_data":"FaceVerse textured scans of real people","license_status":"No explicit code/weights license found in the public repository or model archive; local research evaluation only; redistribution rights not established","resource_id_candidate":202,"path":args.output.relative_to(ROOT).as_posix(),"bytes":args.output.stat().st_size,"sha256":digest(args.output),"magic_hex":"4e414831","export":"Learned inference tensors only; no FLAME template vertices, faces, regressors or landmark tables; no photographs, scans or training-example latent tables","runtime_input":"shape latent256, detail latent128, color latent256, 65 pose/expression controls, 3D coordinates","limitations":["Not integrated into the executable yet","Surface color is learned RGB, not independently verified relightable PBR albedo","Face animation requires evaluating learned blendshape fields and consistent controls"],"tensors":entries}
    manifest["resource_id"]=manifest.pop("resource_id_candidate")
    manifest["runtime_input"]="Seed-derived shape256/detail128/color256 latent codes and 3D coordinates; canonical appearance uses zero pose controls; four captured-expression PCA curves deform the generated surface each frame"
    manifest["limitations"]=["Cinematic photorealism is not established by numerical graph validation", "Surface color is learned RGB, not independently verified relightable PBR albedo", "Four expression modes retain 86.2354% of source variation; canonical normals are not corrected per expression", "Accurate jaw/eye transforms and physical facial tissues are not implemented"]
    manifest["motion"]=motion
    args.output.with_suffix(".json").write_text(json.dumps(manifest,indent=2)+"\n",encoding="utf-8")
    print(json.dumps({key:manifest[key]for key in("model","bytes","sha256","license_status")},indent=2))


if __name__=="__main__":main()
