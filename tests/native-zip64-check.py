import json,struct,subprocess,tempfile,zipfile
from pathlib import Path
from make_fixture import make_fixture
BIN=Path(__file__).resolve().parents[1]/'.cache/native-tests/check'
def run(*args):
 p=subprocess.run([str(BIN),*map(str,args)],capture_output=True);assert p.returncode==0,p.stderr.decode();return p.stdout
with tempfile.TemporaryDirectory(prefix='slidelocal-zip64-') as t:
 d=Path(t);source=make_fixture(d/'sample.pptx');raw=source.read_bytes();end=raw.rfind(b'PK\x05\x06')
 fields=struct.unpack_from('<IHHHHIIH',raw,end);count,central_size,central=fields[4],fields[5],fields[6]
 sparse=d/'sparse64.pptx';offset=(1<<32)+1024
 with sparse.open('wb') as f:
  f.write(raw[:central]);f.seek(offset);f.write(raw[central:central+central_size]);zip64_offset=f.tell()
  f.write(struct.pack('<IQHHIIQQQQ',0x06064b50,44,45,45,0,0,count,count,central_size,offset))
  f.write(struct.pack('<IIQI',0x07064b50,0,zip64_offset,1))
  f.write(struct.pack('<IHHHHIIH',0x06054b50,0,0,0xffff,0xffff,0xffffffff,0xffffffff,0))
 assert json.loads(run('inspect',sparse))['slide_count']==3
 many=d/'many.pptx';many.write_bytes(raw)
 with zipfile.ZipFile(many,'a',allowZip64=True) as z:
  for i in range(65536):z.writestr(f'customXml/empty{i}',b'')
 inv=json.loads(run('inspect',many));units=inv['units'];units[0]['translation']='オーロラ計画';units[0]['status']='done'
 (d/'units.json').write_text(json.dumps(units));output=d/'output.pptx';run('export',many,d/'units.json',output)
 with zipfile.ZipFile(many) as a,zipfile.ZipFile(output) as b:
  assert a.namelist()==b.namelist();assert b.testzip() is None
 assert json.loads(run('inspect',output))['units'][0]['source']=='オーロラ計画'
 print('ZIP64: sparse central offset >4GiB and >65,535 members read/write PASS')
