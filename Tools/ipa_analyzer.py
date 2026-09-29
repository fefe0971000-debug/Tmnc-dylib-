#!/usr/bin/env python3
"""Universal IPA static analyzer.

Read-only analysis of a supplied IPA. It never decrypts, patches, signs, or
redistributes the input. The implementation intentionally uses only Python's
standard library so it can run on Linux, macOS, and CI.
"""
from __future__ import annotations
import argparse, base64, hashlib, json, os, plistlib, re, shutil, struct, subprocess, sys, zipfile
from pathlib import Path

MACHO_MAGICS = {0xfeedface, 0xcefaedfe, 0xfeedfacf, 0xcffaedfe, 0xcafebabe, 0xbebafeca, 0xcafebabf, 0xbfbafeca}
CPU_TYPES = {0x0100000c: "arm64", 0x0000000c: "arm", 0x01000007: "x86_64", 7: "x86", 0x01000012: "arm64_32"}
MH_TYPES = {1:"REL",2:"EXEC",6:"DYLIB",8:"BUNDLE",0x80000002:"DYLIB_STUB"}
LC_NAMES = {1:"SEGMENT",0x19:"SEGMENT_64",2:"SYMTAB",0xb:"DYLIB",0xc:"LOAD_DYLIB",0x18:"LOAD_WEAK_DYLIB",0x1b:"ID_DYLIB",0x1c:"LOAD_DYLINKER",0x1d:"ID_DYLINKER",0x22:"DYLD_INFO",0x24:"VERSION_MIN_IPHONEOS",0x25:"VERSION_MIN_MACOSX",0x32:"RPATH",0x21:"CODE_SIGNATURE",0x26:"DYLD_ENVIRONMENT",0x28:"MAIN",0x29:"DATA_IN_CODE",0x2a:"SOURCE_VERSION",0x2b:"DYLIB_CODE_SIGN_DRS",0x2c:"ENCRYPTION_INFO",0x2d:"DYLD_INFO_ONLY",0x30:"VERSION_MIN_TVOS",0x31:"VERSION_MIN_WATCHOS",0x33:"VERSION_MIN_DRIVERKIT",0x34:"DYLD_EXPORTS_TRIE",0x35:"DYLD_CHAINED_FIXUPS",0x36:"FILESET_ENTRY",0x80000022:"FUNCTION_STARTS",0x80000033:"DATA_IN_CODE"}

def sha256(p):
    h=hashlib.sha256()
    with open(p,'rb') as f:
        for b in iter(lambda:f.read(1024*1024),b''): h.update(b)
    return h.hexdigest()

def run(cmd):
    try: return subprocess.check_output(cmd, stderr=subprocess.STDOUT, text=True, errors='replace')
    except Exception as e: return f"UNAVAILABLE: {e}\n"

def is_macho(data):
    if len(data)<4: return False
    m=struct.unpack('<I',data[:4])[0]
    return m in MACHO_MAGICS

def cstr(data, off, limit=None):
    if off>=len(data): return ''
    end=data.find(b'\0',off, limit or len(data))
    return data[off:end if end>=0 else len(data)].decode('utf-8','replace')

def macho_info(path):
    data=Path(path).read_bytes(); m=struct.unpack('<I',data[:4])[0]
    info={'path':str(path),'size':len(data),'sha256':hashlib.sha256(data).hexdigest(),'magic':hex(m),'architectures':[],'load_commands':[],'sections':[],'dylibs':[],'rpaths':[]}
    if m in (0xcafebabe,0xbebafeca,0xcafebabf,0xbfbafeca):
        endian='>' if m in (0xcafebabe,0xcafebabf) else '<'; is64=m in (0xcafebabf,0xbfbafeca)
        n=struct.unpack_from(endian+'I',data,4)[0]; size=20 if is64 else 20
        for i in range(n):
            off=8+i*20
            cputype,cpusub,offset,sz,align=struct.unpack_from(endian+'IIIII',data,off)
            info['architectures'].append({'cpu_type':hex(cputype),'architecture':CPU_TYPES.get(cputype,'unknown'),'offset':offset,'size':sz})
        return info
    is64=m in (0xfeedfacf,0xcffaedfe); endian='<' if m in (0xfeedface,0xfeedfacf) else '>'
    hs=32 if is64 else 28
    try:
        cputype,cpusub,filetype,ncmds,sizeofcmds,flags=struct.unpack_from(endian+'IIIIII',data,4)
        info.update(cpu_type=hex(cputype),architecture=CPU_TYPES.get(cputype,'unknown'),file_type=MH_TYPES.get(filetype,str(filetype)),ncmds=ncmds,flags=hex(flags),symbols_stripped=not bool(flags & 0x2000))
        off=hs
        for _ in range(ncmds):
            cmd,cmdsize=struct.unpack_from(endian+'II',data,off); raw=data[off:off+cmdsize]
            item={'cmd':hex(cmd),'name':LC_NAMES.get(cmd & 0x7fffffff,LC_NAMES.get(cmd,'UNKNOWN')),'offset':off,'size':cmdsize}
            if (cmd & 0x7fffffff) in (1,0x19):
                isseg=(cmd & 0x7fffffff)==0x19; fmt=endian+('II16sQQQQiiII' if isseg else 'II16sIIIIiiII')
                vals=struct.unpack_from(fmt,data,off); segname=vals[2].split(b'\0',1)[0].decode('utf8','replace'); vmaddr,vmsize,fileoff,filesize=vals[3:7]; nsects=vals[9]; sec_off=off+(72 if isseg else 56)
                item.update(segment=segname,vmaddr=hex(vmaddr),vmsize=vmsize,fileoff=fileoff,filesize=filesize)
                for j in range(nsects):
                    so=sec_off+j*(80 if isseg else 68); sfmt=endian+('16s16sQQIIIIIIII' if isseg else '16s16sIIIIIIIII'); sv=struct.unpack_from(sfmt,data,so); sect=sv[0].split(b'\0',1)[0].decode('utf8','replace'); seg=sv[1].split(b'\0',1)[0].decode('utf8','replace'); addr,ss,fo=sv[2:5]
                    info['sections'].append({'segment':seg,'section':sect,'address':hex(addr),'size':ss,'file_offset':fo,'flags':hex(sv[8])})
            elif (cmd & 0x7fffffff) in (0xc,0x18,0x1b,0x1c):
                no=struct.unpack_from(endian+'I',data,off+8)[0]; val=cstr(data,off+no,off+cmdsize); item['name_value']=val
                if 'DYLIB' in item['name']: info['dylibs'].append(val)
            elif (cmd & 0x7fffffff)==0x1c:
                no=struct.unpack_from(endian+'I',data,off+8)[0]; info['rpaths'].append(cstr(data,off+no,off+cmdsize))
            info['load_commands'].append(item); off+=cmdsize
    except (struct.error,IndexError) as e: info['parse_error']=str(e)
    return info

def write_lines(path, lines):
    Path(path).write_text('\n'.join(map(str,lines))+'\n',encoding='utf-8')

def extract_strings(data, encoding='ascii'):
    if encoding=='utf16':
        return [(m.start(),m.group().decode('utf-16le','replace')) for m in re.finditer(rb'(?:[ -~]\0){4,}',data)]
    return [(m.start(),m.group().decode('utf8','replace')) for m in re.finditer(rb'[ -~]{4,}',data)]


def integrate_runtime(runtime_zip, out, infos, app):
    rd=out/'Runtime'; rd.mkdir(exist_ok=True)
    limitations=[]; runtime_files=[]
    if not runtime_zip:
        limitations.append('No runtime ZIP supplied; screen/class/IMP correlations were not attempted.')
        (rd/'LIMITATIONS.txt').write_text('\n'.join(limitations)+'\n',encoding='utf8'); return
    try:
        with zipfile.ZipFile(runtime_zip) as z:
            bad=z.testzip()
            if bad: limitations.append(f'Runtime ZIP CRC failure at {bad}')
            z.extractall(rd/'Input')
            runtime_files=z.namelist()
    except Exception as e:
        limitations.append(f'Runtime ZIP could not be opened: {e}')
        (rd/'LIMITATIONS.txt').write_text('\n'.join(limitations)+'\n',encoding='utf8'); return
    classes=[]
    for candidate in [rd/'Input/Runtime/RUNTIME_CLASSES_DETAILED.json', rd/'Input/RUNTIME_CLASSES_DETAILED.json']:
        if candidate.exists():
            try: classes=json.loads(candidate.read_text()).get('classes',[])
            except Exception as e: limitations.append(f'Runtime JSON parse error: {e}')
    loaded=[]
    for candidate in [rd/'Input/Runtime/LOADED_IMAGES.json', rd/'Input/LOADED_IMAGES.json']:
        if candidate.exists():
            try: loaded=json.loads(candidate.read_text())
            except Exception as e: limitations.append(f'Loaded images JSON parse error: {e}')
    if not classes:
        for candidate in rd.rglob('RUNTIME_CLASSES_DETAILED.txt'):
            classes=[{'class':line.split(' : ',1)[0]} for line in candidate.read_text(errors='replace').splitlines() if ' : ' in line]
    (rd/'runtime_files.json').write_text(json.dumps({'files':runtime_files,'class_count':len(classes),'loaded_image_count':len(loaded)},indent=2),encoding='utf8')
    static_names=set()
    for info in infos:
        static_names.add(Path(info.get('path','')).name)
    corr=[]
    for row in classes:
        name=row.get('class',''); methods=row.get('methods',[])
        corr.append({'runtime_class':name,'static_class_name_match':name in static_names or any(name in str(x) for x in static_names),'method_count':len(methods),'image':row.get('image',''),'address_mapping':'unavailable without runtime image UUID/base/slide in supplied report'})
    (rd/'SCREEN_CLASS_METHOD_CORRELATION.json').write_text(json.dumps({'classes':corr,'loaded_images':loaded},indent=2),encoding='utf8')
    lines=['Runtime/static correlation','===========================',f'Runtime files: {len(runtime_files)}',f'Runtime classes: {len(classes)}','Only observed screens are represented; unopened screens were not inspected.']
    lines += ['','Address mapping limitations:','- Runtime IMP correlation requires image UUID, ASLR slide, unslid address and static image UUID.']
    lines += ['- The current runtime report may provide IMP/image path only; no virtual address is treated as a file offset.']
    (out/'SCREEN_CLASS_METHOD_CORRELATION.txt').write_text('\n'.join(lines)+'\n',encoding='utf8')
    if not loaded: limitations.append('Runtime loaded-image UUID/base/slide JSON was not present; IMP-to-static mapping is partial.')
    if not classes: limitations.append('No detailed runtime class JSON was present; only text fallback may be available.')
    limitations.append('Swift metadata and original source are not recovered through this analyzer.')
    limitations.append('Disassembly/pseudocode is emitted only if a supported external tool is available; otherwise it is omitted.')
    (rd/'LIMITATIONS.txt').write_text('\n'.join(limitations)+'\n',encoding='utf8')

def emit_per_image_reports(out, infos):
    d=out/'PerImage'; d.mkdir(exist_ok=True)
    for i,info in enumerate(infos,1):
        name=Path(info.get('path','image')).name
        safe=re.sub(r'[^A-Za-z0-9_.-]+','_',name)
        (d/f'{i:04d}_{safe}.json').write_text(json.dumps(info,indent=2),encoding='utf8')

def optional_disassembly(exe, out):
    tools=[['llvm-objdump','-d','--arch-name=arm64',str(exe)],['xcrun','otool','-tvV',str(exe)]]
    for cmd in tools:
        if shutil.which(cmd[0]) or cmd[0]=='xcrun':
            try:
                text=run(cmd)
                if not text.startswith('UNAVAILABLE'):
                    (out/'MachO'/'DISASSEMBLY.txt').write_text(text,encoding='utf8'); return 'available'
            except Exception: pass
    (out/'MachO'/'DISASSEMBLY.txt').write_text('NOT GENERATED: no supported disassembler available in this environment.\n',encoding='utf8'); return 'unavailable'

def analyze(ipa, out, runtime_zip=None):
    ipa=Path(ipa).resolve(); out=Path(out).resolve(); out.mkdir(parents=True,exist_ok=True)
    extracted=out/'IPA'; extracted.mkdir(exist_ok=True)
    with zipfile.ZipFile(ipa) as z: z.extractall(extracted)
    apps=sorted(extracted.glob('Payload/*.app'))
    if not apps: apps=sorted(extracted.glob('**/*.app'))
    if not apps: raise SystemExit('No .app bundle found in IPA')
    app=apps[0]; plist_path=app/'Info.plist'
    try: plist=plistlib.loads(plist_path.read_bytes())
    except Exception as e: plist={'_parse_error':str(e)}
    exe_name=plist.get('CFBundleExecutable') if isinstance(plist,dict) else None
    exe=(app/exe_name) if exe_name and (app/exe_name).exists() else None
    if exe is None:
        candidates=[p for p in app.iterdir() if p.is_file() and is_macho(p.read_bytes()[:4096])]
        exe=candidates[0] if candidates else None
    if exe is None: raise SystemExit('Could not identify main executable')
    (out/'MachOInventory').mkdir(exist_ok=True); (out/'OriginalBinaries').mkdir(exist_ok=True); (out/'MainBinary').mkdir(exist_ok=True)
    shutil.copy2(exe,out/'MainBinary/MAIN_ORIGINAL.bin'); shutil.copy2(exe,out/'OriginalBinaries'/exe.name)
    write_lines(out/'MAIN_SHA256.txt',[sha256(exe)])
    write_lines(out/'INFO_PLIST.txt',[plistlib.dumps(plist,fmt=plistlib.FMT_XML).decode()])
    (out/'BUNDLE_METADATA.json').write_text(json.dumps(plist,indent=2,default=str),encoding='utf8')
    tree=[str(p.relative_to(extracted)) for p in sorted(extracted.rglob('*'))]; write_lines(out/'IPA_FILE_TREE.txt',tree)
    macho_files=[]; infos=[]
    for p in sorted(extracted.rglob('*')):
        if p.is_file():
            try: data=p.read_bytes()
            except: continue
            if is_macho(data):
                macho_files.append(p); inf=macho_info(p); infos.append(inf); shutil.copy2(p,out/'OriginalBinaries'/f'{len(infos):04d}_{p.name}')
    write_lines(out/'MachOInventory/ALL_MACHO_BINARIES.txt',[json.dumps(i,sort_keys=True) for i in infos])
    # Main exports, chunked to keep files manageable.
    data=exe.read_bytes(); chunk=8*1024*1024; hexdir=out/'FullHex'; b64dir=out/'FullBase64'; hexdir.mkdir(exist_ok=True); b64dir.mkdir(exist_ok=True)
    hi=[]; bi=[]
    for n,start in enumerate(range(0,len(data),chunk),1):
        part=data[start:start+chunk]; hp=hexdir/f'HEX_PART_{n:04d}.txt'; bp=b64dir/f'BASE64_PART_{n:04d}.txt'
        with hp.open('w') as f:
            for off in range(0,len(part),16): f.write(f'{start+off:08x}: '+ ' '.join(f'{x:02x}' for x in part[off:off+16])+'\n')
        bp.write_text(base64.b64encode(part).decode()+'\n'); hi.append(f'{hp.name}: start={start} end={start+len(part)-1} bytes={len(part)}'); bi.append(f'{bp.name}: start={start} end={start+len(part)-1} bytes={len(part)}')
    write_lines(out/'FullHex/HEX_INDEX.txt',hi); write_lines(out/'FullBase64/BASE64_INDEX.txt',bi)
    # Reconstruction verification.
    recon_hex=b''.join(bytes(int(x,16) for line in p.read_text().splitlines() if ':' in line for x in line.split(':',1)[1].split()) for p in sorted(hexdir.glob('HEX_PART_*.txt')))
    recon_b64=b''.join(base64.b64decode(p.read_text()) for p in sorted(b64dir.glob('BASE64_PART_*.txt')))
    write_lines(out/'BINARY_EXPORT_VERIFICATION.txt',[f'ORIGINAL SHA256: {sha256(exe)}',f'HEX RECONSTRUCTED SHA256: {hashlib.sha256(recon_hex).hexdigest()}',f'BASE64 RECONSTRUCTED SHA256: {hashlib.sha256(recon_b64).hexdigest()}',f'HEX MATCH: {"YES" if recon_hex==data else "NO"}',f'BASE64 MATCH: {"YES" if recon_b64==data else "NO"}'])
    # Structured Mach-O reports for main binary.
    maininfo=macho_info(exe); md=out/'MachO'; md.mkdir(exist_ok=True)
    write_lines(md/'HEADER.txt',[json.dumps({k:v for k,v in maininfo.items() if k not in ('load_commands','sections')},indent=2)])
    write_lines(md/'LOAD_COMMANDS.txt',[json.dumps(x,sort_keys=True) for x in maininfo.get('load_commands',[])]); write_lines(md/'SECTIONS.txt',[json.dumps(x,sort_keys=True) for x in maininfo.get('sections',[])]); write_lines(md/'DYLIBS.txt',maininfo.get('dylibs',[])); write_lines(md/'RPATHS.txt',maininfo.get('rpaths',[])); write_lines(md/'SECTION_OFFSETS.txt',[f"{x['segment']},{x['section']},address={x['address']},offset={x['file_offset']},size={x['size']}" for x in maininfo.get('sections',[])])
    # Strings and resource inventory.
    sd=out/'Strings'; sd.mkdir(exist_ok=True); ascii_s=extract_strings(data); utf16_s=extract_strings(data,'utf16'); write_lines(sd/'ASCII.txt',[f'0x{o:x}: {s}' for o,s in ascii_s]); write_lines(sd/'UTF8.txt',[f'0x{o:x}: {s}' for o,s in ascii_s]); write_lines(sd/'UTF16.txt',[f'0x{o:x}: {s}' for o,s in utf16_s]); write_lines(sd/'URLS.txt',[f'0x{o:x}: {s}' for o,s in ascii_s if re.search(r'(?i)https?://|mailto:',s)]); write_lines(sd/'PATHS.txt',[f'0x{o:x}: {s}' for o,s in ascii_s if '/' in s]); write_lines(sd/'OBJC_METHOD_NAMES.txt',[f'0x{o:x}: {s}' for o,s in ascii_s if re.fullmatch(r'[-+]?\w[\w:]*',s) and ':' in s]); write_lines(sd/'OBJC_CLASS_NAMES.txt',[f'0x{o:x}: {s}' for o,s in ascii_s if re.fullmatch(r'[A-Z_][A-Za-z0-9_]{2,}',s)])
    rd=out/'Resources'; rd.mkdir(exist_ok=True); resources=[p for p in app.rglob('*') if p.is_file() and p.suffix.lower() in {'.png','.jpg','.jpeg','.heic','.heif','.gif','.pdf','.mov','.mp4','.m4a','.wav','.caf','.car'}]; write_lines(rd/'IMAGE_LIST.txt',[str(p.relative_to(app)) for p in resources if p.suffix.lower() in {'.png','.jpg','.jpeg','.heic','.heif','.gif','.pdf','.car'}]); write_lines(rd/'MEDIA_LIST.txt',[str(p.relative_to(app)) for p in resources if p.suffix.lower() not in {'.png','.jpg','.jpeg','.heic','.heif','.gif','.pdf','.car'}])
    # Reports and machine index.
    idx=[]
    for p in sorted(out.rglob('*')):
        if p.is_file() and p.name!='ANALYSIS_INDEX.json': idx.append({'path':str(p.relative_to(out)),'type':p.suffix.lstrip('.') or 'file','size':p.stat().st_size})
    (out/'ANALYSIS_INDEX.json').write_text(json.dumps({'input':str(ipa),'app':str(app.relative_to(extracted)),'main_executable':str(exe.relative_to(extracted)),'artifacts':idx},indent=2),encoding='utf8')
    emit_per_image_reports(out, infos); optional_disassembly(exe, out); integrate_runtime(runtime_zip, out, infos, app)
    write_lines(out/'IPA_INFO.txt',[f'Input: {ipa}',f'App: {app}',f'Bundle ID: {plist.get("CFBundleIdentifier","")}',f'Executable: {exe.name}',f'Version: {plist.get("CFBundleShortVersionString","")} ({plist.get("CFBundleVersion","")})',f'Mach-O files: {len(macho_files)}',f'Runtime ZIP: {runtime_zip or "(not supplied)"}'])

def main():
    ap=argparse.ArgumentParser(); ap.add_argument('ipa'); ap.add_argument('--runtime-zip',help='Runtime ZIP produced by UniversalUIInspector'); ap.add_argument('-o','--output',default='UniversalIPAAnalysis'); args=ap.parse_args(); analyze(args.ipa,args.output,args.runtime_zip); print(f'Analysis written to {args.output}')
if __name__=='__main__': main()
