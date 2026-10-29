"""Quantify the CPU-only before/after neural mesh refinement experiment."""
import argparse
import hashlib
import json
from pathlib import Path
import numpy as np

ROOT=Path(__file__).resolve().parents[1]

def sha(path):
    with path.open('rb')as f:return hashlib.file_digest(f,'sha256').hexdigest()

def measurements(p,a,t,edges,joints):
    cross=np.cross(p[t[:,1]]-p[t[:,0]],p[t[:,2]]-p[t[:,0]])
    double_area=np.linalg.norm(cross,axis=1)
    n=a[:,:3];n=n/np.maximum(np.linalg.norm(n,axis=1,keepdims=True),1e-12)
    lengths=np.linalg.norm(p[edges[:,0]]-p[edges[:,1]],axis=1)
    lap=np.zeros_like(p);degree=np.zeros(len(p),np.float32)
    np.add.at(lap,edges[:,0],p[edges[:,1]]-p[edges[:,0]])
    np.add.at(lap,edges[:,1],p[edges[:,0]]-p[edges[:,1]])
    np.add.at(degree,edges[:,0],1);np.add.at(degree,edges[:,1],1)
    curvature=np.linalg.norm(lap/np.maximum(degree[:,None],1),axis=1)
    weights=np.zeros((len(p),joints),np.float32)
    for k in range(4):np.add.at(weights,(np.arange(len(p)),a[:,4+k].astype(int)),a[:,8+k])
    variation=np.abs(weights[edges[:,0]]-weights[edges[:,1]]).sum(axis=1)
    angle=np.degrees(np.arccos(np.clip((n[edges[:,0]]*n[edges[:,1]]).sum(axis=1),-1,1)))
    return {'finite':bool(np.isfinite(p).all()and np.isfinite(a).all()),'surface_area':float(double_area.sum()*.5),
        'signed_volume':float(np.einsum('ij,ij->i',p[t[:,0]],cross).sum()/6),
        'degenerate_triangles':int((double_area<1e-12).sum()),
        'bounds_min':p.min(axis=0).tolist(),'bounds_max':p.max(axis=0).tolist(),
        'edge_length_median':float(np.median(lengths)),
        'laplacian_length_mean':float(curvature.mean()),'laplacian_length_p95':float(np.quantile(curvature,.95)),
        'laplacian_length_p99':float(np.quantile(curvature,.99)),
        'neighbour_normal_angle_degrees_mean':float(angle.mean()),'neighbour_normal_angle_degrees_p95':float(np.quantile(angle,.95)),
        'neighbour_weight_l1_mean':float(variation.mean()),'neighbour_weight_l1_p95':float(np.quantile(variation,.95)),
        'weight_sum_max_error':float(np.abs(weights.sum(axis=1)-1).max())}

def main():
    ap=argparse.ArgumentParser();ap.add_argument('directory',type=Path);args=ap.parse_args();d=args.directory
    native=json.loads((d/'native.json').read_text());head=native['kind']=='head';stride=32 if head else 12;joints=5 if head else 24
    t=np.fromfile(d/'indices.u32',dtype='<u4').reshape(-1,3)
    edges=np.unique(np.sort(np.concatenate((t[:,[0,1]],t[:,[1,2]],t[:,[2,0]])),axis=1),axis=0)
    stages={};data={}
    for stage in('before','after'):
        p=np.fromfile(d/(stage+'.positions.f32'),dtype='<f4').reshape(-1,3);a=np.fromfile(d/(stage+'.attributes.f32'),dtype='<f4').reshape(-1,stride)
        data[stage]=p;stages[stage]=measurements(p,a,t,edges,joints)
    displacement=np.linalg.norm(data['after']-data['before'],axis=1)*native['scale']
    before_cross=np.cross(data['before'][t[:,1]]-data['before'][t[:,0]],data['before'][t[:,2]]-data['before'][t[:,0]])
    after_cross=np.cross(data['after'][t[:,1]]-data['after'][t[:,0]],data['after'][t[:,2]]-data['after'][t[:,0]])
    reliable=np.linalg.norm(before_cross,axis=1)>1e-10
    report={'schema':1,'native':native,'before':stages['before'],'after':stages['after'],
        'displacement_metres':{'mean':float(displacement.mean()),'p95':float(np.quantile(displacement,.95)),'maximum':float(displacement.max())},
        'relative_signed_volume_change':(stages['after']['signed_volume']/stages['before']['signed_volume'])-1,
        'flipped_original_triangle_normals':int(((before_cross*after_cross).sum(axis=1)[reliable]<0).sum()),
        'source_sha256':{p:sha(ROOT/p)for p in('src/neural_avatar_runtime.cpp','src/neural_mesh_cleanup.h','tools/neural_geometry_probe.cpp','tools/neural_geometry_metrics.py')},
        'data_sha256':{p.name:sha(p)for p in d.glob('*.f32')},
        'limitations':['One seed; numerical smoothness is not anatomy or photorealism.',
                      'Attributes were inferred at refined coordinates.' if native['attributes_resampled_at_new_positions'] else 'CPU experiment reuses original learned attributes; final runtime resamples them at refined geometry.',
                      'No new fingers, eyes or teeth are invented.']}
    (d/'report.json').write_text(json.dumps(report,indent=2,allow_nan=False)+'\n')
    print(json.dumps(report,indent=2))
if __name__=='__main__':main()
