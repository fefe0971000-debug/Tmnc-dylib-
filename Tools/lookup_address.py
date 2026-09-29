#!/usr/bin/env python3
import argparse,json,re
from pathlib import Path
ap=argparse.ArgumentParser(description='Search UniversalIPAInspector analysis reports')
ap.add_argument('analysis'); ap.add_argument('query'); args=ap.parse_args()
root=Path(args.analysis); q=args.query.lower(); hits=[]
for p in root.rglob('*'):
    if p.is_file() and p.stat().st_size < 64*1024*1024:
        try: text=p.read_text(errors='replace')
        except: continue
        for n,line in enumerate(text.splitlines(),1):
            if q in line.lower(): hits.append({'file':str(p.relative_to(root)),'line':n,'text':line[:1000]})
print(json.dumps({'query':args.query,'hits':hits},indent=2))
