# -*- coding: utf-8 -*-
"""Launch headless Edge via shot.py's minimal CDP helpers, read real .phone
bounding rects, then crop single screens from the full-page jpg."""
import base64
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

from PIL import Image

SHOT = r'C:\Users\zx\AppData\Local\Doubao\User Data\Profile 1\.doubao\agent_mode\workspace\.skills\html\scripts\shot.py'
spec = importlib.util.spec_from_file_location('shotmod', SHOT)
shot = importlib.util.module_from_spec(spec)
spec.loader.exec_module(shot)

HTML = r'F:\PORJECT\cihui-ui\ui-preview.html'
JPG = r'F:\PORJECT\cihui-ui\_shots\ui-preview_desktop.jpg'
OUT = r'F:\PORJECT\cihui-ui\doc_img'

# resolve browser executable
exec_path = shot._find_chromium_fallback()
if not exec_path:
    for c in shot._system_browser_candidates():
        if Path(c).exists():
            exec_path = c
            break
print('browser:', exec_path)

port = shot._pick_free_port()
udd = tempfile.mkdtemp(prefix='rect_cdp_')
url = Path(HTML).resolve().as_uri()
proc = subprocess.Popen([
    exec_path, '--headless=new', '--no-sandbox', '--disable-dev-shm-usage',
    '--disable-gpu', '--hide-scrollbars', '--force-device-scale-factor=1',
    '--window-size=1416,763', f'--remote-debugging-port={port}',
    f'--user-data-dir={udd}', 'about:blank',
], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
try:
    ws_url, _ = shot._cdp_wait_target(port, timeout=10)
    with shot._WSClient(ws_url) as ws:
        ws.call('Page.enable')
        ws.call('Page.navigate', {'url': url})
        deadline = time.time() + 20
        while time.time() < deadline:
            ev = ws.recv_event(timeout=deadline - time.time())
            if ev and ev.get('method') == 'Page.loadEventFired':
                break
        time.sleep(1.5)
        expr = r"""
        JSON.stringify((function(){
          window.scrollTo(0, document.body.scrollHeight);
          var ph=[...document.querySelectorAll('.phone')];
          return ph.map(function(el){var r=el.getBoundingClientRect();
            return {x:r.x+window.scrollX,y:r.y+window.scrollY,w:r.width,h:r.height};});
        })())
        """
        r = ws.call('Runtime.evaluate', {'expression': expr, 'returnByValue': True}, timeout=15)
        rects = json.loads(r['result']['result']['value'])
finally:
    try:
        proc.terminate(); proc.wait(timeout=3)
    except Exception:
        proc.kill()

print('phones:', len(rects))
im = Image.open(JPG).convert('RGB')
s = im.size[0] / 1416.0
os.makedirs(OUT, exist_ok=True)
for i, rc in enumerate(rects, 1):
    x, y = int(round(rc['x'] * s)), int(round(rc['y'] * s))
    w, h = int(round(rc['w'] * s)), int(round(rc['h'] * s))
    crop = im.crop((x, y, x + w, y + h))
    p = os.path.join(OUT, f'screen_{i:02d}.jpg')
    crop.save(p, quality=92)
    print(i, (x, y, w, h))
print('done')
