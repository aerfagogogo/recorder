import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {spawn, execFileSync} from 'node:child_process';
import assert from 'node:assert/strict';

const root = fs.mkdtempSync(path.join(os.tmpdir(), 'recorder-monitor-test-'));
const ffmpeg = '/opt/homebrew/bin/ffmpeg';
const core = process.argv[2];
assert(core, 'Pass the staged recording core path');
const app = path.join(root, 'MeterTest.app');
fs.mkdirSync(path.join(app, 'Contents/MacOS'), {recursive:true});
fs.writeFileSync(path.join(app, 'Contents/Info.plist'), `<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.sunyiting.recorder-meter-test</string><key>CFBundleExecutable</key><string>MeterTest</string><key>CFBundleName</key><string>MeterTest</string><key>CFBundlePackageType</key><string>APPL</string><key>LSUIElement</key><true/></dict></plist>`);
const executable = path.join(app, 'Contents/MacOS/MeterTest');
execFileSync('swiftc', ['scripts/monitor-test-player.swift', '-o', executable]);
const tone = path.join(root, 'tone.wav');
execFileSync(ffmpeg, ['-v','error','-f','lavfi','-i','sine=frequency=1000:duration=2:sample_rate=48000','-af','volume=0.2',tone]);
const sleep = ms => new Promise(resolve=>setTimeout(resolve,ms));
const player = spawn(executable, [tone]);
let capture;
try {
  await sleep(1500);
  const output = path.join(root,'capture.flac');
  capture = spawn(core, ['--app','com.sunyiting.recorder-meter-test','--output',output,'--silence-seconds','0','--no-trim','--max-seconds','16']);
  let out='', err='';
  capture.stdout.on('data',b=>out+=b);
  capture.stderr.on('data',b=>err+=b);
  const ended = new Promise(resolve=>capture.on('exit',resolve));
  for(let i=0;i<80&&!out.includes('CAPTURE_READY')&&capture.exitCode===null;i++) await sleep(100);
  assert(out.includes('CAPTURE_READY'), `Capture not ready: ${out} ${err}`);
  await sleep(2000);
  capture.kill('SIGUSR1');
  await sleep(3000);
  assert(err.includes('MONITOR_MUTED=1'), `No mute acknowledgement: ${err}`);
  capture.kill('SIGUSR2');
  await sleep(2000);
  assert(err.split('MONITOR_MUTED=0').length>=3, `No unmute acknowledgement: ${err}`);
  capture.kill('SIGINT');
  assert.equal(await ended,0,err);
  const pcm=execFileSync(ffmpeg,['-v','error','-i',output,'-f','f32le','-ac','1','-ar','48000','pipe:1'], {maxBuffer:8*1024*1024});
  const rms=(start,end)=>{let sum=0,n=0;for(let i=start*48000*4;i<end*48000*4;i+=4){const x=pcm.readFloatLE(i);sum+=x*x;n++}return 20*Math.log10(Math.sqrt(sum/n));};
  const normal=rms(1,2), muted=rms(3,4), restored=rms(6,7);
  assert(normal > -50 && Math.abs(normal-muted)<0.2 && Math.abs(normal-restored)<0.2, JSON.stringify({normal,muted,restored}));
  console.log(JSON.stringify({pass:true,normalDBFS:normal,mutedDBFS:muted,restoredDBFS:restored,readback:'unmuted → mutedWhenTapped → unmuted',output}));
} finally {
  if(capture?.exitCode===null) capture.kill('SIGINT');
  player.kill('SIGTERM');
  // Keep diagnostics outside the user's music library for inspection.
  console.log(`Diagnostics: ${root}`);
}
