"""Build a local, self-contained before/after SVG boundary inspector."""
import argparse
import base64
import gzip
import json
from pathlib import Path
import shapely
from compile_reviewed_svg_height_map import polygon


def main(root):
    before=json.loads((root/'before/boundary-audit.json').read_text())
    after=json.loads((root/'boundary-audit.json').read_text())
    old={r['id']:r for r in before['cases']}
    # Include remaining flags plus the strongest original defects. Deduplicate
    # locations so both orientations do not fill the entire review queue.
    selected=[];seen=set()
    for r in after['cases'][:12]+before['cases']:
        key=(r['map'],r['side'],tuple(round(v,1) for v in r['originSvg']))
        if key in seen: continue
        seen.add(key);selected.append(r)
        if len(selected)==32:break
    current={}
    wanted={r['id'] for r in selected}
    for line in (root/'cones.jsonl').read_text().splitlines():
        row=json.loads(line)
        if row['id'] in wanted:current[row['id']]=row
    models={};cases=[]
    for r in selected:
        key=f"{r['map']}-{r['side']}"
        if key not in models:
            model=json.loads(gzip.decompress(Path(f"assets/maps/{r['map']}_svg_height_{r['side']}.json.gz").read_bytes()))
            svg=Path(f"assets/maps/{r['map']}_map{'_defense' if r['side']=='defense' else ''}.svg").read_bytes()
            models[key]=dict(viewBox=model['viewBox'],walls=model['walls'],receiver=model['receiver'],
                artwork='data:image/svg+xml;base64,'+base64.b64encode(svg).decode())
        baseline=old.get(r['id'],r)
        issue=dict(max(r['issues'],key=lambda i:abs(i['errorSvg'])))
        active=set(current[r['id']]['activeWallIds'])
        issue['nearestActiveInkSvg']=min((shapely.Point(issue['actual']).distance(polygon(w))
            for w in models[key]['walls'] if w['id'] in active),default=None)
        cases.append(dict(id=r['id'],model=key,kind=r['kind'],origin=r['originSvg'],eye=r['eyeElevationMeters'],
            support=r.get('supportId'),before=baseline['polygonSvg'],current=current[r['id']]['polygonSvg'],
            active=current[r['id']]['activeWallIds'],issue=issue))
    skill=Path.home()/'.agents/skills/blueprint-docs/assets'
    html=(skill/'skeleton.html').read_text(encoding='utf-8')
    css=(skill/'blueprint.css').read_text(encoding='utf-8')
    html=html.replace('/* Inline assets/blueprint.css here, verbatim. */',css)
    html=html.replace('DOCUMENT TITLE','Icarus SVG boundary inspector').replace('◆</span> PLAN','◆</span> AUDIT')
    content='''<article class="document-flow">
<p class="kicker">Icarus · Icebox · Boundary audit</p>
<h1 id="top">Trace a cone edge to the SVG wall that stops it</h1>
<p class="lede">The audit checks actual native cone polygons against independent intersections with the painted SVG footprints. Switch between the original cone and the correction, then zoom into the flagged contact. Height values explain whether each wall is active; this geometric check does not certify the height assignment against live gameplay.</p>
<h2 id="inspect">Inspect the flagged contact</h2>
<div class="controls"><label>Case <select id="case"></select></label>
<label>View <select id="mode"><option value="current">Corrected</option><option value="before">Before</option><option value="overlay">Overlay</option></select></label>
<label>Width <input id="zoom" type="range" min="4" max="160" value="24" step="1"></label>
<button id="context">Show observer</button><button id="contact">Focus contact</button>
<label><input id="walls" type="checkbox"> Highlight active walls</label></div>
<div class="diagram"><svg id="scene" role="img" aria-label="Zoomable SVG map and visibility boundary" style="width:100%;height:540px;touch-action:none"></svg></div>
<p class="caption">Drag to pan. Hover a wall for its ID and height intervals. The map image is the original SVG. The cone is clipped to the original floor fill. Corrected = green; before = red; the dashed line marks the flagged ray.</p>
<pre id="readout" style="white-space:pre-wrap"></pre><p class="source">Source: bundled SVG height models, native cone export, independent GEOS boundary audit. Distances use SVG units; the width control determines display magnification.</p>
<details class="appendix"><summary>Audit scope and measurements</summary><pre id="evidence" style="white-space:pre-wrap"></pre></details>
<p class="colophon">Generated for local Icarus review · SVG boundary attribution v1 · 2026-09-07</p>
</article>'''
    start=html.index('<article class="document-flow">');end=html.index('</article>',start)+len('</article>')
    html=html[:start]+content+html[end:]
    styles='''<style>.controls{display:flex;flex-wrap:wrap;gap:12px;padding:12px 0;font-family:var(--mono);font-size:12px}.controls select,.controls button{background:var(--bg-inset);color:var(--fg);border:1px solid var(--line);padding:6px;max-width:260px}.controls label{display:flex;align-items:center;gap:6px}#scene{background:var(--bg-sunken);cursor:grab}#scene:active{cursor:grabbing}.diagram{overflow:hidden}</style>'''
    payload=json.dumps(dict(models=models,cases=cases,summary={k:v for k,v in after.items() if k!='cases'}),separators=(',',':')).replace('</','<\\/')
    js=r'''
const audit=JSON.parse(document.getElementById('audit-data').textContent), ns='http://www.w3.org/2000/svg';
const $=id=>document.getElementById(id), scene=$('scene');
let selected=0, center=[0,0], width=24, drag=null;
function el(tag,attrs,parent=scene){const n=document.createElementNS(ns,tag);for(const [k,v]of Object.entries(attrs))n.setAttribute(k,v);parent.append(n);return n;}
function path(rings){return rings.map(r=>{let s='M'+r[0]+','+r[1];for(let i=2;i<r.length;i+=2)s+='L'+r[i]+','+r[i+1];return s+'Z'}).join('');}
function poly(points){return points.map(p=>p.join(',')).join(' ')}
function position(){scene.setAttribute('viewBox',`${center[0]-width/2} ${center[1]-width/2} ${width} ${width}`)}
function wallText(w,c){return `${w.id}
${c.active.includes(w.id)?'BLOCKS':'CLEAR'} at eye ${c.eye.toFixed(4)} m
Solid height intervals: ${w.bands.map(b=>`${(b[0]+w.floorElevationMeters).toFixed(4)} to ${b[1]===null?'unbounded':(b[1]+w.floorElevationMeters).toFixed(4)} m`).join('; ')||'none'}`;}
function details(){const c=audit.cases[selected];return `${c.id} · ${c.kind}
Observer: ${c.origin.map(v=>v.toFixed(4)).join(', ')} SVG · eye ${c.eye.toFixed(4)} m
Support: ${c.support||'primary ground'}
Flag: ${c.issue.kind} · ray difference ${c.issue.errorSvg.toFixed(6)} SVG
Distance from flagged edge to nearest active ink: ${c.issue.nearestActiveInkSvg?.toFixed(6)??'none'} SVG
Expected blocking wall: ${c.issue.wallId||'none before range limit'}
View width: ${width.toFixed(1)} SVG units`;}
function draw(){const c=audit.cases[selected],m=audit.models[c.model];scene.replaceChildren();position();
const share=new URL(location.href);share.searchParams.set('case',selected);share.searchParams.set('mode',$('mode').value);share.searchParams.set('width',width);history.replaceState(null,'',share);
const defs=el('defs',{}),clip=el('clipPath',{id:'receiver'},defs);for(const r of m.receiver)el('path',{d:path(r.rings),'fill-rule':r.fillRule||'evenodd'},clip);
el('image',{href:m.artwork,x:m.viewBox[0],y:m.viewBox[1],width:m.viewBox[2],height:m.viewBox[3]});
const mode=$('mode').value;
if(mode!=='current')el('polygon',{points:poly(c.before),fill:'var(--danger)','fill-opacity':'.35','clip-path':'url(#receiver)'});
if(mode!=='before')el('polygon',{points:poly(c.current),fill:'var(--ok)','fill-opacity':'.35','clip-path':'url(#receiver)'});
for(const w of m.walls){const p=el('path',{d:path(w.rings),'fill-rule':w.fillRule,fill:$('walls').checked&&c.active.includes(w.id)?'var(--accent)':'transparent','fill-opacity':'.45','pointer-events':'fill'});p.addEventListener('pointermove',()=>{$('readout').textContent=details()+'\n\n'+wallText(w,c)});}
el('line',{x1:c.origin[0],y1:c.origin[1],x2:c.issue.expected[0],y2:c.issue.expected[1],stroke:'var(--accent)','stroke-width':1,'stroke-dasharray':'4 4','vector-effect':'non-scaling-stroke','pointer-events':'none'});
el('circle',{cx:c.issue.actual[0],cy:c.issue.actual[1],r:width*.004,fill:'var(--danger)','pointer-events':'none'});
el('circle',{cx:c.origin[0],cy:c.origin[1],r:width*.007,fill:'var(--accent)','pointer-events':'none'});
$('readout').textContent=details();}
audit.cases.forEach((c,i)=>{const o=document.createElement('option');o.value=i;o.textContent=c.id;$('case').append(o)});
$('case').onchange=()=>{selected=+$('case').value;focus()};
function focus(){center=[...audit.cases[selected].issue.actual];width=+$('zoom').value;draw()}
$('contact').onclick=focus;$('context').onclick=()=>{center=[...audit.cases[selected].origin];width=160;$('zoom').value=width;draw()};
$('zoom').oninput=()=>{width=+$('zoom').value;draw()};$('mode').onchange=draw;$('walls').onchange=draw;
scene.onpointerdown=e=>{drag=[e.clientX,e.clientY,...center];scene.setPointerCapture(e.pointerId)};
scene.onpointermove=e=>{if(!drag)return;const scale=width/Math.min(scene.clientWidth,scene.clientHeight);center=[drag[2]-(e.clientX-drag[0])*scale,drag[3]-(e.clientY-drag[1])*scale];position()};
scene.onpointerup=()=>drag=null;scene.onpointercancel=()=>drag=null;
const params=new URLSearchParams(location.search);
selected=Math.max(0,Math.min(audit.cases.length-1,Number(params.get('case')||0)));
$('case').value=selected;
if(['before','current','overlay'].includes(params.get('mode'))) $('mode').value=params.get('mode');
if(params.has('width')) $('zoom').value=Math.max(4,Math.min(160,Number(params.get('width'))));
$('evidence').textContent=JSON.stringify(audit.summary,null,2);focus();
'''
    html=html.replace('</head>',styles+'</head>').replace('</body>','<script id="audit-data" type="application/json">'+payload+'</script><script>'+js+'</script></body>')
    (root/'inspector.html').write_text(html,encoding='utf-8')
    print(root/'inspector.html')


if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('root',type=Path);main(p.parse_args().root)
