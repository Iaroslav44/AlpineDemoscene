"""Export inert tensors from the official real-photo-trained PhotoMat release.

No checkpoint Python source/classes are executed. Pickle reconstruction is
restricted to inert metadata, numeric storages and tensor descriptors.
"""
from pathlib import Path
import collections
import hashlib
import io
import json
import pickle
import struct
import zipfile
import numpy as np
from neural_material_fetch import REPOSITORY_REVISION, SOURCE_FILES

ROOT = Path(__file__).resolve().parents[1]
SOURCES = {
    'G_256.pkl': '4648af64714a59d3c6a40eef176935c6b8374d348fa10a40f40b6791a21b55ba',
    'MatUnet_256.pt': '8e08510fdd91ce5004a2cd63fdbd37b7e1292c724474e24861760218a8e5fd1e',
}

class Inert:
    def __setstate__(self, state): self.__dict__.update(state)

class Tensor:
    def __init__(self, storage, offset, shape, stride, *unused):
        self.storage, self.offset, self.shape, self.stride = storage, offset, tuple(shape), tuple(stride)

def persistent(meta):
    result = Inert()
    result.__dict__.update(meta['state'])
    result.class_name = meta['class_name']
    return result

def parameter(value, *unused): return value

def storage_bytes(raw):
    stream = io.BytesIO(raw)
    reader = Restricted(stream)
    magic, protocol, info = reader.load(), reader.load(), reader.load()
    if magic != 0x1950a86a20f9469cfc6c or protocol != 1001 or not info['little_endian']:
        raise ValueError('Unexpected torch legacy storage header')
    descriptor = reader.load()
    keys = reader.load()
    if len(keys) != 1 or descriptor[0] != 'storage' or descriptor[1] not in ('FloatStorage', 'LongStorage'):
        raise ValueError('Unexpected storage object')
    count, = struct.unpack('<Q', stream.read(8))
    dtype = '<f4' if descriptor[1] == 'FloatStorage' else '<i8'
    expected = count * np.dtype(dtype).itemsize
    data = stream.read()
    if len(data) != expected: raise ValueError('Storage byte size mismatch')
    return np.frombuffer(data, dtype=dtype)

class Restricted(pickle.Unpickler):
    def find_class(self, module, name):
        allowed = {
            ('builtins','set'): set,
            ('collections','OrderedDict'): collections.OrderedDict,
            ('dnnlib.util','EasyDict'): dict,
            ('numpy','dtype'): np.dtype,
            ('numpy.core.multiarray','scalar'): np._core.multiarray.scalar,
            ('torch','FloatStorage'): 'FloatStorage',
            ('torch','LongStorage'): 'LongStorage',
            ('torch._utils','_rebuild_parameter'): parameter,
            ('torch._utils','_rebuild_tensor_v2'): Tensor,
            ('torch.storage','_load_from_bytes'): storage_bytes,
            ('torch_utils.persistence','_reconstruct_persistent_obj'): persistent,
            ('torch.nn.modules.container','Sequential'): Inert,
            ('training.networks','OSGDecoder'): Inert,
        }
        if (module,name) not in allowed: raise pickle.UnpicklingError(f'Blocked global {module}.{name}')
        return allowed[module,name]
    def persistent_load(self, value):
        if not isinstance(value, tuple) or len(value) not in (5,6) or value[0] != 'storage':
            raise pickle.UnpicklingError('Invalid storage reference')
        return value

def array(tensor, archive=None):
    if not isinstance(tensor, Tensor): raise ValueError('Expected tensor')
    storage = tensor.storage
    if archive is not None:
        if storage[1] != 'FloatStorage': raise ValueError('Non-float learned tensor')
        storage = np.frombuffer(archive.read('archive/data/' + storage[2]), dtype='<f4')
    result = np.ndarray(tensor.shape, dtype=storage.dtype, buffer=storage,
                        offset=tensor.offset*storage.itemsize,
                        strides=tuple(x*storage.itemsize for x in tensor.stride)).copy()
    if result.dtype != np.float32 or not np.isfinite(result).all(): raise ValueError('Invalid weight tensor')
    return result

def walk(node, prefix=''):
    for name, value in node.__dict__.get('_parameters', {}).items():
        if value is not None: yield prefix+name, array(value)
    for name, value in node.__dict__.get('_buffers', {}).items():
        if value is not None: yield prefix+name, array(value)
    for name, child in node.__dict__.get('_modules', {}).items():
        yield from walk(child, prefix+name+'.')

def load_sources():
    folder = ROOT/'build/neural_material_source'
    for name, sha in SOURCES.items():
        with (folder/name).open('rb') as stream:
            if hashlib.file_digest(stream,'sha256').hexdigest()!=sha: raise ValueError('Source SHA256 mismatch')
    with (folder/'G_256.pkl').open('rb') as stream: state=Restricted(stream).load()
    generator=state['G_ema']
    tensors=collections.OrderedDict(walk(generator))
    with zipfile.ZipFile(folder/'MatUnet_256.pt') as archive:
        state=Restricted(io.BytesIO(archive.read('archive/data.pkl'))).load()
        tensors.update(('unet.'+name,array(value,archive)) for name,value in state['MatUnet'].items())
    return generator,tensors

def export():
    generator,tensors=load_sources()
    folder=ROOT/'build/neural_material_research'
    metadata={'generator':{k:v for k,v in generator.__dict__.items() if k.startswith('_init') or k in ('img_resolution','z_dim','c_dim','w_dim','img_channels')},
              'tensors':{k:{'shape':list(v.shape),'bytes':v.nbytes} for k,v in tensors.items()},
              'total_bytes':sum(v.nbytes for v in tensors.values())}
    (folder/'tensors.json').write_text(json.dumps(metadata,indent=2))
    print(json.dumps({k:v for k,v in metadata.items() if k!='tensors'},indent=2))
    print('tensor_count',len(tensors))
    selected=collections.OrderedDict()
    for name,value in tensors.items():
        if name.startswith('synthesis.MLP_decoder.') or name.endswith(('.noise_const','.resample_filter')):
            continue
        selected[name]=value
    count=len(selected)
    data_offset=(64+count*128+63)&~63
    offset=data_offset
    directory=[]
    payload=[]
    records=[]
    for name,value in selected.items():
        shape=list(value.shape) or [1]
        layout=1
        if value.ndim==4:
            # Coalesced GPU convolution weights [kernelY,kernelX,input,output].
            packed=value.transpose(2,3,1,0).copy(); layout=2
        elif name=='synthesis.b4.const':
            packed=value.transpose(1,2,0).copy(); layout=3
        else: packed=value
        raw=packed.astype('<f4',copy=False).tobytes()
        encoded=name.encode('ascii')
        if len(encoded)>79: raise ValueError('Tensor name too long')
        directory.append(struct.pack('<80s12I',encoded,len(shape),*(shape+[0]*(5-len(shape))),offset,len(raw),layout,0,0,0))
        records.append(dict(name=name,shape=shape,offset=offset,bytes=len(raw),layout=layout))
        payload.append(raw);offset+=len(raw)
    output=ROOT/'models/material/photomat-256.nam'
    output.parent.mkdir(parents=True,exist_ok=True)
    with output.open('wb') as stream:
        stream.write(struct.pack('<16I',0x314d414e,1,count,data_offset,256,512,32,8,2,0,0,0,0,0,0,0))
        for entry in directory:stream.write(entry)
        stream.write(bytes(data_offset-stream.tell()))
        for raw in payload:stream.write(raw)
    with output.open('rb') as stream:sha=hashlib.file_digest(stream,'sha256').hexdigest()
    provenance=dict(schema=1,name='PhotoMat 256',paper='https://arxiv.org/abs/2305.12296',
        repository='https://github.com/xilongzhou/PhotoMat',repository_revision=REPOSITORY_REVISION,
        official_source_sha256=SOURCE_FILES,
        training='Real flash photographs of physical material samples, as stated by the authors.',
        source_checkpoints=SOURCES,export_bytes=output.stat().st_size,export_sha256=sha,
        format='NAM1; 64-byte header; 128-byte tensor records; little-endian float32; logical source dimensions',
        retained='G_ema mapping/synthesis feature generator and MatUnet trained SVBRDF estimator.',
        excluded='Discriminator, non-EMA generator, learned relighting MLP, stored fixed random noise, fixed resample filters.',
        noise='Fresh seeded CLT Gaussian noise evaluated during runtime, using trained noise strengths.',
        inference='Float32 operators. Checkpoint FP16 acceleration is not reproduced; reference requests float32.',
        output='256x256 height, diffuse RGB, roughness, specular RGB; source height-to-normal conversion.',
        limitations=['Unconditional model; no guaranteed semantic material category.',
                    'Generator uses zero padding; generated tiles are not inherently seamless.',
                    'Materials do not generate object geometry.',
                    'PhotoMat and StyleGAN license limits to noncommercial research/evaluation.'],
        generator=metadata['generator'],tensors=records)
    (output.parent/'provenance.json').write_text(json.dumps(provenance,indent=2))
    for source,target in [('LICENSE.txt','LICENSE-PhotoMat.txt'),('LICENSE-stylegan.txt','LICENSE-StyleGAN.txt')]:
        (output.parent/target).write_bytes((folder/source).read_bytes())
    (output.parent/'NOTICE.txt').write_text('PhotoMat: A Material Generator Learned from Single Flash Photos, SIGGRAPH 2023.\nXilong Zhou, Milos Hasan, Valentin Deschaintre, Paul Guerrero, Yannick Hold-Geoffroy, Kalyan Sunkavalli, Nima Khademi Kalantari.\nOfficial pretrained weights; float32 tensor subset and native inference implementation for local noncommercial research/evaluation.\nSee LICENSE-PhotoMat.txt and LICENSE-StyleGAN.txt. No recorded material images are packaged.\n')
    print(json.dumps(dict(path=str(output),bytes=output.stat().st_size,sha256=sha,tensor_count=count)))

if __name__=='__main__':export()
