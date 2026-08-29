#!/usr/bin/env python3
import hashlib, json, sys, urllib.request
base, model = sys.argv[1], sys.argv[2]
body = {"model": model, "temperature": 0, "max_tokens": 4000, "reasoning_effort": "low",
        "messages": [{"role": "user", "content":
          "Write a TypeScript function that debounces an async function, "
          "preserving the return value of the last call."}]}
req = urllib.request.Request(base + "/v1/chat/completions", data=json.dumps(body).encode(),
                             headers={"Content-Type": "application/json"})
with urllib.request.urlopen(req, timeout=900) as r: d = json.loads(r.read())
ch = d["choices"][0]; m = ch["message"]; t = d.get("timings", {})
c = m.get("content") or ""
dn, da = t.get("draft_n"), t.get("draft_n_accepted")
print("  decode %.1f tok/s | prefill %.0f tok/s | tokens %s | MTP %s | sha %s"
      % (t.get("predicted_per_second", 0), t.get("prompt_per_second", 0), t.get("predicted_n"),
         ("%.1f%%" % (100*da/dn)) if dn else "off",
         hashlib.sha256(c.encode()).hexdigest()[:12]))
