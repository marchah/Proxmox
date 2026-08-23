#!/usr/bin/env python3
"""Does the coder actually SEE images? Sends a generated PNG of a blue circle on
near-white and asserts the reply names both the colour and the shape.

Ground truth is unambiguous, so this test can genuinely FAIL — a vision test whose
answer you cannot verify is not a test. PNG is written with a minimal pure-python
encoder so there is no Pillow dependency inside the container.
"""
import base64, json, struct, sys, urllib.request, zlib

W = H = 256

def png_blue_circle():
    rows = []
    cx = cy = W // 2
    r2 = (W // 3) ** 2
    for y in range(H):
        row = bytearray([0])                      # filter byte 0 = None
        for x in range(W):
            if (x - cx) ** 2 + (y - cy) ** 2 <= r2:
                row += bytes((20, 60, 220))       # solid blue
            else:
                row += bytes((248, 248, 248))     # near-white
        rows.append(bytes(row))
    raw = b"".join(rows)

    def chunk(tag, data):
        return (struct.pack(">I", len(data)) + tag + data
                + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))

    ihdr = struct.pack(">IIBBBBB", W, H, 8, 2, 0, 0, 0)   # 8-bit truecolour RGB
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr)
            + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))

def main():
    base = sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:8080"
    model = sys.argv[2] if len(sys.argv) > 2 else "qwen3.8-27b-mtp"
    b64 = base64.b64encode(png_blue_circle()).decode()
    body = {
        "model": model, "temperature": 0, "max_tokens": 200,
        "reasoning_effort": "none",
        "messages": [{"role": "user", "content": [
            {"type": "text", "text": "What colour and what shape is in this image? Answer in one short sentence."},
            {"type": "image_url", "image_url": {"url": "data:image/png;base64," + b64}},
        ]}],
    }
    req = urllib.request.Request(base + "/v1/chat/completions", data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=900) as r:
            d = json.loads(r.read())
    except urllib.error.HTTPError as e:
        print("HTTP %s: %s" % (e.code, e.read().decode()[:300])); sys.exit(1)
    if "choices" not in d:
        print("REJECTED: %s" % str(d)[:300]); sys.exit(1)
    ch = d["choices"][0]; t = d.get("timings", {})
    ans = (ch["message"].get("content") or "")
    low = ans.lower()
    ok = ("blue" in low) and ("circle" in low or "round" in low or "disc" in low)
    print("answer      : %r" % ans[:200])
    print("decode      : %.1f tok/s" % t.get("predicted_per_second", 0))
    dn, da = t.get("draft_n"), t.get("draft_n_accepted")
    print("MTP on image: %s" % (("%s/%s accepted" % (da, dn)) if dn else "not used for this request"))
    print("VERDICT     : %s" % ("PASS — names both colour and shape" if ok
                                else "FAIL — did not name blue + circle"))
    sys.exit(0 if ok else 2)

if __name__ == "__main__":
    main()
