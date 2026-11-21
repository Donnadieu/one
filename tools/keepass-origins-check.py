"""Checks that a KeePass login fills on its own site's sign-in hosts, and nowhere else.

Run: python3 tools/keepass-origins-check.py   (prints "keepass origins ok")

Nov 20 2026: the Google entry is saved for google.com; Google asks for the password on accounts.google.com,
so browser_vault fill said "Could not determine the current page origin". Never reads a real vault.
"""

import importlib.util
import sys
import types
from pathlib import Path

HERE = Path(__file__).resolve().parent
store = types.ModuleType("agent.vault_store")
store.VaultItemMeta = object
store.normalize_origin = lambda u: u
base = types.ModuleType("agent.vault_backends.base")
for n in ("LoginBackend", "UnlockRequired"):
    setattr(base, n, type(n, (Exception,), {}))
vb = types.ModuleType("agent.vault_backends")
vb.unlock = types.ModuleType("agent.vault_backends.unlock")
sys.modules.update({"agent": types.ModuleType("agent"), "agent.vault_store": store, "agent.vault_backends": vb,
                    "agent.vault_backends.unlock": vb.unlock, "agent.vault_backends.base": base})
spec = importlib.util.spec_from_file_location("kp", HERE / "overlay/agent/vault_backends/keepass.py")
kp = importlib.util.module_from_spec(spec)
try:
    spec.loader.exec_module(kp)
except ImportError as e:  # a name the stand-ins above lack: say which
    print(f"keepass origins: can't load keepass.py here ({e})")
    sys.exit(1)
fails = 0


def check(name, ok):
    global fails
    print(("  ✓ " if ok else "  ✗ ") + name)
    fails += 0 if ok else 1


g = kp.sign_in_origins("https://google.com")
check("a google.com login fills on accounts.google.com (Nov 20)", "https://accounts.google.com" in g and g[0] == "https://google.com")
check("and www.google.com", "https://www.google.com" in kp.sign_in_origins("https://www.google.com"))
check("never another company's site", not any(o.endswith(("evilgoogle.com", ".com.evil")) or "evil" in o for o in g)
      and all(o.endswith("://google.com") or o.endswith(".google.com") for o in g))
check("amazon.co.uk stays amazon.co.uk", all(o.endswith("amazon.co.uk") for o in kp.sign_in_origins("https://www.amazon.co.uk")))
check("an http, IP or port entry keeps only itself", kp.sign_in_origins("http://router.home") == ("http://router.home",)
      and kp.sign_in_origins("https://192.168.1.1") == ("https://192.168.1.1",)
      and kp.sign_in_origins("https://example.com:8443") == ("https://example.com:8443",))
print("keepass origins ok" if not fails else f"keepass origins FAILED: {fails}")
sys.exit(1 if fails else 0)
