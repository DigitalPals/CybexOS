"""Shared real-desktop and saved-preference checks for both installer paths."""
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def desktop_lifecycle(vm):
    helper = (ROOT / 'tests/lib/quickshell-live').read_text()
    test = (ROOT / 'tests/system-settings-live').read_text().split('qs_live_begin\n', 1)[1]
    script = 'set -euo pipefail\nexport XDG_RUNTIME_DIR=/run/user/$(id -u)\n' + helper + '\nqs_live_begin\n' + test
    try:
        subprocess.run([*vm.ssh, 'bash -s'], input=script, text=True, capture_output=True, check=True, timeout=300)
    except subprocess.CalledProcessError as error:
        detail = ((error.stdout or '') + (error.stderr or ''))[-4000:]
        raise RuntimeError('Managed Settings lifecycle failed: ' + detail) from error


SAVED_CHOICES = r'''
import json, os, pwd
from pathlib import Path
account=pwd.getpwnam('qualification')
home=Path(account.pw_dir)
path=home / '.config/cybexos/shell.json'
data=json.loads(path.read_text())
data['position']='bottom'
data['qualificationFuture']={'preserve':[False,0,'user-owned']}
path.write_text(json.dumps(data,indent=2)+'\n')
files={
    '.config/cybexos/input.json': json.dumps({'v':1,'keyboard':{'layouts':[{'layout':'us','variant':''},{'layout':'nl','variant':''}], 'shortcut':'grp:alt_shift_toggle'}, 'touchpad':{'tap':False,'naturalScroll':False,'sensitivity':0.25},'qualificationFuture':True})+'\n',
    '.config/cybexos/hypr/user.lua': 'hl.config({ input = { repeat_rate = 37 } })\n',
    'qualification-personal-marker': 'qualification-preserve\n',
}
for relative, value in files.items():
    target=home / relative
    target.parent.mkdir(parents=True,exist_ok=True)
    target.write_text(value)
    os.chown(target,account.pw_uid,account.pw_gid)
os.chown(path,account.pw_uid,account.pw_gid)
'''


def prepare_saved_choices(vm, password, root_script):
    root_script(vm, "python3 - <<'PY'\n" + SAVED_CHOICES + '\nPY\n', password)


def verify_saved_choices(vm, password, root_script):
    root_script(vm, r'''python3 - <<'PY'
import json
from pathlib import Path
home=Path('/home/qualification')
data=json.loads((home / '.config/cybexos/shell.json').read_text())
assert data['position']=='bottom'
assert data['qualificationFuture']=={'preserve':[False,0,'user-owned']}
assert (home / '.config/cybexos/hypr/user.lua').read_text()=='hl.config({ input = { repeat_rate = 37 } })\n'
assert json.loads((home / '.config/cybexos/input.json').read_text())['qualificationFuture'] is True
assert (home / 'qualification-personal-marker').read_text()=='qualification-preserve\n'
PY
''', password)
