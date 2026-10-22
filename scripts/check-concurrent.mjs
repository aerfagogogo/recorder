import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import assert from 'node:assert/strict';
import {spawn, execFileSync} from 'node:child_process';

const root = fs.mkdtempSync(path.join(os.tmpdir(), 'recorder-concurrent-'));
const ffmpeg = '/opt/homebrew/bin/ffmpeg';
const core = process.argv[2];
assert(core, 'Pass recording core path');
const processes = [];
const sleep = ms => new Promise(r=>setTimeout(r,ms));
function run(command,args) {
  const p=spawn(command,args); processes.push(p); p.lines=[]; p.err=''; let buffer='';
  p.stdout.on('data',b=>{buffer+=b; let i; while((i=buffer.indexOf('\n'))>=0){p.lines.push(buffer.slice(0,i));buffer=buffer.slice(i+1);}});
  p.stderr.on('data',b=>p.err+=b);
  return p;
}
function fixture(name) {
  const dir=path.join(root,`${name}.app/Contents`);
  fs.mkdirSync(path.join(dir,'MacOS'),{recursive:true});
  fs.writeFileSync(path.join(dir,'Info.plist'),`<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.sunyiting.recorder-test-${name}</string><key>CFBundleExecutable</key><string>Player</string><key>CFBundleName</key><string>${name}</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>`);
  const exe=path.join(dir,'MacOS/Player');
  execFileSync('swiftc',['scripts/concurrent-test-player.swift','-o',exe]);
  return exe;
}
const messages=p=>p.lines.flatMap(l=>{try{return [JSON.parse(l)]}catch{return []}});
try {
  const music=fixture('music'), video=fixture('video');
  const wav=path.join(root,'music.wav'), mp4=path.join(root,'video.mp4');
  execFileSync(ffmpeg,['-v','error','-f','lavfi','-i','sine=frequency=1000:duration=30:sample_rate=48000','-af','volume=0.2',wav]);
  execFileSync(ffmpeg,['-v','error','-f','lavfi','-i','color=c=blue:s=320x180:r=15:d=30','-f','lavfi','-i','sine=frequency=440:duration=30:sample_rate=48000','-af','volume=0.2','-c:v','mpeg4','-c:a','aac',mp4]);
  run(music,[wav,'music']); await sleep(1500);
  const agent=run('/usr/bin/swift',['AppBundle/NowPlayingAgent.swift',String(process.pid),'com.sunyiting.recorder-test-music']);
  const global=run('/usr/bin/swift',['AppBundle/NowPlayingAgent.swift',String(process.pid)]);
  const output=path.join(root,'isolated.flac');
  const capture=run(core,['--app','com.sunyiting.recorder-test-music','--mute-playback','--output',output,'--no-trim','--silence-seconds','0','--max-seconds','15']);
  const ended=new Promise(r=>capture.on('exit',r));
  for(let i=0;i<100&&!capture.lines.includes('CAPTURE_READY');i++)await sleep(100);
  assert(capture.lines.includes('CAPTURE_READY'),capture.err);
  await sleep(1500);
  run(video,[mp4,'video']);
  await sleep(6500);
  const targeted=messages(agent), all=messages(global);
  assert(all.some(m=>m.title==='Video isolation test'),'Video did not take global Now Playing: '+JSON.stringify(all.slice(-3)));
  assert(targeted.length>10 && targeted.every(m=>m.title==='Music isolation test'),'Target changed or missing: '+agent.err+JSON.stringify(targeted.slice(-3)));
  assert(targeted.at(-1).elapsed-targeted[0].elapsed>5,'Target progress stalled');
  assert(capture.exitCode===null,'Capture stopped during concurrent playback');
  assert(capture.err.includes('MONITOR_MUTED=1'),'Mute was not confirmed');
  capture.kill('SIGINT'); assert.equal(await ended,0,capture.err);
  const pcm=execFileSync(ffmpeg,['-v','error','-i',output,'-f','f32le','-ac','1','-ar','48000','pipe:1'],{maxBuffer:8*1024*1024});
  function amplitude(hz) {let c=0,s=0,n=0;for(let i=4*48000;i<6*48000;i++){const x=pcm.readFloatLE(i*4),a=2*Math.PI*hz*i/48000;c+=x*Math.cos(a);s+=x*Math.sin(a);n++;}return 20*Math.log10(2*Math.hypot(c,s)/n);}
  const musicDB=amplitude(1000),videoDB=amplitude(440);
  assert(musicDB>-50&&videoDB<musicDB-50,JSON.stringify({musicDB,videoDB}));
  console.log(JSON.stringify({pass:true,targetedSamples:targeted.length,globalVideoObserved:true,targetProgressSeconds:targeted.at(-1).elapsed-targeted[0].elapsed,musicDB,videoDB,output}));
} finally {
  fs.writeFileSync(path.join(root,'process-logs.json'),JSON.stringify(processes.map(p=>({pid:p.pid,lines:p.lines,err:p.err})),null,2));
  for(const p of processes)if(p.exitCode===null)p.kill('SIGTERM');
  console.log('Diagnostics: '+root);
}
