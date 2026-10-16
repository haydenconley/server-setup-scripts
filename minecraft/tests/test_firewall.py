"""Exercise repeated firewall application without touching the host firewall."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class FirewallTest(unittest.TestCase):
    def test_repeat_and_change_source_preserve_unrelated_rules(self):
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            state = work / 'state.json'
            state.write_text(json.dumps({'hooks': ['-j ts-input'], 'foreign': ['vpn-nat']}))
            shim = work / 'iptables'
            shim.write_text('''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
p = Path(os.environ['STATE'])
s = json.loads(p.read_text())
a = sys.argv[1:]
if a[:2] == ['-w', '10']: a = a[2:]
result = 0
if '-restore' in Path(sys.argv[0]).name:
    text = sys.stdin.read()
    assert text.startswith('*filter\\n-F CONLEY-HOST-IN\\n')
    assert text.endswith('COMMIT\\n')
    s['rules'] = text
elif a[0] == '-nL': result = 0 if s.get('chain') else 1
elif a[0] == '-N': s['chain'] = True
elif a[0] == '-C': result = 0 if ' '.join(a[2:]) in s['hooks'] else 1
elif a[0] == '-A': s['hooks'].append(' '.join(a[2:]))
else: raise AssertionError(a)
p.write_text(json.dumps(s))
sys.exit(result)
''')
            shim.chmod(0o755)
            (work / 'iptables-restore').symlink_to(shim)
            config = work / 'firewall.conf'
            env = dict(os.environ, STATE=str(state), FIREWALL_CONFIG=str(config))
            # Production uses a fixed system PATH; replace only that declaration
            # in the temporary test copy so all firewall commands are mocked.
            script = work / 'firewall.sh'
            script.write_text((ROOT / 'host-firewall.sh').read_text().replace(
                'export PATH=/usr/sbin:/usr/bin:/sbin:/bin',
                f'export PATH={work}:/usr/bin:/bin'))
            for source in ('192.168.30.1/32', '192.168.30.1/32', '192.168.40.1/32'):
                config.write_text(f'SSH_SOURCE_CIDR={source}\n')
                subprocess.run(['bash', str(script)], env=env, check=True)
            result = json.loads(state.read_text())
            self.assertEqual(result['hooks'], ['-j ts-input', '-j CONLEY-HOST-IN'])
            self.assertEqual(result['foreign'], ['vpn-nat'])
            self.assertIn('-s 192.168.40.1/32', result['rules'])
            self.assertNotIn('192.168.30.1', result['rules'])
            for port in (25, 465, 587):
                self.assertIn(f'--dport {port} -j DROP', result['rules'])
            self.assertLess(result['rules'].index('--dport 22 -j ACCEPT'),
                            result['rules'].index('--dport 22 -j DROP'))


if __name__ == '__main__':
    unittest.main()
