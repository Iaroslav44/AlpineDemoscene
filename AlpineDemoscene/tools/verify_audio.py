"""Numerical QA of the production MASM score. This does not certify realism.

Uses NumPy for signal analysis and ffmpeg for BS.1770 loudness/true-peak.
"""
from pathlib import Path
import argparse, json, subprocess, wave, hashlib
import numpy as np

parser=argparse.ArgumentParser()
parser.add_argument('--directory',type=Path,default=Path('build/audio_revision'))
args=parser.parse_args()

def read(path):
    with wave.open(str(path),'rb') as f:
        assert f.getsampwidth()==2 and f.getframerate()==44100
        return np.frombuffer(f.readframes(f.getnframes()),'<i2').reshape(-1,f.getnchannels()).astype(np.float64)/32768

def db(value):return float(20*np.log10(max(float(value),1e-15)))
report={'quality_claim':'URMP-trained MIDI-DDSP timbre decoder with authored pitch and expression; perceptual indistinguishability is not established by these numerical checks.','files':{}}
errors=[]
for name in ['orchestral_house_full.wav','violin_C4.wav','double_bass_A1.wav','trumpet_A4.wav']:
    path=args.directory/name
    a=read(path)
    m={'seconds':len(a)/44100,'channels':a.shape[1],'sample_peak_dbfs':db(np.max(np.abs(a))),
       'rms_dbfs':db(np.sqrt(np.mean(a*a))),'dc':a.mean(axis=0).tolist(),
       'fullscale_samples':int(np.count_nonzero(np.abs(a)>=32767/32768)),
       'sha256':hashlib.sha256(path.read_bytes()).hexdigest()}
    if m['fullscale_samples']:errors.append(name+': clipping')
    if np.max(np.abs(a.mean(axis=0)))>0.002:errors.append(name+': DC')
    if a.shape[1]==2:
        m['stereo_correlation']=float(np.corrcoef(a.T)[0,1])
        m['side_mid_db']=db(np.sqrt(np.mean((a[:,0]-a[:,1])**2))/np.sqrt(np.mean((a[:,0]+a[:,1])**2)))
        m['boundary_first_last']=a[[0,-1]].tolist()
        m['max_sample_step']=float(np.max(np.abs(np.diff(a,axis=0))))
        if np.max(np.abs(a[[0,-1]]))>1/32768:errors.append(name+': nonzero loop seam')
        if len(a)!=44100*128:errors.append(name+': wrong score duration')
    else:
        target={'violin_C4.wav':261.625565,'double_bass_A1.wav':55.,'trumpet_A4.wav':440.}[name]
        # Measure the fundamental in a narrow known-register band. A whole-
        # spectrum argmax would mistake a strong body mode for the fundamental.
        w=a[11025:11025+65536,0]*np.hanning(65536)
        size=1<<19
        spectrum=np.abs(np.fft.rfft(w,n=size))
        hz=np.fft.rfftfreq(size,1/44100)
        band=(hz>target*.94)&(hz<target*1.06)
        f=float(hz[np.where(band)[0][np.argmax(spectrum[band])]])
        m['fundamental_hz']=f;m['expected_hz']=target;m['pitch_error_cents']=float(1200*np.log2(f/target))
        m['spectral_centroid_hz']=float(np.sum(hz*spectrum**2)/np.sum(spectrum**2))
        if abs(m['pitch_error_cents'])>15:errors.append(name+': unstable tuning')
    report['files'][name]=m
generation=json.loads((args.directory/'generation.json').read_text())
report['generation']=generation
if generation['bank_nonfinite']!=0:errors.append('nonfinite generated bank')
result=subprocess.run(['ffmpeg','-hide_banner','-i',str(args.directory/'orchestral_house_full.wav'),'-af','ebur128=peak=true','-f','null','-'],capture_output=True,text=True,check=True)
report['loudness_summary']=result.stderr[result.stderr.rfind('Summary:'):].strip()
report['errors']=errors;report['passed']=not errors
(args.directory/'audio_metrics.json').write_text(json.dumps(report,indent=2),encoding='utf-8')
print(json.dumps(report,indent=2))
raise SystemExit(bool(errors))
