import hashlib,json,sqlite3,subprocess,tempfile
from pathlib import Path
from make_fixture import make_fixture
BIN=Path(__file__).resolve().parents[1]/'.cache/native-tests/check'
def run(*args,ok=True):
 p=subprocess.run([str(BIN),*map(str,args)],capture_output=True)
 assert (p.returncode==0)==ok,p.stderr.decode()
 return p.stdout

def manifest(root):
 return {str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in root.rglob('*') if p.is_file()}
with tempfile.TemporaryDirectory(prefix='slidelocal-storage-') as t:
 d=Path(t);legacy=d/'legacy';id='a'*32;folder=legacy/id;folder.mkdir(parents=True)
 fixture=make_fixture(folder/'source.pptx');inventory=json.loads(run('inspect',fixture))
 project=dict(id=id,filename='日本語.pptx',created=1,state='complete',message='完了',source='',target='ja',model='plamo-translate:0.8b',completed=0,total=0,fit=True,include_notes=False,chats=[dict(question='質問',answer='回答',refs=[1],model='qwen3.5:4b')],preview_state='idle',preview_version='source',preview_error='',**inventory)
 (folder/'project.json').write_text(json.dumps(project,ensure_ascii=False))
 (legacy/'queue.json').write_text(json.dumps(dict(paused=True,items=[])))
 with sqlite3.connect(legacy/'cache.sqlite') as db:
  db.execute('CREATE TABLE translations (key TEXT PRIMARY KEY,value TEXT NOT NULL)')
  db.execute('INSERT INTO translations VALUES (?,?)',('legacy-key','既存の翻訳値'))
 before=manifest(legacy);target=d/'native';run('store',legacy,target,'既存の翻訳値')
 assert before==manifest(legacy)
 assert json.loads((target/id/'project.json').read_text())==project
 assert json.loads((target/'queue.json').read_text())==dict(paused=True,items=[])
 assert json.loads((target/'migration.json').read_text())['projects']==1
 run('lock',d/'locked')
 values=['digest','ja','','文脈\nURL/😀\u2028','"hello"\t日本語']
 key=hashlib.sha256(json.dumps(values,ensure_ascii=False).encode()).hexdigest()
 assert run('cache-key',*values).decode()==key
 bad=d/'bad';badid='b'*32;(bad/badid).mkdir(parents=True);(bad/badid/'project.json').write_text('broken')
 original=manifest(bad);run('store',bad,d/'bad-target',ok=False)
 assert not (d/'bad-target').exists();assert manifest(bad)==original
 print('native storage: migration/idempotence/source hashes/chats/cache key compatibility/lock/failed migration rollback PASS')
