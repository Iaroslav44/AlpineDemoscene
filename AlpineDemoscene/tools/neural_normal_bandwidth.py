"""CPU-only normal-bandwidth diagnostic; never installs this QA cache as an asset."""
import argparse
import heapq
import hashlib
import json
from pathlib import Path
import shutil
import time
import numpy as np

def main():
    ap=argparse.ArgumentParser();ap.add_argument('--cache',type=Path,default=Path('build/neural_refined_qa_cache42'));ap.add_argument('--geometry',type=Path,default=Path('build/neural_refined_body_cpu'));ap.add_argument('--out',type=Path,default=Path('build/neural_geodesic_normal_qa'));ap.add_argument('--radius',type=float,default=.025);ap.add_argument('--compare-native',type=Path);args=ap.parse_args()
    start=time.perf_counter();p=np.fromfile(args.geometry/'after.positions.f32','<f4').reshape(-1,3)
    n=np.fromfile(args.geometry/'after.geometric_normals.f32','<f4').reshape(-1,3)
    attrs=np.fromfile(args.geometry/'after.attributes.f32','<f4').reshape(-1,12)
    triangles=np.fromfile(args.geometry/'indices.u32','<u4').reshape(-1,3);normal=n.copy()
    edges=np.unique(np.sort(np.concatenate([triangles[:,[0,1]],triangles[:,[1,2]],triangles[:,[2,0]]]),axis=1),axis=0)
    lengths=np.linalg.norm(p[edges[:,0]]-p[edges[:,1]],axis=1);neighbours=[[]for _ in p]
    for (a,b),length in zip(edges,lengths):neighbours[a].append((int(b),float(length)));neighbours[b].append((int(a),float(length)))
    cross=np.cross(p[triangles[:,1]]-p[triangles[:,0]],p[triangles[:,2]]-p[triangles[:,0]])
    area=np.zeros(len(p),np.float64)
    for j in range(3):np.add.at(area,triangles[:,j],np.linalg.norm(cross,axis=1)/6)
    scale=1.75/np.ptp(p[:,1]);radius=args.radius/scale
    foot=np.where(np.isin(attrs[:,4:8].astype(int),[7,8,10,11]),attrs[:,8:12],0).sum(1)
    normalized=p.copy();normalized[:,1]-=p[:,1].min();normalized*=scale
    eligible=(abs(normalized[:,0])<.68)&(normalized[:,1]<1.44)&(foot<.45)
    counts=[]
    for vertex in np.flatnonzero(eligible):
        best={int(vertex):0.0};queue=[(0.0,int(vertex))]
        while queue:
            distance,i=heapq.heappop(queue)
            if distance!=best[i]:continue
            for j,length in neighbours[i]:
                d=distance+length
                if d<=radius and d<best.get(j,float('inf')):best[j]=d;heapq.heappush(queue,(d,j))
        ids=np.fromiter(best,dtype=np.int32);distance=np.fromiter(best.values(),dtype=np.float64)
        kernel=np.square(np.maximum(0,1-np.square(distance/radius)))*area[ids]
        # Mild orientation gate prevents opposite faces of a thin feature from
        # cancelling, but does not lock every extracted wrinkle into the filter.
        kernel*=np.square(np.maximum(.1,n[ids]@n[vertex]))
        value=(n[ids]*kernel[:,None]).sum(0);normal[vertex]=value/max(np.linalg.norm(value),1e-12);counts.append(len(ids))
    args.out.mkdir(parents=True,exist_ok=True)
    for f in args.cache.iterdir():
        if f.is_file()and f.name!='200.vertices':shutil.copy2(f,args.out/f.name)
    vertices=np.fromfile(args.cache/'200.vertices','<f4').reshape(-1,16);vertices[:,4:7]=normal[triangles.ravel()];vertices.tofile(args.out/'200.vertices')
    before=np.degrees(np.arccos(np.clip(np.sum(n[edges[:,0]]*n[edges[:,1]],axis=1),-1,1)))
    after=np.degrees(np.arccos(np.clip(np.sum(normal[edges[:,0]]*normal[edges[:,1]],axis=1),-1,1)))
    report={'diagnostic_only':True,'normal_override':'Area-weighted compact kernel over shortest mesh-edge paths; clothing only','radius_metres':args.radius,'filtered_unique_vertices':int(eligible.sum()),'neighbourhood_median':float(np.median(counts)),
        'adjacent_normal_degrees_p95_before':float(np.quantile(before,.95)),'adjacent_normal_degrees_p95_after':float(np.quantile(after,.95)),'wall_seconds':time.perf_counter()-start,'geometry_unchanged':True,'learned_residual_included':False}
    if args.compare_native:
        native=np.fromfile(args.compare_native,dtype='<f4').reshape(-1,16);mask=eligible[triangles.ravel()]
        report['native_comparison']={'eligible_vertex_instances':int(mask.sum()),'normal_max_abs_error':float(np.abs(native[mask,4:7]-vertices[mask,4:7]).max()),
            'normal_rms_error':float(np.sqrt(np.mean((native[mask,4:7]-vertices[mask,4:7])**2))),
            'positions_unchanged':bool(np.array_equal(native[:,:3],vertices[:,:3])),
            'weights_and_ids_unchanged':bool(np.array_equal(native[:,8:16],vertices[:,8:16])),
            'native_vertex_sha256':hashlib.sha256(args.compare_native.read_bytes()).hexdigest()}
        check=report['native_comparison'];report['passed']=check['normal_max_abs_error']<2e-5 and check['positions_unchanged']and check['weights_and_ids_unchanged']
        report['source_sha256']={str(p).replace('\\','/'):hashlib.sha256(p.read_bytes()).hexdigest()for p in [Path('src/neural_mesh_cleanup.h'),Path(__file__).relative_to(Path.cwd())]}
    (args.out/'diagnostic.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,indent=2))
if __name__=='__main__':main()
