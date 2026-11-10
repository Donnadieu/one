import Foundation

/// The phone page for a hand-off (Direction A: the page full-bleed, a hairline One bar on top, Not now / Done at
/// the bottom). Plain HTML + JS, no outside files: it opens what the Mac sends with the key in the link's #part
/// (WebCrypto AES-GCM) and sends back only taps, scrolls, typed text and Enter/Backspace/Tab, sealed the same way.
enum PhonePage {
    static func html(title: String, ends: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "h:mm"
        let safeTitle = title.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: ">", with: "&gt;")
        return template.replacingOccurrences(of: "{{TITLE}}", with: safeTitle).replacingOccurrences(of: "{{ENDS}}", with: f.string(from: ends))
    }
    static let template = #"""
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
        <meta name="referrer" content="no-referrer"><title>One · {{TITLE}}</title>
        <style>
        :root{--bg:#141416;--cream:#efe6d6;--orange:#f0a04b}
        *{box-sizing:border-box}html,body{margin:0;height:100%;background:var(--bg);color:var(--cream);font:15px -apple-system,system-ui,sans-serif}
        #bar{position:fixed;top:0;left:0;right:0;height:34px;display:flex;align-items:center;gap:8px;padding:0 14px;font-size:12.5px;
          color:rgba(239,230,214,.72);background:rgba(20,20,22,.92);border-bottom:1px solid rgba(239,230,214,.12);z-index:3}
        #bar b{color:var(--cream);font-weight:600}
        #view{position:absolute;top:34px;bottom:118px;left:0;right:0;overflow:hidden;display:flex;justify-content:center;align-items:flex-start}
        #view img{max-width:100%;max-height:100%;touch-action:none;user-select:none;-webkit-user-select:none}
        #type{position:fixed;left:0;right:0;bottom:62px;display:flex;gap:6px;padding:8px 12px}
        #type input{flex:1;min-width:0;background:#222225;border:1px solid rgba(239,230,214,.18);color:var(--cream);border-radius:10px;padding:10px;font-size:16px}
        #type button,#act button{border-radius:999px;border:1px solid rgba(239,230,214,.25);background:transparent;color:var(--cream);font-size:15px;padding:10px 14px}
        #act{position:fixed;left:0;right:0;bottom:0;height:62px;display:flex;gap:10px;padding:10px 12px}
        #act button{flex:1}#act #done{background:var(--cream);color:var(--bg);font-weight:600;border:0}
        #note{position:fixed;inset:34px 0 0 0;display:none;align-items:center;justify-content:center;text-align:center;padding:30px;
          background:var(--bg);font-size:17px;line-height:1.45;z-index:4}
        </style></head><body data-title="{{TITLE}}">
        <div id="bar"><span>🔒</span><b>Only this page</b><span>· ends {{ENDS}}</span></div>
        <div id="view"><img id="img" alt="The page your helper needs you for"></div>
        <div id="type"><input id="text" autocomplete="one-time-code" autocapitalize="off" placeholder="Type here, then Send">
        <button id="send">Send</button><button data-k="Backspace">⌫</button><button data-k="Enter">⏎</button></div>
        <div id="act"><button id="notnow">Not now</button><button id="done">Done</button></div>
        <div id="note"></div>
        <script>
        (async () => {
          const note = (t) => { const n = document.getElementById('note'); n.textContent = t; n.style.display = 'flex'; };
          const k64 = (location.hash.match(/k=([A-Za-z0-9_-]+)/) || [])[1];
          if (!k64) return note('This link has ended.');
          const pad = '='.repeat((4 - k64.length % 4) % 4);
          const raw = Uint8Array.from(atob(k64.replace(/-/g, '+').replace(/_/g, '/') + pad), c => c.charCodeAt(0));
          const key = await crypto.subtle.importKey('raw', raw, 'AES-GCM', false, ['encrypt', 'decrypt']);
          history.replaceState(null, '', location.pathname);  // the key leaves the address bar
          const room = location.pathname.split('/').pop();
          const ws = new WebSocket((location.protocol === 'https:' ? 'wss://' : 'ws://') + location.host + '/ws/' + room);
          ws.binaryType = 'arraybuffer';
          const send = async (j) => {
            const iv = crypto.getRandomValues(new Uint8Array(12));
            const ct = new Uint8Array(await crypto.subtle.encrypt({name: 'AES-GCM', iv}, key, new TextEncoder().encode(JSON.stringify(j))));
            const out = new Uint8Array(12 + ct.length); out.set(iv); out.set(ct, 12);
            if (ws.readyState === 1) ws.send(out);
          };
          const img = document.getElementById('img'); let url = null, done = false;
          ws.onmessage = async (e) => {
            const b = new Uint8Array(e.data);
            let j; try { j = JSON.parse(new TextDecoder().decode(await crypto.subtle.decrypt({name: 'AES-GCM', iv: b.slice(0, 12)}, key, b.slice(12)))); } catch (_) { return; }
            if (j.t === 'frame') {
              const bin = atob(j.d), u8 = new Uint8Array(bin.length); for (let i = 0; i < bin.length; i++) u8[i] = bin.charCodeAt(i);
              const nu = URL.createObjectURL(new Blob([u8], {type: 'image/jpeg'})); img.src = nu; if (url) URL.revokeObjectURL(url); url = nu;
            } else if (j.t === 'thanks') { done = true; note('Thanks, ' + document.body.dataset.title + ' is carrying on.'); }
            else if (j.t === 'left') { done = true; note('This page went somewhere else, so this link has ended.'); }
          };
          ws.onclose = () => { if (!done) note('This link has ended.'); };
          img.addEventListener('pointerup', (e) => { const r = img.getBoundingClientRect();
            send({t: 'tap', x: Math.min(1, Math.max(0, (e.clientX - r.left) / r.width)), y: Math.min(1, Math.max(0, (e.clientY - r.top) / r.height))}); });
          let y0 = null;
          img.addEventListener('touchstart', (e) => { y0 = e.touches[0].clientY; }, {passive: true});
          img.addEventListener('touchend', (e) => { if (y0 === null) return; const dy = y0 - e.changedTouches[0].clientY; y0 = null;
            if (Math.abs(dy) > 30) send({t: 'scroll', dy: dy * 2}); });
          const text = document.getElementById('text');
          document.getElementById('send').onclick = () => { const s = text.value.trim(); if (s) send({t: 'text', s: s.slice(0, 200)}); text.value = ''; };
          document.querySelectorAll('[data-k]').forEach(b => b.onclick = () => send({t: 'key', k: b.dataset.k}));
          document.getElementById('done').onclick = () => send({t: 'done'});
          document.getElementById('notnow').onclick = () => { send({t: 'notnow'}); done = true; note('Okay. It waits for you, or you can do it at your Mac.'); };
        })();
        </script></body></html>
        """#
}
