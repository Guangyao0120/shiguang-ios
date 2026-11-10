"""Boot one headless simulator matching the selected Xcode SDK."""
import json
import os
import subprocess


def read(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True,
                          timeout=240).stdout


sdk = read('xcrun', '--sdk', 'iphonesimulator', '--show-sdk-version').strip()
runtimes = json.loads(read('xcrun', 'simctl', 'list', 'runtimes', '-j'))['runtimes']
runtime = next(r['identifier'] for r in runtimes
               if r.get('isAvailable') and r.get('version') == sdk)
types = json.loads(read('xcrun', 'simctl', 'list', 'devicetypes', '-j'))['devicetypes']
device = next(t['identifier'] for t in types if t['name'] == 'iPhone 17 Pro')
identifier = read('xcrun', 'simctl', 'create', 'Shiguang-Review', device, runtime).strip()
print('Booting one headless test device:', runtime, identifier, flush=True)
# Simulator.app can boot an additional default device and contend for VM memory.
try:
    subprocess.run(['xcrun', 'simctl', 'bootstatus', identifier, '-b'],
                   check=True, timeout=480)
except (subprocess.TimeoutExpired, subprocess.CalledProcessError):
    subprocess.run(['xcrun', 'simctl', 'list', 'devices', '-j'], timeout=30)
    raise
with open(os.environ['GITHUB_ENV'], 'a') as output:
    output.write('DEVICE_ID=' + identifier + '\n')
