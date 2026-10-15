W=1600
o=[]
def box(x,y,w,h,fill,stroke,lines,tsize=19,bold_first=True,tcol="#1f2933",rx=12):
    o.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{rx}" fill="{fill}" stroke="{stroke}" stroke-width="2.5"/>')
    n=len(lines); lh=tsize*1.35; ty=y+h/2-(n-1)*lh/2+tsize*0.35
    for i,l in enumerate(lines):
        wgt="700" if (i==0 and bold_first) else "400"
        sz=tsize+2 if (i==0 and bold_first) else tsize
        o.append(f'<text x="{x+w/2}" y="{ty+i*lh:.1f}" text-anchor="middle" font-size="{sz}" font-weight="{wgt}" fill="{tcol}">{l}</text>')
def arrow(x1,y1,x2,y2,col="#52606d",dash=False,label=None):
    d=' stroke-dasharray="7 5"' if dash else ''
    m="red" if col=="#c62828" else "grey"
    o.append(f'<line x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}" stroke="{col}" stroke-width="3"{d} marker-end="url(#{m})"/>')
    if label: o.append(f'<text x="{(x1+x2)/2}" y="{(y1+y2)/2-8}" text-anchor="middle" font-size="15" fill="{col}" font-weight="600">{label}</text>')
B=("#e3f0fc","#1565c0"); G=("#e6f4ea","#2e7d32"); A=("#fff4e0","#e08a00"); R=("#fdecea","#c62828"); N=("#eef1f5","#52606d")
cx=90; cw=900; mid=cx+cw/2
y=150
steps=[]
def main(h,col,lines,gap=34):
    global y
    box(cx,y,cw,h,col[0],col[1],lines); top=y; y+=h
    steps.append((top,h)); 
    return top
def link(gap=34):
    global y
    arrow(mid,y,mid,y+gap-4); y+=gap
t0=main(78,N,["Start: DBA runs a DRY RUN in AWS CloudShell","./rds_patch_runner.sh -P prod -r us-east-1 -c orders-prod   (read-only, changes nothing)"]); link()
t1=main(100,B,["Preflight checks","Cluster + every member 'available'?  Pending maintenance actions per instance / cluster","Minor version availability: current, next, latest, all available minors"]); link()
t2=main(78,B,["Plan shown, numbered in the exact order it will run","Team reviews it, then re-runs with --execute  ->  confirm  Patch orders-prod? [y/N]"]); link()
t3=main(78,G,["1  Snapshot","pre-maint-&lt;cluster&gt;-&lt;UTC time&gt;, wait until the snapshot is available"]); link()
# rolling pass container
py=y; ph=400
o.append(f'<rect x="{cx}" y="{py}" width="{cw}" height="{ph}" rx="14" fill="#f3faf4" stroke="#2e7d32" stroke-width="2.5" stroke-dasharray="9 6"/>')
o.append(f'<text x="{cx+24}" y="{py+36}" font-size="22" font-weight="700" fill="#2e7d32">2  ONE rolling pass  (one failover pass overall)</text>')
iy=py+60; ih=95; iw=260; gx=[cx+24, cx+24+iw+45, cx+24+2*(iw+45)]
box(gx[0],iy,iw,ih,"#ffffff","#2e7d32",["Readers, one at a time","each: system patch -> OS","update -> DB update"],tsize=16)
box(gx[1],iy,iw,ih,"#ffffff","#2e7d32",["Cluster-level actions","same order","(e.g. db-upgrade)"],tsize=16)
box(gx[2],iy,iw,ih,"#ffffff","#2e7d32",["Writer LAST","same order;","failover is logged"],tsize=16)
arrow(gx[0]+iw,iy+ih/2,gx[1]-4,iy+ih/2); arrow(gx[1]+iw,iy+ih/2,gx[2]-4,iy+ih/2)
o.append(f'<text x="{mid}" y="{iy+ih+40}" text-anchor="middle" font-size="17" fill="#1f2933">After EVERY action: wait until the instance is healthy (available) and that action is gone, then the next.</text>')
o.append(f'<text x="{mid}" y="{iy+ih+68}" text-anchor="middle" font-size="17" fill="#1f2933">The current writer is re-checked before each instance, so the real writer is always patched last.</text>')
o.append(f'<text x="{mid}" y="{iy+ih+96}" text-anchor="middle" font-size="17" fill="#1f2933">Other / unknown action types count as DB updates and go last.</text>')
o.append(f'<text x="{mid}" y="{iy+ih+124}" text-anchor="middle" font-size="15" fill="#52606d">--opt-in-type immediate, one action at a time</text>')
y=py+ph; t4=py; link()
t5=main(78,B,["3  Verify","Cluster + all members available, nothing selected still pending"]); link()
t6=main(110,A,["4  Minor version upgrade to the latest  (the downtime moment)","Re-check the target; skip if already at the latest (a DB update may have got there)","modify-db-cluster --apply-immediately: ALL instances restart together; wait on the new version"]); link()
t7=main(78,G,["5  Summary report + log  (+ optional e-mail / Slack alert)","txt / csv / html / json: every step with times, versions before -> after, anything left pending"])
end=y
# red stops
sx=1090; sw=440
stops=[(t1,100,["STOP: not available","cluster / member not 'available',","global DB or engine not supported -> exit 2"]),
       (t3,78,["STOP: snapshot fails","nothing is patched -> exit 3"]),
       (t4+60,95,["STOP before the writer","a reader fails or times out:","writer and minor upgrade NOT run"]),
       (t5,78,["Verify fails","-> NO minor upgrade, exit 3"])]
for (ty,h,l) in stops:
    box(sx,ty,sw,h,R[0],R[1],l,tsize=17)
    arrow(cx+cw,ty+h/2,sx-4,ty+h/2,col="#c62828")
# general safety notes
ny=t6
box(sx,ny,sw,110,R[0],R[1],["Any time","Ctrl-C: state reported, what still runs in AWS;","re-run picks up only what is pending"],tsize=16)
box(sx,ny+130,sw,78,"#fff","#c62828",["Lock","one run per cluster: no double runs"],tsize=16)
# example cluster visual (top right)
ex=1090; ey=t4+185
box(ex,ey,sw,195,"#ffffff","#9aa5b1",[""],rx=12)
o.append(f'<text x="{ex+sw/2}" y="{ey+30}" text-anchor="middle" font-size="18" font-weight="700" fill="#1f2933">Example: cluster orders-prod</text>')
for i,(nm,role,c,order) in enumerate([("orders-prod-2","reader","#2e7d32","patched 1st"),("orders-prod-3","reader","#2e7d32","patched 2nd"),("orders-prod-1","WRITER","#1565c0","patched last")]):
    bx=ex+18+i*140
    o.append(f'<rect x="{bx}" y="{ey+50}" width="125" height="90" rx="10" fill="#f8fafc" stroke="{c}" stroke-width="2.5"/>')
    o.append(f'<ellipse cx="{bx+62}" cy="{ey+68}" rx="22" ry="7" fill="none" stroke="{c}" stroke-width="2"/>')
    o.append(f'<path d="M{bx+40} {ey+68} v22 a22 7 0 0 0 44 0 v-22" fill="none" stroke="{c}" stroke-width="2"/>')
    o.append(f'<text x="{bx+62}" y="{ey+115}" text-anchor="middle" font-size="14" font-weight="700" fill="{c}">{role}</text>')
    o.append(f'<text x="{bx+62}" y="{ey+133}" text-anchor="middle" font-size="13" fill="#1f2933">{nm}</text>')
    o.append(f'<text x="{bx+62}" y="{ey+165}" text-anchor="middle" font-size="14" font-weight="600" fill="#52606d">{order}</text>')
# legend
ly=end+40
o.append(f'<text x="{cx}" y="{ly+22}" font-size="18" font-weight="700" fill="#1f2933">Legend</text>')
lx=cx+90
for col,lab in [(B,"check (read-only)"),(G,"action (changes AWS)"),(A,"downtime moment"),(R,"safety stop"),(N,"you / start")]:
    o.append(f'<rect x="{lx}" y="{ly}" width="34" height="28" rx="6" fill="{col[0]}" stroke="{col[1]}" stroke-width="2.5"/>')
    o.append(f'<text x="{lx+44}" y="{ly+21}" font-size="17" fill="#1f2933">{lab}</text>')
    lx+=44+len(lab)*9+40
H=ly+70
o.append(f'<text x="{W-60}" y="{H-25}" text-anchor="end" font-size="14" fill="#7b8794">rds_patch_runner.sh v1.1.0 - dry run is the default; nothing changes without --execute</text>')
head=f'''<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" font-family="Segoe UI, Roboto, Helvetica, Arial, sans-serif">
<defs><marker id="grey" markerWidth="10" markerHeight="10" refX="8" refY="5" orient="auto"><path d="M0,0 L10,5 L0,10 z" fill="#52606d"/></marker>
<marker id="red" markerWidth="10" markerHeight="10" refX="8" refY="5" orient="auto"><path d="M0,0 L10,5 L0,10 z" fill="#c62828"/></marker></defs>
<rect width="{W}" height="{H}" fill="#ffffff"/>
<rect width="{W}" height="100" fill="#232f3e"/>
<text x="60" y="52" font-size="34" font-weight="700" fill="#ffffff">RDS Aurora Patch Runner - how it works</text>
<text x="60" y="84" font-size="18" fill="#c9d1d9">One Aurora / DocumentDB / Neptune cluster: snapshot, one rolling pass (readers, cluster, writer last), verify, then the minor upgrade</text>
'''
open("patch_runner_flow.svg","w").write(head+"\n".join(o)+"\n</svg>\n")
print(H)
