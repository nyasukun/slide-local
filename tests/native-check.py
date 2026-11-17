"""Independent OOXML oracle for the actual compiled Swift engine (Python is tests only)."""
import argparse, io, json, os, subprocess, sys, tempfile, zipfile, hashlib
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
sys.path.insert(0,str(Path(__file__).parent))
from make_fixture import make_fixture
from reference_pptx import inspect_deck
from pptx import Presentation
from lxml import etree as ET
ROOT=Path(__file__).resolve().parents[1]
BIN=ROOT/'.cache/native-tests/check'

def run(*args):
    p=subprocess.run([str(BIN),*map(str,args)],capture_output=True)
    assert p.returncode==0,p.stderr.decode()
    return p.stdout

def check(large=False):
    with tempfile.TemporaryDirectory(prefix='slidelocal-native-') as temporary:
        d=Path(temporary); source=make_fixture(d/'source.pptx')
        # Some real decks encode spacing as a whitespace-only rich run.
        amended=d/'amended.pptx'
        with zipfile.ZipFile(source) as a,zipfile.ZipFile(amended,'w',zipfile.ZIP_DEFLATED) as b:
            for info in a.infolist():
                content=a.read(info)
                if info.filename=='ppt/slides/slide1.xml':
                    tree=ET.fromstring(content);ns={'a':'http://schemas.openxmlformats.org/drawingml/2006/main'}
                    paragraph=tree.findall('.//a:p',ns)[2]
                    r=ET.SubElement(paragraph,'{'+ns['a']+'}r');ET.SubElement(r,'{'+ns['a']+'}t').text='  '
                    content=ET.tostring(tree,xml_declaration=True,encoding='UTF-8',standalone=True)
                b.writestr(info,content)
        amended.replace(source)
        if large:
            with zipfile.ZipFile(source,'a',compression=zipfile.ZIP_STORED,allowZip64=True) as z:
                with z.open('ppt/media/large.bin','w',force_zip64=True) as f:
                    for _ in range(76):f.write(b'x'*(1024*1024))
                for i in range(20001):z.writestr(f'customXml/piece{i}.txt',b'preserved')
                with z.open('customXml/expanded.bin','w',force_zip64=True) as f:
                    for _ in range(801):f.write(bytes(1024*1024))
        native=json.loads(run('inspect',source)); legacy=inspect_deck(source)
        assert native==legacy,(native,legacy)
        translations={'Project Aurora':'オーロラ計画','Japan':'日本','Europe':'欧州','Revenue':'売上高','Region':'地域'}
        units=[u for u in native['units'] if u['kind']!='notes']
        for u in units:u['translation']=translations.get(u['source'],'翻訳 '+u['source']);u['status']='done'
        (d/'units.json').write_text(json.dumps(units,ensure_ascii=False))
        output=d/'translated.pptx';run('export',source,d/'units.json',output)
        with zipfile.ZipFile(source) as a,zipfile.ZipFile(output) as b:
            assert a.namelist()==b.namelist()
            changed={u['part'] for u in units if u['source']!=u['translation']}
            changed|={n for n in a.namelist() if n.endswith('.xlsx')}
            for n in a.namelist():
                if n not in changed:
                    def digest(z):
                        h=hashlib.sha256()
                        with z.open(n) as f:
                            while chunk:=f.read(1024*1024):h.update(chunk)
                        return h.hexdigest()
                    assert digest(a)==digest(b),n
                elif n.endswith('.xml'):ET.fromstring(b.read(n))
            workbook=next(n for n in b.namelist() if n.endswith('.xlsx'))
            with zipfile.ZipFile(io.BytesIO(b.read(workbook))) as x:
                assert '日本' in x.read('xl/sharedStrings.xml').decode()
                assert '欧州' in x.read('xl/sharedStrings.xml').decode()
        prs=Presentation(output);assert len(prs.slides)==3
        assert prs.slides[0].shapes[0].text=='オーロラ計画'
        assert any(u['source']=='日本' for u in json.loads(run('inspect',output))['units'])
        assert any(u['source']=='Internal speaker notes: keep these unchanged.' for u in native['units'])
        invalid=d/'invalid.pptx';invalid.write_bytes(b'bad')
        p=subprocess.run([str(BIN),'inspect',str(invalid)],capture_output=True);assert p.returncode!=0
        duplicate=d/'duplicate.pptx'
        with zipfile.ZipFile(source) as a,zipfile.ZipFile(duplicate,'w',zipfile.ZIP_DEFLATED) as b:
            for info in a.infolist():
                content=a.read(info)
                if info.filename=='ppt/_rels/presentation.xml.rels':
                    from copy import deepcopy
                    tree=ET.fromstring(content);tree.append(deepcopy(next(r for r in tree if r.get('Type','').endswith('/slide'))));content=ET.tostring(tree)
                b.writestr(info,content)
        run('reject',duplicate)
        print(json.dumps({'native_core':'pass','large':large,'units':len(units),'output_bytes':output.stat().st_size}))

if __name__=='__main__':check('--large' in sys.argv)
