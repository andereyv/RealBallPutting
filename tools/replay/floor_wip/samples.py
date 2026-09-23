"""Print each replayed putt sample in image and floor coordinates:  python3 samples.py <rec_dir>"""
import sys,json
import os
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
from mat_edge_world import load_heads, pose_at, make_unproject
R=sys.argv[1]
meta=json.load(open(R+'/meta.json')); ts,qs,ps=load_heads(R+'/events.jsonl'); unp=make_unproject(meta,False,False)
t0=json.loads(open(R+'/events.jsonl').readline())['t_ns']
plane=float(meta['tee_box_pos'][1])+0.02135
for line in open(R+'/replay_putts.jsonl'):
    p=json.loads(line); print("putt t=%.2f"%p['t_s'])
    for s in p['samples']:
        Rm,pp=pose_at(ts,qs,ps,s[1]/1e9-0.025); w=unp([[s[2],s[3]]],Rm,pp,plane)
        print("   %.3f  img(%.3f,%.3f) floor(%.3f,%.3f)"%((s[1]-t0)/1e9,s[2],s[3],w[0][0],w[0][1]))
