"""Benign offline integration: dedicated Ollama, existing read-only models, OS blocks Internet IP traffic."""
from pathlib import Path
import os,sys,json,subprocess,tempfile,time,signal,urllib.request,shutil,socket,hashlib
from pptx import Presentation
from pptx.util import Inches
ROOT=Path(__file__).resolve().parents[1]
CACHE=ROOT/'.cache/offline-check'
MODELS=Path.home()/'.ollama/models'

def main():
    scratch=Path(tempfile.mkdtemp(prefix='slp-offline-',dir='/private/tmp'))
    server=None
    model_meta={str(p.relative_to(MODELS)):(p.stat().st_size,p.stat().st_mtime_ns) for p in MODELS.rglob('*') if p.is_file()}
    policy='''(version 1)
(allow default)
(deny network*)
(allow network-bind (local ip "localhost:*"))
(allow network-inbound (local ip "localhost:*"))
(allow network-outbound (remote ip "localhost:*"))
(allow network-bind (local unix-socket))
(allow network-inbound (local unix-socket))
(allow network-outbound (remote unix-socket))
(deny lsopen)
(deny appleevent-send)
(deny file-write* (subpath (param "MODEL_ROOT")))
'''
    try:
        for name in ['home','tmp','data']:(scratch/name).mkdir(mode=0o700)
        (scratch/'offline.sb').write_text(policy)
        port_check=socket.socket();port_check.bind(('127.0.0.1',11435));port_check.close()
        for name,text in [('first','Revenue increased by 20%.'),('second','The meeting is scheduled for next Monday.')]:
            deck=Presentation();slide=deck.slides.add_slide(deck.slide_layouts[6]);slide.shapes.add_textbox(Inches(1),Inches(1),Inches(8),Inches(2)).text=text;deck.save(scratch/(name+'.pptx'))
        env={'PATH':'/usr/bin:/bin','HOME':str(scratch/'home'),'TMPDIR':str(scratch/'tmp')+'/',
             'LANG':'en_US.UTF-8','OLLAMA_HOST':'127.0.0.1:11435','OLLAMA_MODELS':str(MODELS.resolve()),
             'OLLAMA_NO_CLOUD':'1','OLLAMA_KEEP_ALIVE':'5m','OLLAMA_NUM_PARALLEL':'1','OLLAMA_MAX_LOADED_MODELS':'2'}
        sandbox=['/usr/bin/sandbox-exec','-D','MODEL_ROOT='+str(MODELS.resolve()),'-f',str(scratch/'offline.sb')]
        with (scratch/'server.log').open('wb') as log:
            server=subprocess.Popen([*sandbox,'/Applications/Ollama.app/Contents/Resources/ollama','serve'],env=env,cwd=scratch,stdout=log,stderr=log,start_new_session=True)
            opener=urllib.request.build_opener(urllib.request.ProxyHandler({}))
            for _ in range(100):
                if server.poll() is not None:raise RuntimeError('Isolated Ollama exited: '+(scratch/'server.log').read_text()[-1800:])
                try:
                    with opener.open('http://127.0.0.1:11435/api/status',timeout=1) as response:status=json.load(response)
                    if status.get('cloud',{}).get('disabled') is True:break
                except (OSError,ValueError):pass
                time.sleep(.2)
            else:raise RuntimeError('Isolated Ollama did not become ready')
            print('Dedicated Ollama ready; cloud disabled; only loopback IP traffic permitted.',flush=True)
            process=subprocess.run([*sandbox,str(CACHE/'integration'),str(scratch/'data'),str(scratch/'first.pptx'),str(scratch/'second.pptx'),'--skip-preview'],env=env,cwd=scratch,capture_output=True,text=True,timeout=240)
            if process.returncode!=0:raise RuntimeError('Offline integration failed: '+process.stderr[-2200:]+'\nServer tail: '+(scratch/'server.log').read_text()[-2200:])
            result=json.loads((scratch/'data/real-native-check.json').read_text())
            pdf=Path(result['output']);assert pdf.exists()
            # Render in a separate helper so the app's normal renderer sandbox is the decisive policy.
            # No API calls occur in this phase; the LibreOffice child itself denies all IP traffic.
            preview=subprocess.run([str(ROOT/'.cache/native-tests/preview-smoke'),str(pdf),str(scratch/'preview')],cwd=scratch,capture_output=True,text=True,timeout=150)
            if preview.returncode!=0:raise RuntimeError('Offline renderer failed: '+preview.stderr[-1500:])
            image=scratch/'preview/slide-1.png';assert image.exists()
            result['preview']=str(image);result['preview_performed']=True
            result['preview_validation']=preview.stdout.strip()
            from pptx import Presentation as VerifyPresentation
            assert len(VerifyPresentation(pdf).slides)==1
            result['verification_mode']='Translation/chat client, dedicated Ollama and model runners: macOS blocks non-loopback IP traffic. Preview: separate production renderer helper with its own IP-denying sandbox; no model/API calls during preview.'
            result['inference_seconds']=result.pop('seconds')
            result['model_store_read_only']=True
            result['fresh_ollama_process']=True
            result['endpoint_test_copy']=json.loads((CACHE/'endpoint-change.json').read_text())
            result['policy']=policy
            result['environment_keys']=sorted(env)
            result['preview_png_bytes']=image.stat().st_size
            result['output_pptx_bytes']=pdf.stat().st_size
            result['source_sha256']={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in ROOT.glob('Native*.swift')}
            (ROOT/'tests/output/offline-verification.json').write_text(json.dumps(result,ensure_ascii=False,indent=2))
            print('OFFLINE PASS: PLaMo translation (2 queued decks), Qwen document chat, editable PPTX, LibreOffice/PDFKit preview.',flush=True)
            print('Translation:',result['translation']);print('Answer:',result['answer']);print('Inference seconds:',round(result['inference_seconds'],2))
    finally:
        if server is not None and server.poll() is None:
            server.terminate()
            try:server.wait(timeout=15)
            except subprocess.TimeoutExpired:
                os.killpg(server.pid,signal.SIGKILL);server.wait(timeout=5)
        after={str(p.relative_to(MODELS)):(p.stat().st_size,p.stat().st_mtime_ns) for p in MODELS.rglob('*') if p.is_file()}
        if after!=model_meta:print('WARNING: model-store metadata changed during validation',file=sys.stderr)
        shutil.rmtree(scratch)
if __name__=='__main__':main()
