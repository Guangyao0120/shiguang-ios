import json,os,subprocess

def open_simulator(identifier=None):
    args=['open','-a',os.path.join(os.environ['DEVELOPER_DIR'],'Applications/Simulator.app')]
    if identifier: args+=['-n','--args','-CurrentDeviceUDID',identifier]
    try:
        subprocess.run(args,check=False,timeout=15)
    except subprocess.TimeoutExpired:
        print('Simulator UI launch did not return; continuing with simctl boot checks',flush=True)

def run(*args,timeout=90):
    for attempt in range(2):
        try:
            return subprocess.run(args,check=True,capture_output=True,text=True,timeout=timeout).stdout
        except subprocess.TimeoutExpired:
            if attempt: raise
            print('Simulator service cold-start timed out; retrying once',flush=True)
            open_simulator()

open_simulator()
runtimes=json.loads(run('xcrun','simctl','list','runtimes','-j'))['runtimes']
runtime=next(r['identifier'] for r in runtimes if r.get('isAvailable') and '.iOS-26' in r['identifier'])
types=json.loads(run('xcrun','simctl','list','devicetypes','-j'))['devicetypes']
device=next(t['identifier'] for t in types if t['name']=='iPhone 17 Pro')
for attempt in range(2):
    identifier=run('xcrun','simctl','create',f'Shiguang-Review-{attempt}',device,runtime).strip()
    print('Booting fresh test device',identifier,flush=True)
    open_simulator(identifier)
    print('Starting simctl boot',flush=True)
    try:
        subprocess.run(['xcrun','simctl','boot',identifier],check=False,timeout=90)
    except subprocess.TimeoutExpired:
        print('Boot command is still starting; checking actual boot state',flush=True)
    try:
        result=run('xcrun','simctl','bootstatus',identifier,'-b',timeout=180)
        print(result,flush=True)
        with open(os.environ['GITHUB_ENV'],'a') as f:f.write('DEVICE_ID='+identifier+'\n')
        break
    except subprocess.TimeoutExpired:
        print('Device startup timed out; restarting with another fresh device',flush=True)
        subprocess.run(['xcrun','simctl','shutdown',identifier],timeout=30,check=False)
else:raise SystemExit('Simulator infrastructure failed to boot within bounded retries')
