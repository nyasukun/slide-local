"""Run the same renderer policy plus one exact test-binary exec permission. Only the parent-owned loopback fixtures can be addressed; never send data."""
from pathlib import Path
import subprocess,tempfile,shutil,os,socket
ROOT=Path(__file__).resolve().parents[1]
root=Path(tempfile.mkdtemp(prefix='slp-check-',dir='/private/tmp'))
fd,canary=tempfile.mkstemp(prefix='slp-denied-',dir='/private/tmp');os.write(fd,b'DUMMY_NOT_A_SECRET');os.close(fd)
listeners=[]
try:
 for family,address in [(socket.AF_INET,('127.0.0.1',0)),(socket.AF_INET6,('::1',0))]:
  listener=socket.socket(family,socket.SOCK_STREAM);listener.bind(address);listener.listen(1);listener.settimeout(.1);listeners.append(listener)
 for name in ['home','tmp']:(root/name).mkdir()
 binary=root/'probe'
 subprocess.run(['/usr/bin/clang',str(ROOT/'tests/RendererPolicyProbe.c'),'-o',str(binary)],check=True)
 policy=subprocess.check_output([str(ROOT/'.cache/native-tests/preview-smoke'),'policy'],text=True)
 policy+='\n(allow process-exec (literal "'+str(binary)+'"))\n'
 (root/'profile.sb').write_text(policy)
 env={'PATH':'/usr/bin:/bin','HOME':str(root/'home'),'TMPDIR':str(root/'tmp')+'/','LANG':'en_US.UTF-8'}
 result=subprocess.run(['/usr/bin/sandbox-exec','-D','RENDER_ROOT='+str(root),'-D','LO_APP=/Applications/LibreOffice.app','-D','USER_FONTS='+str(Path.home()/'Library/Fonts'),'-f',str(root/'profile.sb'),str(binary),canary,str(listeners[0].getsockname()[1]),str(listeners[1].getsockname()[1])],env=env,cwd=root,capture_output=True,text=True,timeout=10)
 print(result.stdout,end='');print(result.stderr,end='')
 assert result.returncode==0, 'renderer policy connection check failed'
 for listener in listeners:
  try:
   connection,_=listener.accept();connection.close();raise AssertionError('sandbox reached loopback fixture')
  except socket.timeout:pass
finally:
 for listener in listeners:listener.close()
 shutil.rmtree(root);os.unlink(canary)
