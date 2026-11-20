#!/usr/bin/env python3
"""Compares two shaper dumps: glyph ids must match exactly, x positions within tol."""
import sys

def load(p):
    out = []
    with open(p) as f:
        for line in f:
            if line.startswith('#'):
                continue
            a = line.split()
            if len(a) == 3:
                out.append((int(a[0]), int(a[1]), float(a[2])))
    return out

def main():
    ref_p, got_p = sys.argv[1], sys.argv[2]
    tol = float(sys.argv[3]) if len(sys.argv) > 3 else 0.05
    ref, got = load(ref_p), load(got_p)
    print(f"glyphs: ref={len(ref)} got={len(got)}")
    if len(ref) != len(got):
        print("FAIL: glyph count differs")
        return 1
    id_bad = [i for i, (r, g) in enumerate(zip(ref, got)) if r[1] != g[1]]
    cl_bad = [i for i, (r, g) in enumerate(zip(ref, got)) if r[0] != g[0]]
    dx = [abs(r[2] - g[2]) for r, g in zip(ref, got)]
    maxdx = max(dx)
    print(f"glyph id mismatches: {len(id_bad)}")
    print(f"cluster mismatches:  {len(cl_bad)}")
    print(f"x deviation: max {maxdx:.4f} px, mean {sum(dx)/len(dx):.4f} px")
    print(f"x deviation at last glyph: {dx[-1]:.4f} px (ref {ref[-1][2]:.2f}, got {got[-1][2]:.2f})")
    over = sum(1 for d in dx if d > tol)
    print(f"glyphs over tol {tol}: {over}")
    if id_bad or cl_bad:
        for i in (id_bad + cl_bad)[:5]:
            print(f"  idx {i}: ref {ref[i]} got {got[i]}")
        print("FAIL")
        return 1
    print("glyph ids and clusters: IDENTICAL")
    return 0 if over == 0 else 2

sys.exit(main())
