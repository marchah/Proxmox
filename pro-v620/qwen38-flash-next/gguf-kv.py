#!/usr/bin/env python3
"""Read a GGUF's metadata header and size its KV cache. No dependencies, header only.

🔴 Why this matters for sizing: `n_layer` in the usual formula
    2 * n_layer * n_head_kv * head_dim * bytes
means **full-attention layers only**. The Qwen3.5/3.6/3.8 families are hybrid — most
layers are linear attention (Gated DeltaNet) whose state is fixed-size and
context-independent, so only the full-attention layers hold a per-token KV cache. Reading
`layer_types` / `full_attention_interval` before sizing anything is the difference between
a correct number and one an order of magnitude too big.
"""
import struct, sys

T_U8, T_I8, T_U16, T_I16, T_U32, T_I32, T_F32, T_BOOL, T_STR, T_ARR, T_U64, T_I64, T_F64 = range(13)
FIXED = {T_U8: ("<B", 1), T_I8: ("<b", 1), T_U16: ("<H", 2), T_I16: ("<h", 2),
         T_U32: ("<I", 4), T_I32: ("<i", 4), T_F32: ("<f", 4), T_BOOL: ("<B", 1),
         T_U64: ("<Q", 8), T_I64: ("<q", 8), T_F64: ("<d", 8)}


class R:
    def __init__(self, f): self.f = f
    def raw(self, n): 
        b = self.f.read(n)
        if len(b) != n: raise EOFError
        return b
    def u32(self): return struct.unpack("<I", self.raw(4))[0]
    def u64(self): return struct.unpack("<Q", self.raw(8))[0]
    def s(self): return self.raw(self.u64()).decode("utf-8", "replace")
    def val(self, t):
        if t in FIXED:
            fmt, n = FIXED[t]
            return struct.unpack(fmt, self.raw(n))[0]
        if t == T_STR: return self.s()
        if t == T_ARR:
            et, n = self.u32(), self.u64()
            # ⚠️ The bytes MUST be consumed whether or not they are kept, or the stream
            # desyncs and the next key read blows up mid-file (a 151k-entry tokenizer list
            # is the first thing this hits).
            if n > 4096:
                if et in FIXED:
                    self.f.seek(FIXED[et][1] * n, 1)
                else:
                    for _ in range(n):
                        self.val(et)
                return "<%d items, skipped>" % n
            return [self.val(et) for _ in range(n)]
        raise ValueError("unknown gguf type %d" % t)


def main():
    path = sys.argv[1]
    with open(path, "rb") as f:
        r = R(f)
        if r.raw(4) != b"GGUF": sys.exit("not a GGUF")
        ver, n_tensors, n_kv = r.u32(), r.u64(), r.u64()
        kv = {}
        for _ in range(n_kv):
            k = r.s()
            kv[k] = r.val(r.u32())
    print("gguf v%d, %d tensors, %d metadata keys" % (ver, n_tensors, n_kv))
    arch = kv.get("general.architecture", "?")
    print("architecture: %s" % arch)
    print()

    interesting = [k for k in kv if any(s in k for s in (
        "block_count", "attention.head_count", "attention.key_length",
        "attention.value_length", "embedding_length", "context_length",
        "layer_types", "full_attention", "linear", "recurrent", "expert",
        "nextn", "ple", "ssm", "rope.dimension"))]
    for k in sorted(interesting):
        v = kv[k]
        if isinstance(v, list) and len(v) > 24:
            # collapse a long layer_types array to its pattern
            uniq = sorted(set(v))
            print("  %-52s %d entries, values %s" % (k, len(v), uniq))
            if len(uniq) <= 4:
                print("  %-52s counts %s" % ("", {u: v.count(u) for u in uniq}))
        else:
            print("  %-52s %s" % (k, v))

    # ---- size the cache
    n_layer = kv.get("%s.block_count" % arch)
    hkv = kv.get("%s.attention.head_count_kv" % arch)
    if isinstance(hkv, list): hkv_list, hkv = hkv, max(hkv)
    else: hkv_list = None
    klen = kv.get("%s.attention.key_length" % arch)
    vlen = kv.get("%s.attention.value_length" % arch, klen)
    emb = kv.get("%s.embedding_length" % arch)
    nhead = kv.get("%s.attention.head_count" % arch)
    if isinstance(nhead, list): nhead = max(nhead)
    if klen is None and emb and nhead: klen = vlen = emb // nhead

    # How many layers actually hold a KV cache?
    full = None
    lt = kv.get("%s.layer_types" % arch)
    if isinstance(lt, list):
        full = sum(1 for x in lt if str(x).startswith("full"))
    if full is None:
        iv = kv.get("%s.full_attention_interval" % arch)
        if iv and n_layer: full = n_layer // iv
    if hkv_list:
        nz = sum(1 for x in hkv_list if x)
        full = nz if full is None else full

    print()
    print("KV sizing")
    print("  block_count            %s" % n_layer)
    print("  head_count_kv          %s" % hkv)
    print("  key/value length       %s / %s" % (klen, vlen))
    print("  FULL-ATTENTION layers  %s %s" % (
        full, "(all -- NOT hybrid, the formula applies literally)" if full == n_layer else "(hybrid)"))
    if full and hkv and klen:
        for name, nbytes in (("f16", 2), ("q8_0", 1)):
            per_tok = full * hkv * (klen + vlen) * nbytes
            print("  %-4s  %8.1f KiB/token   65536 ctx = %6.2f GiB   131072 = %6.2f GiB   262144 = %6.2f GiB" % (
                name, per_tok / 1024,
                per_tok * 65536 / 2**30, per_tok * 131072 / 2**30, per_tok * 262144 / 2**30))
        print()
        print("  ⚠️ An estimate from metadata. Confirm with a VRAM DELTA between two context")
        print("  sizes, reading GTT alongside VRAM -- flat VRAM can mean the KV moved to host")
        print("  memory, not that it got cheaper.")


if __name__ == "__main__":
    main()
