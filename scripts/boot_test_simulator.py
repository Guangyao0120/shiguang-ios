import json,os,subprocess

def run(*args,timeout=60):return subprocess.run(args,check=True,capture_output=True,text=True,timeout=timeout).stdout
runtimes=json.loads(run('xcrun','simctl','list','runtimes','-j'))['runtimes']
runtime=next(r['identifier'] for r in runtimes if r.get('isAvailable') and '.iOS-26' in r['identifier'])
types=json.loads(run('xcrun','simctl','list','devicetypes','-j'))['devicetypes']
device=next(t['identifier'] for t in types if t['name']=='iPhone 17 Pro')
for attempt in range(2):
    identifier=run('xcrun','simctl','create',f'Shiguang-Review-{attempt}',device,runtime).strip()
    print('Booting fresh test device',identifier,flush=True)
    subprocess.run(['open','-a',os.path.join(os.environ['DEVELOPER_DIR'],'Applications/Simulator.app'),'--args','-CurrentDeviceUDID',identifier],check=False)
    subprocess.run(['xcrun','simctl','boot',identifier],check=False,timeout=60)
    try:
        result=run('xcrun','simctl','bootstatus',identifier,'-b',timeout=180)
        print(result,flush=True)
        with open(os.environ['GITHUB_ENV'],'a') as f:f.write('DEVICE_ID='+identifier+'\n')
        break
    except subprocess.TimeoutExpired:
        print('Device startup timed out; restarting with another fresh device',flush=True)
        subprocess.run(['xcrun','simctl','shutdown',identifier],timeout=30,check=False)
else:raise SystemExit('Simulator infrastructure failed to boot within bounded retries')
