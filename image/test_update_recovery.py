"""Compare deployed recovery files from real Ansible and RPM assembly logic."""
import ast
import copy
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]


class RecoveryParity(unittest.TestCase):
    def test_both_installers_deploy_the_same_recovery_protocol_and_login_barrier(self):
        names = {
            'Install transactional Btrfs recovery helper',
            'Install the durable update transaction helpers',
            'Install the interrupted-update boot recovery unit',
            'Create the login recovery dependency directories',
            'Block login if interrupted-update recovery fails',
            'Install Fedora upgrade validation units',
        }
        tasks = [copy.deepcopy(task) for task in yaml.safe_load(
            (ROOT / 'roles/base/tasks/main.yml').read_text()) if task.get('name') in names]
        self.assertEqual({task['name'] for task in tasks}, names)
        with tempfile.TemporaryDirectory(prefix='cybexos-recovery-parity-') as temporary:
            directory = Path(temporary)
            checkout, payload = directory / 'checkout', directory / 'rpm'
            for relative in ('usr/local/libexec', 'etc/systemd/system'):
                (checkout / relative).mkdir(parents=True)
            for task in tasks:
                task['become'] = False
                options = task.get('ansible.builtin.copy') or task['ansible.builtin.file']
                for key in ('owner', 'group'):
                    options.pop(key, None)
                destination = 'dest' if 'dest' in options else 'path'
                options[destination] = '{{ fixture_root }}' + options[destination]
                if 'src' in options:
                    options['src'] = str(ROOT / 'roles/base/files') + '/' + options['src']
            playbook = directory / 'recovery.yml'
            playbook.write_text(yaml.safe_dump([{
                'hosts': 'localhost', 'connection': 'local', 'gather_facts': False,
                'vars': {'fixture_root': str(checkout)}, 'tasks': tasks,
            }]))
            result = subprocess.run(['ansible-playbook', '-i', 'localhost,', str(playbook)],
                                    capture_output=True, text=True, timeout=60)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

            # Execute the real contiguous recovery assembly section; unrelated
            # application downloads and privileged image construction stay out
            # of this disposable-filesystem contract test.
            main = next(node for node in ast.parse((ROOT / 'image/package').read_text()).body
                        if isinstance(node, ast.FunctionDef) and node.name == 'main')
            start = next(index for index, node in enumerate(main.body)
                         if isinstance(node, ast.Expr) and isinstance(node.value, ast.Call)
                         and isinstance(node.value.func, ast.Name) and node.value.func.id == 'copy'
                         and node.value.args and isinstance(node.value.args[0], ast.Constant)
                         and node.value.args[0].value == 'roles/base/files/cybexos-system-snapshot')
            end = next(index for index, node in enumerate(main.body)
                       if isinstance(node, ast.Assign) and isinstance(node.value, ast.Constant)
                       and node.value.value == 'roles/base/files/recovery')

            def write(relative, content, executable=False):
                target = payload / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text(content)
                target.chmod(0o755 if executable else 0o644)

            def package_copy(source, relative, executable=False):
                write(relative, (ROOT / source).read_text(), executable)

            exec(compile(ast.Module(body=main.body[start:end], type_ignores=[]),
                         str(ROOT / 'image/package'), 'exec'),
                 {'ROOT': ROOT, 'payload': payload, 'write': write, 'copy': package_copy})
            source_files = sorted(path for path in checkout.rglob('*') if path.is_file())
            self.assertGreaterEqual(len(source_files), 13)
            for source in source_files:
                relative = source.relative_to(checkout).as_posix()
                installed = relative.replace('usr/local/libexec/', 'usr/libexec/').replace(
                    'etc/systemd/system/', 'usr/lib/systemd/system/')
                expected = source.read_text()
                if relative.startswith('etc/systemd/system/'):
                    expected = expected.replace('/usr/local/libexec/cybexos-', '/usr/libexec/cybexos-')
                self.assertEqual((payload / installed).read_text(), expected, relative)
                self.assertEqual(os.access(source, os.X_OK), os.access(payload / installed, os.X_OK))
            # Every shipped recovery artifact must be covered by the RPM file
            # manifest, including the new user-sessions dependency directory.
            spec = (ROOT / 'image/cybexos-desktop.spec').read_text()
            self.assertIn('/usr/libexec/cybexos-*', spec)
            self.assertIn('/usr/lib/systemd/system/sddm.service.d/', spec)
            self.assertIn('/usr/lib/systemd/system/systemd-user-sessions.service.d/60-cybexos-update-recover.conf', spec)


if __name__ == '__main__':
    unittest.main()
