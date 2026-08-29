#!/usr/bin/env python3
"""Measure the cost of an IMAGE request: projector on GPU vs on CPU.

Text-only throughput is already known to be unaffected either way, so the metric that
matters is image latency. Uses screenshot-sized images because that is what a visual
critic actually looks at, and image encode cost scales with patch count, i.e. resolution.
"""
import base64, json, struct, sys, time, urllib.request, zlib

def png(w, h):
    """Structured content (grid + disc), so encoding is not trivially compressible."""
    rows = []
    cx, cy, r2 = w // 2, h // 2, (min(w, h) // 3) ** 2
    for y in range(h):
        row = bytearray([0])
        for x in range(w):
            if (x - cx) ** 2 + (y - cy) ** 2 <= r2:
                row += bytes((20, 60, 220))
            elif (x // 16 + y // 16) % 2 == 0:
                row += bytes((240, 240, 240))
            else:
                row += bytes((200, 205, 215))
        rows.append(bytes(row))
    raw = b"".join(rows)
    def chunk(tag, data):
        return (struct.pack(">I", len(data)) + tag + data
                + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))
    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b""))

def ask(base, model, img_b64, reps):
    out = []
    for _ in range(reps):
        content = [{"type": "text", "text": "What colour and shape is in the centre? One short sentence."}]
        if img_b64:
            content.append({"type": "image_url",
                            "image_url": {"url": "data:image/png;base64," + img_b64}})
        # cache_prompt MUST be false: with it on, repeated identical requests are served from
        # the prefix cache and prompt_n collapses to a handful of tokens -- you then measure
        # cache hits, not image encoding. A prompt_n of ~4 for a 1280x720 image is the tell.
        body = {"model": model, "temperature": 0, "max_tokens": 60, "cache_prompt": False,
                "reasoning_effort": "none", "messages": [{"role": "user", "content": content}]}
        req = urllib.request.Request(base + "/v1/chat/completions", data=json.dumps(body).encode(),
                                     headers={"Content-Type": "application/json"})
        t0 = time.time()
        with urllib.request.urlopen(req, timeout=900) as r:
            d = json.loads(r.read())
        wall = time.time() - t0
        t = d.get("timings", {})
        c = d["choices"][0]["message"].get("content") or ""
        out.append({"wall": wall, "prompt_n": t.get("prompt_n"),
                    "prompt_ms": t.get("prompt_ms"), "dec": t.get("predicted_per_second"),
                    "ok": ("blue" in c.lower())})
    return out

def main():
    base, model = sys.argv[1], sys.argv[2]
    reps = int(sys.argv[3]) if len(sys.argv) > 3 else 3
    print("  %-16s %8s %10s %11s %9s  %s" % ("case", "wall s", "prompt_n", "prompt_ms", "dec t/s", "correct"))
    for label, dims in (("text-only", None), ("image 512x512", (512, 512)), ("image 1280x720", (1280, 720))):
        b64 = base64.b64encode(png(*dims)).decode() if dims else None
        rs = ask(base, model, b64, reps)
        med = sorted(r["wall"] for r in rs)[len(rs)//2]
        r0 = rs[0]
        suspect = "" if (dims is None or (r0["prompt_n"] or 0) > 50) else "  <-- prompt_n too small, image not processed?"
        print("  %-16s %8.2f %10s %11s %9.1f  %s%s"
              % (label, med, r0["prompt_n"],
                 ("%.0f" % r0["prompt_ms"]) if r0["prompt_ms"] else "-",
                 r0["dec"] or 0, "yes" if (dims is None or r0["ok"]) else "NO", suspect))

if __name__ == "__main__":
    main()
