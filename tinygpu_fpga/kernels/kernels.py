#!/usr/bin/env python3
"""TinyGPU benchmark kernels: assembler + memory images for gpu_soc_top.

Writes into ../mem/:
  prog.hex    NUM_KERNELS x 256 x 16-bit   program image of kernel k at [k*256 ...]
  init.hex    NUM_KERNELS x 256 x 8-bit    data memory before the launch
  expect.hex  NUM_KERNELS x 256 x 8-bit    data memory expected after the launch (all 256 bytes are checked)
  kinfo.hex   16 x 8-bit                   thread count of kernel k
  kernels.lst human-readable listing

ISA notes for the stock adam-maj/tiny-gpu datapath (8-bit, everything mod 256):
  * CMP computes (rs-rt > 0, rs-rt == 0, rs-rt < 0) in an *unsigned* context, so the "<0" flag never
    sets and the ">0" flag means "not equal".  Loops therefore use BRNE = mask 0b101, which means
    "not equal" under both the actual and the intended (signed) flag semantics.
  * MUL keeps the low 8 bits.
  * R13 = %blockIdx, R14 = %blockDim, R15 = %threadIdx (read-only).
"""
import os, random

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "mem")
BLOCK_DIM = 4          # THREADS_PER_BLOCK used by the hardware sweep (thread counts are multiples of it)

# ----------------------------------------------------------------- assembler
OPS = {"NOP": 0x0, "BR": 0x1, "CMP": 0x2, "ADD": 0x3, "SUB": 0x4, "MUL": 0x5, "DIV": 0x6,
       "LDR": 0x7, "STR": 0x8, "CONST": 0x9, "RET": 0xF}
BRNE = 0b101


def reg(tok):
    tok = tok.strip().rstrip(",").upper()
    alias = {"%BLOCKIDX": 13, "%BLOCKDIM": 14, "%THREADIDX": 15}
    if tok in alias:
        return alias[tok]
    assert tok.startswith("R"), tok
    r = int(tok[1:])
    assert 0 <= r <= 15
    return r


def assemble(src):
    lines, labels = [], {}
    for raw in src.strip().splitlines():
        line = raw.split(";")[0].strip()
        if not line:
            continue
        if line.endswith(":"):
            labels[line[:-1]] = len(lines)
            continue
        lines.append(line)
    words = []
    for line in lines:
        op, *args = line.replace(",", " ").split()
        op = op.upper()
        if op in ("ADD", "SUB", "MUL", "DIV"):
            d, s, t = map(reg, args)
            w = (OPS[op] << 12) | (d << 8) | (s << 4) | t
        elif op == "CMP":
            s, t = map(reg, args)
            w = (OPS[op] << 12) | (s << 4) | t
        elif op == "LDR":                       # LDR rd, rs   : rd = mem[rs]
            d, s = map(reg, args)
            w = (OPS[op] << 12) | (d << 8) | (s << 4)
        elif op == "STR":                       # STR rs, rt   : mem[rs] = rt
            s, t = map(reg, args)
            w = (OPS[op] << 12) | (s << 4) | t
        elif op == "CONST":
            d = reg(args[0])
            imm = int(args[1].lstrip("#"), 0)
            assert 0 <= imm <= 255
            w = (OPS[op] << 12) | (d << 8) | imm
        elif op == "BRNE":
            w = (OPS["BR"] << 12) | (BRNE << 9) | labels[args[0]]
        elif op in ("RET", "NOP"):
            w = OPS[op] << 12
        else:
            raise ValueError(line)
        words.append(w)
    assert len(words) <= 256
    return words, lines


# ----------------------------------------------------------------- kernels
def k_vecadd():
    """A[i] = A[i] + B[i], i < 128.  A at 0..127, B at 128..255 (result written over A)."""
    n = 128
    src = """
        MUL   R0, %blockIdx, %blockDim
        ADD   R0, R0, %threadIdx        ; i
        CONST R1, #128                  ; base B
        LDR   R2, R0                    ; A[i]
        ADD   R3, R1, R0
        LDR   R3, R3                    ; B[i]
        ADD   R2, R2, R3
        STR   R0, R2                    ; A[i] = A[i] + B[i]
        RET
    """
    rng = random.Random(1)
    mem = [rng.randrange(256) for _ in range(256)]
    exp = list(mem)
    for i in range(n):
        exp[i] = (mem[i] + mem[128 + i]) & 0xFF
    return "vecadd", n, src, mem, exp


def k_matmul():
    """C = A x B, 8x8 (mod 256).  A at 0..63, B at 64..127, C at 128..191.  One thread per C element."""
    N = 8
    src = """
        MUL   R0, %blockIdx, %blockDim
        ADD   R0, R0, %threadIdx        ; i
        CONST R1, #1
        CONST R2, #8                    ; N
        CONST R4, #64                   ; base B
        CONST R5, #128                  ; base C
        DIV   R6, R0, R2                ; row = i / N
        MUL   R7, R6, R2
        SUB   R7, R0, R7                ; col = i - row*N
        CONST R8, #0                    ; acc
        CONST R9, #0                    ; k
        MUL   R3, R6, R2                ; row*N  (base A = 0)
    LOOP:
        ADD   R10, R3, R9               ; &A[row][k]
        LDR   R10, R10
        MUL   R11, R9, R2
        ADD   R11, R11, R7
        ADD   R11, R11, R4              ; &B[k][col]
        LDR   R11, R11
        MUL   R12, R10, R11
        ADD   R8, R8, R12
        ADD   R9, R9, R1
        CMP   R9, R2
        BRNE  LOOP
        ADD   R10, R5, R0
        STR   R10, R8                   ; C[i] = acc
        RET
    """
    rng = random.Random(2)
    mem = [0] * 256
    for i in range(128):
        mem[i] = rng.randrange(16)
    exp = list(mem)
    for r in range(N):
        for c in range(N):
            exp[128 + r * N + c] = sum(mem[r * N + k] * mem[64 + k * N + c] for k in range(N)) & 0xFF
    return "matmul", N * N, src, mem, exp


def k_compute():
    """out[i] = f^16(i) with f(x) = x*x + i (mod 256), i < 128.  ALU-bound: one store per thread."""
    n, iters = 128, 16
    src = f"""
        MUL   R0, %blockIdx, %blockDim
        ADD   R0, R0, %threadIdx        ; i
        CONST R4, #1
        CONST R5, #{iters}
        CONST R6, #0                    ; j
        ADD   R1, R0, R6                ; x = i
    LOOP:
        MUL   R1, R1, R1
        ADD   R1, R1, R0                ; x = x*x + i
        ADD   R6, R6, R4
        CMP   R6, R5
        BRNE  LOOP
        STR   R0, R1                    ; out[i] = x
        RET
    """
    mem = [0] * 256
    exp = list(mem)
    for i in range(n):
        x = i
        for _ in range(iters):
            x = (x * x + i) & 0xFF
        exp[i] = x
    return "compute", n, src, mem, exp


KERNELS = [k_vecadd, k_matmul, k_compute]


def main():
    os.makedirs(OUT, exist_ok=True)
    prog, init, expect, kinfo, lst = [], [], [], [0] * 16, []
    for k, fn in enumerate(KERNELS):
        name, threads, src, mem, exp = fn()
        assert threads % BLOCK_DIM == 0 and threads <= 255
        words, lines = assemble(src)
        prog += words + [0xF000] * (256 - len(words))      # pad with RET
        init += mem
        expect += exp
        kinfo[k] = threads
        lst.append(f"K{k} {name}: {threads} threads, {len(words)} instructions")
        lst += [f"  {a:3d}: {w:04x}   {l}" for a, (w, l) in enumerate(zip(words, lines))]
    with open(os.path.join(OUT, "prog.hex"), "w") as fh:
        fh.write("\n".join(f"{w:04x}" for w in prog) + "\n")
    for name, img in (("init.hex", init), ("expect.hex", expect), ("kinfo.hex", kinfo)):
        with open(os.path.join(OUT, name), "w") as fh:
            fh.write("\n".join(f"{b:02x}" for b in img) + "\n")
    with open(os.path.join(OUT, "kernels.lst"), "w") as fh:
        fh.write("\n".join(lst) + "\n")
    print("\n".join(l for l in lst if l.startswith("K")))
    print(f"NUM_KERNELS = {len(KERNELS)}")


if __name__ == "__main__":
    main()
