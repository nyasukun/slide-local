"""No renderer/network: verify only the actual Swift preview-package sanitizer."""
import tempfile,zipfile,subprocess
from pathlib import Path
from lxml import etree as ET
from make_fixture import make_fixture
BIN=Path(__file__).resolve().parents[1]/'.cache/native-tests/check'
with tempfile.TemporaryDirectory(prefix='slidelocal-preview-policy-') as t:
 d=Path(t);source=make_fixture(d/'source.pptx');prepared=d/'prepared.pptx'
 # Add an unused, harmless external relationship solely for sanitizer testing.
 # This file is never opened by a renderer or network client.
 amended=d/'amended.pptx'
 with zipfile.ZipFile(source) as a,zipfile.ZipFile(amended,'w',zipfile.ZIP_DEFLATED) as b:
  for info in a.infolist():
   content=a.read(info)
   if info.filename=='ppt/slides/_rels/slide1.xml.rels':
    tree=ET.fromstring(content)
    ET.SubElement(tree,'{http://schemas.openxmlformats.org/package/2006/relationships}Relationship',Id='privacyDummy',Type='http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink',Target='https://example.invalid/never-requested',TargetMode='External')
    content=ET.tostring(tree)
   b.writestr(info,content)
 amended.replace(source)
 before=source.read_bytes()
 p=subprocess.run([str(BIN),'preview-copy',str(source),str(prepared)],capture_output=True)
 assert p.returncode==0,p.stderr.decode()
 assert source.read_bytes()==before
 stripped=0
 with zipfile.ZipFile(source) as a,zipfile.ZipFile(prepared) as b:
  assert a.namelist()==b.namelist()
  for name in a.namelist():
   if name.endswith('.rels'):
    x=ET.fromstring(a.read(name));y=ET.fromstring(b.read(name))
    expected=[r for r in x if r.get('TargetMode','').lower()!='external']
    stripped+=len(x)-len(expected)
    assert len(expected)==len(y)
    assert all(r.get('TargetMode','').lower()!='external' for r in y)
    assert [(r.get('Id'),r.get('Target')) for r in expected]==[(r.get('Id'),r.get('Target')) for r in y]
   else:assert a.read(name)==b.read(name),name
 assert stripped>0
 print('preview privacy: external relationships removed only in rendering copy; source/media/internal refs unchanged PASS')
