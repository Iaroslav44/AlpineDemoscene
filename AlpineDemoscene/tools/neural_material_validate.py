"""Independent NumPy reference of PhotoMat's published inference operators.

Reads original official checkpoints, not the transformed NAM1 file. This is
developer QA only and is never used to pre-bake executable runtime maps.
"""
import argparse
import hashlib
import json
import time
from pathlib import Path
import numpy as np
from neural_material_export import ROOT, load_sources, SOURCES

def hash32(x):
    x=np.asarray(x,dtype=np.uint32)
    with np.errstate(over='ignore'):
        x=(x^(x>>np.uint32(16)))*np.uint32(0x7feb352d)
        x=(x^(x>>np.uint32(15)))*np.uint32(0x846ca68b)
    return x^(x>>np.uint32(16))

def gaussian(state):
    value=np.zeros(np.shape(state),dtype=np.float32)
    for _ in range(12):
        with np.errstate(over='ignore'):state=hash32(state+np.uint32(0x9e3779b9))
        value+=(state>>np.uint32(8)).astype(np.float32)*np.float32(1/16777216)-np.float32(0.5)
    return value,state

def conv(x,weight,stride=1,pad=1,circular=False):
    out_c,in_c,kh,kw=weight.shape
    x=np.pad(x,((pad,pad),(pad,pad),(0,0)),mode='wrap' if circular else 'constant')
    h=(x.shape[0]-kh)//stride+1;w=(x.shape[1]-kw)//stride+1
    result=np.zeros((h*w,out_c),np.float32)
    for y in range(kh):
        for z in range(kw):
            patch=np.ascontiguousarray(x[y:y+h*stride:stride,z:z+w*stride:stride]).reshape(h*w,in_c)
            result+=patch@np.ascontiguousarray(weight[:,:,y,z].T)
    return result.reshape(h,w,out_c)

def fir(x,pad):
    h,w,c=x.shape
    expanded=np.zeros((h*2,w*2,c),np.float32);expanded[::2,::2]=x
    expanded=np.pad(expanded,((pad,pad-1),(pad,pad-1),(0,0)))
    h,w=expanded.shape[:2];h-=3;w-=3
    out=np.zeros((h,w,c),np.float32)
    for y,wy in enumerate((1,3,3,1)):
        for z,wx in enumerate((1,3,3,1)):
            out+=expanded[y:y+h,z:z+w]*np.float32(wy*wx/16)
    return out

def bilinear(x):
    h,w,c=x.shape
    y=np.arange(h*2,dtype=np.float32)*np.float32((h-1)/(h*2-1))
    z=np.arange(w*2,dtype=np.float32)*np.float32((w-1)/(w*2-1))
    yl=y.astype(int);zl=z.astype(int);yh=np.minimum(yl+1,h-1);zh=np.minimum(zl+1,w-1)
    fy=(y-yl).astype(np.float32)[:,None,None];fx=(z-zl).astype(np.float32)[None,:,None]
    a=x[yl[:,None],zl];b=x[yl[:,None],zh];c=x[yh[:,None],zl];d=x[yh[:,None],zh]
    ab=a+(b-a)*fx;cd=c+(d-c)*fx
    return ab+(cd-ab)*fy

def digest(path):
    with path.open('rb') as stream:return hashlib.file_digest(stream,'sha256').hexdigest()

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--directory',default='build/neural_material_probe42');parser.add_argument('--seed',type=int,default=42);parser.add_argument('--skip-reference',action='store_true');args=parser.parse_args()
    folder=ROOT/args.directory
    report={'schema':1,'model_sha256':digest(ROOT/'models/material/photomat-256.nam'),'source_checkpoints':SOURCES,'seed':args.seed,'errors':[],'operator_comparison':{},'perceptual_indistinguishability_verified':False}
    report['source_sha256']={name:digest(ROOT/name) for name in ['src/neural_material_runtime.cpp','src/neural_material_runtime.h','src/neural_material.hlsl','tools/neural_material_export.py','tools/neural_material_validate.py']}
    report['timing']=json.loads((folder/'timing.json').read_text())
    def compare(name,values,tolerance=0.0002):
        native=np.fromfile(folder/(name+'.f32'),dtype='<f4').reshape(values.shape)
        delta=native.astype(np.float64)-values
        metric={'max_absolute':float(np.abs(delta).max()),'rms':float(np.sqrt(np.mean(delta*delta))),'reference_rms':float(np.sqrt(np.mean(values.astype(np.float64)**2)))}
        report['operator_comparison'][name]=metric
        print(name,metric,flush=True)
        if not np.isfinite(native).all() or metric['max_absolute']>tolerance:report['errors'].append(name+' reference mismatch')
    if not args.skip_reference:
        started=time.perf_counter();_,t=load_sources();state=hash32(np.uint32(args.seed));z=[]
        for _ in range(512):v,state=gaussian(state);z.append(v)
        z=np.array(z,dtype=np.float32);z/=np.sqrt(np.mean(z*z,dtype=np.float32)+np.float32(1e-8));compare('latent_z',z,1e-5)
        latent=z
        for i in range(2):
            w=t[f'mapping.fc{i}.weight']*np.float32(0.01/np.sqrt(np.float32(512)))
            latent=latent@w.T+t[f'mapping.fc{i}.bias']*np.float32(0.01)
            latent=np.where(latent>=0,latent,latent*np.float32(0.2))*np.float32(np.sqrt(2))
        latent=t['mapping.w_avg']+(latent-t['mapping.w_avg'])*np.float32(0.7);compare('latent_w',latent,1e-4)
        layer_index=0
        def styled(prefix,x,up=False,demod=True):
            nonlocal layer_index
            w=t[prefix+'.weight'];style=latent@(t[prefix+'.affine.weight']*np.float32(1/np.sqrt(np.float32(512)))).T+t[prefix+'.affine.bias']
            if not demod:style*=np.float32(1/np.sqrt(np.float32(x.shape[2])))
            if up:x=fir(x,3)
            value=conv(x*style,w[:,:,::-1,::-1] if up else w,pad=0 if up or not demod else 1)
            if demod:
                norm=np.sqrt(np.sum((w*style[None,:,None,None])**2,axis=(1,2,3),dtype=np.float32)+np.float32(1e-8))
                value/=norm
                layer_index+=1
                layer_seed=hash32(np.uint32(args.seed^((layer_index*0x9e3779b9)&0xffffffff)))
                noise,_=gaussian(hash32(np.arange(value.shape[0]*value.shape[1],dtype=np.uint32)^layer_seed))
                value+=noise.reshape(value.shape[:2]+(1,))*t[prefix+'.noise_strength']
            value+=t[prefix+'.bias']
            if demod:value=np.where(value>=0,value,value*np.float32(0.2))*np.float32(np.sqrt(2))
            return np.clip(value,-256,256)
        field=t['synthesis.b4.const'].transpose(1,2,0).copy();image=None
        for res in (4,8,16,32,64,128,256):
            prefix=f'synthesis.b{res}'
            if res>4:field=styled(prefix+'.conv0',field,True)
            field=styled(prefix+'.conv1',field)
            rgb=styled(prefix+'.torgb',field,demod=False)
            image=rgb if image is None else fir(image,2)+rgb
            compare(f'feature_{res}',image)
        levels=[];x=image
        def ordinary(prefix,x,stride=1,last=False):
            y=conv(x,t[prefix+'.weight'],stride=stride,circular=True)+t[prefix+'.bias']
            return np.tanh(y) if last else np.where(y>=0,y,y*np.float32(0.01))
        for block in range(5):
            x=ordinary(f'unet.block{block}.model.0',x,2);x=ordinary(f'unet.block{block}.model.2',x);levels.append(x)
        for block in range(5,9):
            x=ordinary(f'unet.block{block}.model.0',np.concatenate((bilinear(x),levels[8-block]),axis=2))
            x=ordinary(f'unet.block{block}.model.2',x)
        raw=ordinary('unet.out',bilinear(x),last=True);compare('svbrdf_raw',raw,0.0002)
        report['reference_seconds']=time.perf_counter()-started
        np.save(folder/'svbrdf_reference.npy',raw)
    raw=np.fromfile(folder/'svbrdf_raw.f32',dtype='<f4').reshape(256,256,8)*0.5+0.5
    diffuse=np.fromfile(folder/'diffuse_roughness.f32',dtype='<f4').reshape(256,256,4)
    normal=np.fromfile(folder/'normal_height.f32',dtype='<f4').reshape(256,256,4)
    specular=np.fromfile(folder/'specular.f32',dtype='<f4').reshape(256,256,4)
    report['maps']={'diffuse_min':float(diffuse[:,:,:3].min()),'diffuse_max':float(diffuse[:,:,:3].max()),'diffuse_std':float(diffuse[:,:,:3].std()),'roughness_min':float(diffuse[:,:,3].min()),'roughness_max':float(diffuse[:,:,3].max()),'normal_length_max_error':float(np.abs(np.linalg.norm(normal[:,:,:3],axis=2)-1).max()),'specular_min':float(specular[:,:,:3].min()),'specular_max':float(specular[:,:,:3].max())}
    for name,values in [('diffuse',diffuse),('normal',normal),('specular',specular)]:
        if not np.isfinite(values).all():report['errors'].append(name+' nonfinite')
    if report['maps']['normal_length_max_error']>1e-5:report['errors'].append('invalid normal lengths')
    from PIL import Image,ImageDraw
    images=[('Diffuse (sRGB display)',np.clip(diffuse[:,:,:3],0,1)**(1/2.2)),('Height',np.repeat(raw[:,:,:1],3,2)),('Tangent normal',normal[:,:,:3]*0.5+0.5),('Roughness',np.repeat(diffuse[:,:,3:],3,2)),('Specular (linear)',specular[:,:,:3])]
    canvas=Image.new('RGB',(256*3,284*2),(24,24,24));draw=ImageDraw.Draw(canvas)
    for i,(name,data) in enumerate(images):
        image=Image.fromarray(np.uint8(np.clip(data,0,1)*255),'RGB');image.save(folder/(name.split(' ')[0].lower()+'.png'))
        x=(i%3)*256;y=(i//3)*284;canvas.paste(image,(x,y+28));draw.text((x+5,y+8),name,fill='white')
    canvas.save(folder/'maps.png')
    report['passed']=not report['errors'] and report['timing']['success'] and not args.skip_reference
    report['limitations']=['Float32 reference, runtime-generated noise, truncation0.7; no category conditioning.','No perceptual match-to-reality validation. Generated material appearance is not geometry generation.','Non-seamless zero-padded generator; world mapping must address seams.']
    report['output_sha256']={name:digest(folder/name) for name in ['svbrdf_raw.f32','diffuse_roughness.f32','normal_height.f32','specular.f32']}
    for key in ('reject_truncated','reject_bad_magic','reject_bad_offset'):
        if not report['timing'].get(key):report['errors'].append('missing or failed negative test '+key)
    cancel_path=ROOT/'build/neural_material_cancel/timing.json'
    if cancel_path.exists():
        report['cancellation']=json.loads(cancel_path.read_text())
        if report['cancellation']['status']!=2 or report['cancellation']['pump_calls']!=3:report['errors'].append('cancellation contract failed')
    else:report['errors'].append('cancellation check missing')
    second=ROOT/'build/neural_material_probe43/svbrdf_raw.f32'
    if second.exists() and args.seed==42:
        difference=np.fromfile(second,dtype='<f4')-np.fromfile(folder/'svbrdf_raw.f32',dtype='<f4')
        report['different_seed']={'seed':43,'raw_rms_difference':float(np.sqrt(np.mean(difference.astype(np.float64)**2))),'sha256':digest(second)}
        if report['different_seed']['raw_rms_difference']<0.001:report['errors'].append('seed does not change generated material')
    previous=ROOT/'validation/neural-material.json'
    if previous.exists() and args.seed==42:
        old=json.loads(previous.read_text())
        if old.get('model_sha256')==report['model_sha256']:
            report['same_seed_repeat_identical']=old['output_sha256']==report['output_sha256']
            if not report['same_seed_repeat_identical']:report['errors'].append('same seed output changed between native repetitions')
    report['passed']=not report['errors'] and report['timing']['success'] and not args.skip_reference
    (folder/'validation.json').write_text(json.dumps(report,indent=2))
    if not args.skip_reference:(ROOT/'validation/neural-material.json').write_text(json.dumps(report,indent=2))
    print(json.dumps({'passed':report['passed'],'errors':report['errors'],'maps':report['maps']},indent=2))
    if report['errors']:raise SystemExit(1)

if __name__=='__main__':main()
