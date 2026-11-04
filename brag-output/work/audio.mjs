import { writeFileSync } from 'node:fs';
const SR = 44100, DUR = 21.5, N = Math.ceil(SR*DUR);
const L = new Float32Array(N), R = new Float32Array(N), sendL = new Float32Array(N), sendR = new Float32Array(N);
const duck = new Float32Array(N).fill(1);
const mtof = m => 440*Math.pow(2,(m-69)/12);
const nm = {C:0,'C#':1,D:2,E:4,F:5,G:7,A:9,B:11};
const note = s => { const m = s.match(/^([A-G]#?)(\d)$/); return 12*(+m[2]+1)+nm[m[1]]; };
let seed = 7; const rnd = () => (seed = (seed*16807)%2147483647)/2147483647*2-1;
function add(i, v, pan=0, send=0) { if (i<0||i>=N) return; const gl = Math.cos((pan+1)*Math.PI/4), gr = Math.sin((pan+1)*Math.PI/4); L[i]+=v*gl; R[i]+=v*gr; sendL[i]+=v*gl*send; sendR[i]+=v*gr*send; }

// voices
function pluck(t, m, amp, pan=0, send=0.35, dec=3.2) { const f = mtof(m), s0 = Math.floor(t*SR), len = Math.floor(SR*1.6);
  for (let k=0;k<len;k++) { const x=k/SR; const env = Math.min(1, x/0.004)*Math.exp(-x*dec);
    const v = Math.sin(2*Math.PI*f*x) + 0.35*Math.sin(2*Math.PI*2*f*x)*Math.exp(-x*6) + 0.12*Math.sin(2*Math.PI*3*f*x)*Math.exp(-x*10);
    add(s0+k, v*env*amp, pan, send); } }
function bell(t, m, amp, pan=0, send=0.5) { const f = mtof(m), s0 = Math.floor(t*SR), len = Math.floor(SR*2.2);
  for (let k=0;k<len;k++) { const x=k/SR; const env = Math.min(1,x/0.003)*Math.exp(-x*2.6);
    const v = Math.sin(2*Math.PI*f*x + 0.8*Math.sin(2*Math.PI*f*3.5*x)*Math.exp(-x*5)) ; add(s0+k, v*env*amp, pan, send); } }
function pad(t0, t1, notes, amp) { const s0=Math.floor(t0*SR), s1=Math.floor(t1*SR); let lp=[0,0];
  for (const [ni,m] of notes.entries()) { const f = mtof(m); lp=[0,0];
    for (let i=s0;i<s1+SR*0.6;i++) { const x=(i-s0)/SR, rel=(i-s1)/SR; const env = Math.min(1,x/0.35)*(i>s1?Math.exp(-rel*6):1);
      for (const [c,det,pan] of [[0,-0.12,-0.6],[1,0.12,0.6]]) { const ff=f*Math.pow(2,det/12); const ph=(ff*x)%1; const saw = 2*ph-1;
        lp[c] += 0.06*(saw - lp[c]); add(i, lp[c]*env*amp*duck[Math.min(i,N-1)], pan, 0.25); } } } }
function bass(t, m, len, amp) { const f=mtof(m), s0=Math.floor(t*SR);
  for (let k=0;k<SR*len;k++){ const x=k/SR; const env=Math.min(1,x/0.01)*Math.exp(-x*2.2)*(x>len-0.05?(len-x)/0.05:1); add(s0+k,(Math.sin(2*Math.PI*f*x)+0.2*Math.sin(4*Math.PI*f*x))*env*amp,0,0); } }
function kick(t, amp) { const s0=Math.floor(t*SR); let ph=0;
  for (let k=0;k<SR*0.35;k++){ const x=k/SR; const f=45+90*Math.exp(-x*35); ph+=2*Math.PI*f/SR; add(s0+k, Math.sin(ph)*Math.exp(-x*9)*amp,0,0); }
  for (let k=0;k<SR*0.45;k++){ const i=s0+k; if(i<N) duck[i]=Math.min(duck[i], 1-0.45*Math.exp(-k/SR*7)); } }
function noiseHit(t, len, amp, hp=0.6, pan=0, send=0.2, att=0.002) { const s0=Math.floor(t*SR); let prev=0;
  for (let k=0;k<SR*len;k++){ const x=k/SR; const n=rnd(); const h=n-prev*hp; prev=n; add(s0+k, h*Math.min(1,x/att)*Math.exp(-x*(5/len))*amp, pan, send); } }
function swell(t0, t1, amp, send=0.5) { const s0=Math.floor(t0*SR), s1=Math.floor(t1*SR); let lp=0;
  for (let i=s0;i<s1;i++){ const k=(i-s0)/(s1-s0); const c=0.01+0.25*k*k; lp+=c*(rnd()-lp); const env=Math.pow(k,2)*(k>0.92?(1-k)/0.08:1); add(i, lp*env*amp, Math.sin(k*6)*0.5, send); } }

// harmony
const CH = { Am:['A','C','E'], F:['F','A','C'], C:['C','E','G'], G:['G','B','D'] };
const prog = [[0,2,'Am'],[2,4,'F'],[4,6,'C'],[6,8,'G'],[8,10,'Am'],[10,12,'F'],[12,14,'C'],[14,16,'G'],[16,17,'F'],[17,18,'G'],[18,21.5,'C']];
// kicks first (they write the duck curve used by the pad)
for (let b=3.0; b<17.9; b+=0.5) kick(b, b<7?0.5:0.6);
kick(18.0, 0.7);
for (const [a,b,c] of prog) {
  const ns = CH[c].map(n=>note(n+'3')); if (c==='G'||c==='F') ns[0]-=0; pad(a, b, [...ns, note(CH[c][0]+'4')], a<3?0.10:0.13);
  const root = note(CH[c][0]+'2');
  if (a>=3) { for (let x=a; x<b-0.01; x+=1) { bass(x, root, 0.45, 0.32); if (x+0.75<b) bass(x+0.75, root, 0.22, 0.2); } }
  else if (a===0) bass(0.3, root, 1.6, 0.18);
  // arpeggio (8ths), sparser in the hook
  const arp = [CH[c][0]+'4', CH[c][1]+'4', CH[c][2]+'4', CH[c][0]+'5', CH[c][2]+'4', CH[c][1]+'4', CH[c][0]+'5', CH[c][2]+'5'].map(note);
  const step = a<3 ? 0.5 : 0.25, stop = c==='C'&&a===18 ? 18.01 : b;
  let j=0; for (let x=a; x<stop-0.01; x+=step, j++) pluck(x, arp[j%arp.length], a<3?0.07:0.06, (j%2?0.35:-0.35), 0.4);
}
// hats from scene 3
for (let x=7.25; x<17.9; x+=0.5) noiseHit(x, 0.06, 0.035, 0.95, 0.3, 0.05);

// transitions
swell(2.0, 3.0, 0.22); noiseHit(3.0, 1.2, 0.05, 0.2, 0, 0.8, 0.01); bass(3.0, note('A1'), 1.0, 0.35);
swell(6.3, 7.0, 0.12); swell(14.5, 15.05, 0.12); swell(17.3, 18.0, 0.18);
// logo build: node plinks in key (A minor pentatonic up)
['A5','C6','E6','G6','A6'].forEach((n,i)=>bell(3.35+i*0.07, note(n), 0.05, -0.4+i*0.2, 0.6));
['C6','E6','G6','C7'].forEach((n,i)=>bell(18.3+i*0.07, note(n), 0.05, -0.3+i*0.2, 0.6));
// final chord bloom
pad(18.0, 21.2, ['C3','G3','E4','G4','C5'].map(note), 0.08);
bell(18.0, note('C5'), 0.06, 0, 0.7); bell(18.0, note('G5'), 0.04, 0.3, 0.7);
// scene 3 sfx
noiseHit(7.6, 0.03, 0.05, 0.9, 0.5, 0.2);                      // menu open tick
bell(8.45, note('E6'), 0.09, 0.6, 0.5); bell(8.57, note('A6'), 0.07, 0.6, 0.5);   // phone chime
swell(8.85, 9.4, 0.08, 0.6);                                     // fly whoosh
const REPLY='On my way!'; for (let i=1;i<=REPLY.length;i++) noiseHit(9.9 + (i/REPLY.length)*0.55 - 0.02, 0.025, 0.035, 0.97, -0.2+0.04*i, 0.1);
noiseHit(10.53, 0.03, 0.06, 0.9, 0, 0.2); bell(10.68, note('C6'), 0.06, -0.3, 0.6); bell(10.78, note('G6'), 0.05, -0.3, 0.6);  // send + sent
bell(10.85, note('E6'), 0.05, 0.6, 0.5);                         // phone confirms
// scene 4 sfx: edge crossing shimmer, click, toggle on
['E5','G5','A5','C6','E6'].forEach((n,i)=>bell(12.5+i*0.04, note(n), 0.035, -0.2+i*0.2, 0.7));
noiseHit(13.47, 0.02, 0.08, 0.92, 0.6, 0.15); bell(13.55, note('G6'), 0.06, 0.6, 0.5);
// scene 5 chips: soft plinks
const pent=['C5','D5','E5','G5','A5','C6','D6']; for (let i=0;i<14;i++) bell(15.45+i*0.075, note(pent[i%7]) + (i>=7?12:0)-12, 0.025, -0.6+i*0.09, 0.6);

// reverb (Schroeder) on the send bus
function reverb(inp, combs, aps) { const out = new Float32Array(N);
  for (const [d,fb] of combs) { const buf=new Float32Array(d); let p=0, lp=0; for (let i=0;i<N;i++){ const y=buf[p]; lp = y*0.7 + lp*0.3; buf[p]=inp[i]+lp*fb; p=(p+1)%d; out[i]+=y/combs.length; } }
  for (const d of aps) { const buf=new Float32Array(d); let p=0; for (let i=0;i<N;i++){ const b=buf[p]; const y=-out[i]+b; buf[p]=out[i]+b*0.5; p=(p+1)%d; out[i]=y; } }
  return out; }
const rl = reverb(sendL, [[1557,.84],[1617,.84],[1491,.84],[1422,.84]], [225,556]);
const rr = reverb(sendR, [[1580,.84],[1640,.84],[1514,.84],[1445,.84]], [248,579]);
for (let i=0;i<N;i++){ L[i]+=rl[i]*0.9; R[i]+=rr[i]*0.9; }
// master: fade in/out, soft clip, normalize
let pk=0; for (let i=0;i<N;i++){ const t=i/SR; const f=Math.min(1,t/0.05)*Math.min(1,(DUR-t)/1.2); L[i]=Math.tanh(L[i]*1.2*f); R[i]=Math.tanh(R[i]*1.2*f); pk=Math.max(pk,Math.abs(L[i]),Math.abs(R[i])); }
const g = 0.89/pk; const buf = Buffer.alloc(44+N*4);
buf.write('RIFF',0); buf.writeUInt32LE(36+N*4,4); buf.write('WAVEfmt ',8); buf.writeUInt32LE(16,16); buf.writeUInt16LE(1,20); buf.writeUInt16LE(2,22); buf.writeUInt32LE(SR,24); buf.writeUInt32LE(SR*4,28); buf.writeUInt16LE(4,32); buf.writeUInt16LE(16,34); buf.write('data',36); buf.writeUInt32LE(N*4,40);
for (let i=0;i<N;i++){ buf.writeInt16LE(Math.round(L[i]*g*32767),44+i*4); buf.writeInt16LE(Math.round(R[i]*g*32767),46+i*4); }
writeFileSync('music.wav', buf); console.log('peak', pk.toFixed(2));
