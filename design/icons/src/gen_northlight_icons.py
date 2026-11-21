#!/usr/bin/env python3
"""Generate Northlight app icon SVG masters (iOS + macOS).

Palette (strict): deep navy, Gemini blue #4C8DFF, iris #9A7CF6, star-white #F4F2FF,
one amber star #FFB65C. No rainbow / thin-film colours.

Writes to ../northlight/*.svg. All masters are 1024x1024.
iOS masters are full-bleed; *-mask.svg variants bake in the continuous-corner
(superellipse) mask for previews. macOS masters use a superellipse body on the
1024 grid (824 body, ~185 corner) with a soft drop shadow.
"""
import math
import os
import random

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "northlight")
W = 1024

NAVY_0 = "#03061A"
NAVY_1 = "#0B1650"
BLUE = "#4C8DFF"
IRIS = "#9A7CF6"
WHITE = "#F4F2FF"
AMBER = "#FFB65C"


def f(v):
    return f"{v:.1f}".rstrip("0").rstrip(".")


def squircle(cx, cy, a, n=5.0, steps=720):
    pts = []
    for i in range(steps):
        t = 2 * math.pi * i / steps
        c, s = math.cos(t), math.sin(t)
        x = cx + a * math.copysign(abs(c) ** (2 / n), c)
        y = cy + a * math.copysign(abs(s) ** (2 / n), s)
        pts.append(f"{x:.2f} {y:.2f}")
    return "M" + " L".join(pts) + " Z"


def bi_grad(gid, x1, y1, x2, y2, c0=BLUE, c1=IRIS, mid=None):
    stops = f'<stop offset="0" stop-color="{c0}"/>'
    if mid:
        stops += f'<stop offset=".5" stop-color="{mid}"/>'
    stops += f'<stop offset="1" stop-color="{c1}"/>'
    return (f'<linearGradient id="{gid}" gradientUnits="userSpaceOnUse" x1="{f(x1)}" y1="{f(y1)}" '
            f'x2="{f(x2)}" y2="{f(y2)}">{stops}</linearGradient>')


def common_defs():
    blur = "".join(
        f'<filter id="b{s}" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="{s}"/></filter>'
        for s in (4, 10, 18, 26, 30))
    return (
        blur +
        f'<radialGradient id="starglow"><stop offset="0" stop-color="{WHITE}" stop-opacity="1"/>'
        f'<stop offset=".08" stop-color="{WHITE}" stop-opacity=".9"/>'
        f'<stop offset=".24" stop-color="{BLUE}" stop-opacity=".5"/>'
        f'<stop offset=".55" stop-color="{BLUE}" stop-opacity=".14"/>'
        f'<stop offset="1" stop-color="{BLUE}" stop-opacity="0"/></radialGradient>'
        f'<radialGradient id="amberglow"><stop offset="0" stop-color="{AMBER}" stop-opacity=".95"/>'
        f'<stop offset=".3" stop-color="{AMBER}" stop-opacity=".45"/>'
        f'<stop offset="1" stop-color="{AMBER}" stop-opacity="0"/></radialGradient>'
        f'<linearGradient id="ray" x1="0" y1="0" x2="1" y2="0">'
        f'<stop offset="0" stop-color="{WHITE}" stop-opacity="0"/>'
        f'<stop offset=".5" stop-color="{WHITE}" stop-opacity=".95"/>'
        f'<stop offset="1" stop-color="{WHITE}" stop-opacity="0"/></linearGradient>'
    )


def bg_stars(seed, n, avoid=(), rmin=1.8, rmax=3.8, box=(0, 0, W, W)):
    rnd = random.Random(seed)
    out = []
    x0, y0, x1, y1 = box
    tries = 0
    while len(out) < n and tries < 4000:
        tries += 1
        x, y = rnd.uniform(x0 + 30, x1 - 30), rnd.uniform(y0 + 30, y1 - 30)
        if any(math.hypot(x - ax, y - ay) < ar for ax, ay, ar in avoid):
            continue
        r = rnd.uniform(rmin, rmax)
        op = rnd.uniform(.45, .9)
        out.append(f'<circle cx="{f(x)}" cy="{f(y)}" r="{f(r)}" fill="{WHITE}" opacity="{f(op)}"/>')
    return "".join(out)


def six_ray_star(cx, cy, core=36, main_len=300, diag_len=240, w=7, ring=True, ring_r=74, glow_r=380):
    s = [f'<circle cx="{cx}" cy="{cy}" r="{glow_r}" fill="url(#starglow)"/>']
    for ang, L in ((90, main_len), (30, diag_len), (-30, diag_len)):
        s.append(f'<g transform="translate({cx} {cy}) rotate({ang})">'
                 f'<polygon points="{-L},0 0,{-w} {L},0 0,{w}" fill="url(#ray)"/></g>')
    if ring:
        s.append(f'<circle cx="{cx}" cy="{cy}" r="{ring_r}" fill="none" stroke="url(#ringG)" stroke-width="16" opacity=".6" filter="url(#b10)"/>')
        s.append(f'<circle cx="{cx}" cy="{cy}" r="{ring_r}" fill="none" stroke="url(#ringG)" stroke-width="6"/>')
    s.append(f'<circle cx="{cx}" cy="{cy}" r="{core*1.9}" fill="{WHITE}" opacity=".55" filter="url(#b18)"/>')
    s.append(f'<circle cx="{cx}" cy="{cy}" r="{core}" fill="#FFFFFF"/>')
    return "".join(s)


def amber_star(cx, cy, r=10):
    return (f'<circle cx="{cx}" cy="{cy}" r="{r*5}" fill="url(#amberglow)" opacity=".85"/>'
            f'<circle cx="{cx}" cy="{cy}" r="{r}" fill="{AMBER}"/>'
            f'<circle cx="{cx}" cy="{cy}" r="{r*0.45}" fill="{WHITE}" opacity=".85"/>')


def svg(defs, body, mask=False):
    if mask:
        defs += f'<clipPath id="sq"><path d="{squircle(512, 512, 512)}"/></clipPath>'
        body = f'<g clip-path="url(#sq)">{body}</g>'
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {W}" width="{W}" height="{W}">'
            f'<defs>{common_defs()}{defs}</defs>{body}</svg>')


def write(name, content):
    with open(os.path.join(OUT, name), "w") as fh:
        fh.write(content)


# ---------------------------------------------------------------- iOS A
def ios_a(mode="default"):
    """Window to the sky: constellation viewfinder corners + guide star at the thirds point."""
    sx, sy = 624, 404
    ax, ay = 366, 668
    m, a = 196, 170
    d, b = [], []
    if mode == "default":
        d.append(f'<linearGradient id="sky" x1="0.25" y1="0" x2="0.62" y2="1">'
                 f'<stop offset="0" stop-color="{NAVY_0}"/><stop offset=".38" stop-color="{NAVY_1}"/>'
                 f'<stop offset=".8" stop-color="{BLUE}"/><stop offset="1" stop-color="{IRIS}"/></linearGradient>'
                 f'<radialGradient id="hz" cx=".5" cy="1.08" r=".62"><stop offset="0" stop-color="{IRIS}" stop-opacity=".8"/>'
                 f'<stop offset="1" stop-color="{IRIS}" stop-opacity="0"/></radialGradient>')
        b.append(f'<rect width="{W}" height="{W}" fill="url(#sky)"/><rect width="{W}" height="{W}" fill="url(#hz)"/>')
    elif mode == "dark":
        d.append(f'<linearGradient id="sky" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#0D1028"/>'
                 f'<stop offset="1" stop-color="#020309"/></linearGradient>'
                 f'<radialGradient id="hz" cx=".61" cy=".39" r=".55"><stop offset="0" stop-color="{NAVY_1}" stop-opacity=".9"/>'
                 f'<stop offset="1" stop-color="{NAVY_1}" stop-opacity="0"/></radialGradient>')
        b.append(f'<rect width="{W}" height="{W}" fill="url(#sky)"/><rect width="{W}" height="{W}" fill="url(#hz)"/>')
    else:
        b.append(f'<rect width="{W}" height="{W}" fill="#000"/>')
    d.append(bi_grad("ringG", sx - 100, sy - 100, sx + 100, sy + 100))
    b.append(bg_stars(7, 12, avoid=((sx, sy, 170), (ax, ay, 70), (512, 512, 0))))
    b.append(f'<circle cx="{sx}" cy="{sy}" r="330" fill="url(#starglow)"/>')
    b.append(f'<g transform="rotate(-20 {sx} {sy})"><ellipse cx="{sx}" cy="{sy}" rx="214" ry="56" fill="none" stroke="{WHITE}" stroke-width="3" opacity=".5"/>'
             f'<circle cx="{sx-188}" cy="{sy+27}" r="8" fill="{WHITE}"/></g>')
    dx, dy = sx - ax, sy - ay
    L = math.hypot(dx, dy)
    ux, uy = dx / L, dy / L
    b.append(f'<line x1="{f(ax+ux*36)}" y1="{f(ay+uy*36)}" x2="{f(sx-ux*126)}" y2="{f(sy-uy*126)}" stroke="{WHITE}" stroke-width="3.5" stroke-linecap="round" stroke-dasharray="0.1 16" opacity=".6"/>')
    corners = {
        "TL": [(m, m + a), (m, m), (m + a, m)],
        "TR": [(W - m - a, m), (W - m, m), (W - m, m + a)],
        "BL": [(m, W - m - a), (m, W - m), (m + a, W - m)],
        "BR": [(W - m - a, W - m), (W - m, W - m), (W - m, W - m - a)],
    }
    for k, pts in corners.items():
        ptxt = " ".join(f"{x},{y}" for x, y in pts)
        if k == "TR":
            b.append(f'<polyline points="{ptxt}" fill="none" stroke="{BLUE}" stroke-width="54" stroke-linecap="round" stroke-linejoin="round" opacity=".9" filter="url(#b18)"/>')
        b.append(f'<polyline points="{ptxt}" fill="none" stroke="{WHITE}" stroke-width="18" stroke-linecap="round" stroke-linejoin="round"/>')
        for i, (x, y) in enumerate(pts):
            r = 19 if i == 1 else 12
            b.append(f'<circle cx="{x}" cy="{y}" r="{r*2.2}" fill="{WHITE}" opacity=".3" filter="url(#b10)"/>'
                     f'<circle cx="{x}" cy="{y}" r="{r}" fill="#FFFFFF"/>')
    b.append(f'<circle cx="{sx}" cy="{sy}" r="90" fill="none" stroke="url(#ringG)" stroke-width="30" opacity=".6" filter="url(#b10)"/>'
             f'<circle cx="{sx}" cy="{sy}" r="90" fill="none" stroke="url(#ringG)" stroke-width="12"/>'
             f'<circle cx="{sx}" cy="{sy}" r="118" fill="none" stroke="{WHITE}" stroke-width="2" opacity=".35"/>'
             f'<circle cx="{sx}" cy="{sy}" r="68" fill="{WHITE}" opacity=".6" filter="url(#b18)"/>'
             f'<circle cx="{sx}" cy="{sy}" r="38" fill="#FFFFFF"/>')
    b.append(amber_star(ax, ay, 12))
    body = "".join(b)
    if mode == "tint":
        d.append('<filter id="gray" filterUnits="userSpaceOnUse" x="0" y="0" width="1024" height="1024"><feColorMatrix type="saturate" values="0"/></filter>')
        body = f'<g filter="url(#gray)">{body}</g>'
    elif mode in ("tint-blue", "tint-amber"):
        tr, tg, tb = (0.30, 0.55, 1.0) if mode == "tint-blue" else (1.0, 0.71, 0.36)
        mat = " ".join(f"{t*.2126:.4f} {t*.7152:.4f} {t*.0722:.4f} 0 0" for t in (tr, tg, tb)) + " 0 0 0 1 0"
        d.append(f'<filter id="tintf" filterUnits="userSpaceOnUse" x="0" y="0" width="1024" height="1024"><feColorMatrix type="matrix" values="{mat}"/></filter>')
        body = f'<g filter="url(#tintf)">{body}</g>'
    return "".join(d), body


# ---------------------------------------------------------------- iOS B
def wave(base, amp, lam, ph, x):
    return base + amp * math.sin(2*math.pi*x/lam + ph) + amp*0.45*math.sin(2*math.pi*x/(lam*0.47) + ph*1.7)


def ios_b():
    """North star rising over layered engraved depth contours."""
    sx, sy = 512, 500
    d = [f'<linearGradient id="sky" x1="0" y1="0" x2="0" y2="1">'
         f'<stop offset="0" stop-color="{NAVY_0}"/><stop offset=".30" stop-color="{NAVY_1}"/>'
         f'<stop offset=".54" stop-color="{BLUE}"/><stop offset=".66" stop-color="{IRIS}"/></linearGradient>',
         f'<radialGradient id="lit" gradientUnits="userSpaceOnUse" cx="512" cy="620" r="560">'
         f'<stop offset="0" stop-color="{WHITE}" stop-opacity=".6"/><stop offset=".5" stop-color="{BLUE}" stop-opacity=".3"/>'
         f'<stop offset="1" stop-color="{BLUE}" stop-opacity=".1"/></radialGradient>',
         bi_grad("ringG", sx - 90, sy - 90, sx + 90, sy + 90),
         bi_grad("edgeG", 0, 0, W, 0, BLUE, IRIS, WHITE)]
    b = [f'<rect width="{W}" height="{W}" fill="url(#sky)"/>']
    b.append(bg_stars(21, 12, avoid=((sx, sy, 200),), box=(0, 0, W, 560)))
    b.append(f'<circle cx="{sx}" cy="{sy}" r="200" fill="none" stroke="{WHITE}" stroke-width="2.6" stroke-dasharray="0.1 14" stroke-linecap="round" opacity=".5"/>')
    b.append(amber_star(806, 230, 11))
    b.append(six_ray_star(sx, sy, core=46, main_len=380, diag_len=290, w=9, ring_r=92, glow_r=470))
    bands = [
        (640, 22, 900, 0.6, "#1A2C9A", "#122070"),
        (730, 24, 760, 2.2, "#13206E", "#0D1650"),
        (822, 22, 980, 4.1, "#0B1450", "#081038"),
        (914, 18, 820, 1.3, "#070D34", "#040822"),
    ]
    xs = list(range(-16, W + 33, 16))
    for i, (base, amp, lam, ph, c0, c1) in enumerate(bands):
        def yy(x, base=base, amp=amp, lam=lam, ph=ph, i=i):
            v = wave(base, amp, lam, ph, x)
            if i == 0:
                v += 26 * math.exp(-((x - sx) / 170) ** 2) - 18
            return v
        top = "M" + " L".join(f"{x} {f(yy(x))}" for x in xs)
        d.append(f'<linearGradient id="bf{i}" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="{c0}"/><stop offset=".4" stop-color="{c1}"/></linearGradient>')
        b.append(f'<path d="{top} L{W+32} {W+32} L-16 {W+32} Z" fill="url(#bf{i})"/>')
        nxt = bands[i + 1][0] if i + 1 < len(bands) else W + 40
        n = max(1, int((nxt - base) / 28))
        lines = []
        for j in range(1, n + 1):
            k = 1 - j / (n + 2)
            lines.append("M" + " L".join(f"{x} {f(base + j*28 + (yy(x) - base)*k)}" for x in xs))
        b.append(f'<path d="{"".join(lines)}" fill="none" stroke="url(#lit)" stroke-width="2" opacity="{f(1 - i*0.15)}"/>')
        if i == 0:
            b.append(f'<path d="{top}" fill="none" stroke="url(#edgeG)" stroke-width="14" opacity=".55" filter="url(#b10)"/>')
            b.append(f'<path d="{top}" fill="none" stroke="url(#edgeG)" stroke-width="5"/>')
        else:
            b.append(f'<path d="{top}" fill="none" stroke="url(#lit)" stroke-width="3"/>')
    return "".join(d), "".join(b)


# ---------------------------------------------------------------- iOS C
def ios_c():
    """Light through glass: blue-iris halo partly eclipsed by a matte crescent over a lensed chart grid."""
    cx, cy, R = 512, 512, 300
    A = (432, 598, 322)
    B = (548, 478, 300)
    d = [f'<radialGradient id="bg" cx=".55" cy=".45" r=".75"><stop offset="0" stop-color="#14205E"/>'
         f'<stop offset=".55" stop-color="#080E30"/><stop offset="1" stop-color="{NAVY_0}"/></radialGradient>',
         f'<radialGradient id="gridlit" gradientUnits="userSpaceOnUse" cx="560" cy="470" r="340">'
         f'<stop offset="0" stop-color="{WHITE}" stop-opacity=".42"/><stop offset="1" stop-color="{BLUE}" stop-opacity=".16"/></radialGradient>',
         f'<radialGradient id="inner" cx=".5" cy=".5" r=".5"><stop offset="0" stop-color="{BLUE}" stop-opacity="0"/>'
         f'<stop offset=".8" stop-color="{BLUE}" stop-opacity=".16"/><stop offset=".97" stop-color="{IRIS}" stop-opacity=".4"/>'
         f'<stop offset="1" stop-color="{IRIS}" stop-opacity="0"/></radialGradient>',
         bi_grad("ringG", cx + R, cy - R, cx - R, cy + R, BLUE, IRIS),
         f'<linearGradient id="matte" x1="0.1" y1="1" x2="0.7" y2="0.2"><stop offset="0" stop-color="#1A2250"/>'
         f'<stop offset=".5" stop-color="#0C1130"/><stop offset="1" stop-color="#070A1E"/></linearGradient>',
         f'<mask id="cres" maskUnits="userSpaceOnUse" x="0" y="0" width="{W}" height="{W}"><rect width="{W}" height="{W}" fill="#fff"/>'
         f'<circle cx="{B[0]}" cy="{B[1]}" r="{B[2]}" fill="#000"/></mask>',
         f'<clipPath id="inA"><circle cx="{A[0]}" cy="{A[1]}" r="{A[2]}"/></clipPath>',
         f'<clipPath id="lensC"><circle cx="{cx}" cy="{cy}" r="{R-2}"/></clipPath>']
    b = [f'<rect width="{W}" height="{W}" fill="url(#bg)"/>']
    Rl = 340

    def lens(x, y):
        dx, dy = x - cx, y - cy
        r = math.hypot(dx, dy)
        if r < 1e-6 or r >= Rl:
            return x, y
        r2 = Rl * (r / Rl) ** 0.62
        return cx + dx * r2 / r, cy + dy * r2 / r
    paths = []
    ts = [i * 8 for i in range(0, W // 8 + 1)]
    for k in range(-4, 5):
        c = 512 + k * 84
        paths.append("M" + " L".join(f"{f(x)} {f(y)}" for x, y in (lens(c, t) for t in ts)))
        paths.append("M" + " L".join(f"{f(x)} {f(y)}" for x, y in (lens(t, c) for t in ts)))
    b.append(f'<g clip-path="url(#lensC)"><path d="{"".join(paths)}" fill="none" stroke="url(#gridlit)" stroke-width="2.2"/></g>')
    b.append(bg_stars(5, 10, avoid=((cx, cy, 400),)))
    b.append(amber_star(846, 176, 11))
    b.append(f'<circle cx="{cx}" cy="{cy}" r="{R}" fill="url(#inner)"/>')
    b.append(f'<circle cx="{cx}" cy="{cy}" r="{R}" fill="none" stroke="url(#ringG)" stroke-width="80" opacity=".5" filter="url(#b30)"/>')
    b.append(f'<circle cx="{cx}" cy="{cy}" r="{R}" fill="none" stroke="url(#ringG)" stroke-width="34"/>')
    b.append(f'<circle cx="{cx}" cy="{cy}" r="{R-10}" fill="none" stroke="{WHITE}" stroke-width="3" opacity=".55"/>')
    b.append(f'<circle cx="{A[0]+10}" cy="{A[1]+16}" r="{A[2]}" fill="#000" opacity=".55" filter="url(#b18)" mask="url(#cres)"/>')
    b.append(f'<circle cx="{A[0]}" cy="{A[1]}" r="{A[2]}" fill="url(#matte)" mask="url(#cres)"/>')
    b.append(f'<g clip-path="url(#inA)"><circle cx="{B[0]}" cy="{B[1]}" r="{B[2]}" fill="none" stroke="{IRIS}" stroke-width="10" opacity=".6" filter="url(#b4)"/>'
             f'<circle cx="{B[0]}" cy="{B[1]}" r="{B[2]}" fill="none" stroke="{IRIS}" stroke-width="3"/></g>')
    tx, ty = 330, 268
    prev = None
    for i in range(3600):
        t = 2 * math.pi * i / 3600
        x, y = cx + R * math.cos(t), cy + R * math.sin(t)
        occ = math.hypot(x - A[0], y - A[1]) < A[2] and not math.hypot(x - B[0], y - B[1]) < B[2]
        if prev is not None and occ != prev and y < 512:
            tx, ty = x, y
            break
        prev = occ
    b.append(six_ray_star(int(tx), int(ty), core=26, main_len=210, diag_len=160, w=5.5, ring=False, glow_r=260))
    return "".join(d), "".join(b)


# ---------------------------------------------------------------- macOS
def mac_wrap(defs, inner):
    body_d = squircle(512, 512, 412)
    defs += (f'<clipPath id="body"><path d="{body_d}"/></clipPath>'
             '<filter id="drop" x="-20%" y="-20%" width="140%" height="150%"><feDropShadow dx="0" dy="12" stdDeviation="14" flood-color="#000" flood-opacity=".34"/></filter>'
             f'<linearGradient id="rimL" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="{WHITE}" stop-opacity=".30"/>'
             f'<stop offset=".35" stop-color="{WHITE}" stop-opacity=".04"/><stop offset="1" stop-color="{WHITE}" stop-opacity=".08"/></linearGradient>')
    body = (f'<path d="{body_d}" fill="{NAVY_1}" filter="url(#drop)"/>'
            f'<g clip-path="url(#body)">{inner}</g>'
            f'<path d="{body_d}" fill="none" stroke="url(#rimL)" stroke-width="3"/>')
    return defs, body


def mac_console():
    """Dark matte fader console at an angle; one slot glows blue-iris, a star above it."""
    FL, FR, BL = (300, 812), (872, 684), (194, 600)
    BR = (FR[0] + BL[0] - FL[0], FR[1] + BL[1] - FL[1])
    T = 56

    def P(u, v):
        return (FL[0] + u*(FR[0]-FL[0]) + v*(BL[0]-FL[0]), FL[1] + u*(FR[1]-FL[1]) + v*(BL[1]-FL[1]))

    def pts(seq):
        return " ".join(f"{f(x)},{f(y)}" for x, y in seq)
    lit_u = 0.68
    top_end = P(lit_u, 0.9)
    sx, sy = int(top_end[0]) + 8, 300
    d = [f'<linearGradient id="sky" x1="0" y1="0" x2="0" y2="1"><stop offset=".1" stop-color="{NAVY_0}"/>'
         f'<stop offset=".45" stop-color="{NAVY_1}"/><stop offset=".72" stop-color="{BLUE}"/>'
         f'<stop offset="1" stop-color="{IRIS}"/></linearGradient>',
         '<linearGradient id="topF" gradientUnits="userSpaceOnUse" x1="560" y1="540" x2="520" y2="800">'
         '<stop offset="0" stop-color="#262C4E"/><stop offset="1" stop-color="#13182E"/></linearGradient>',
         '<linearGradient id="frontF" x1="0" y1="0" x2="1" y2="0"><stop offset="0" stop-color="#0A0D1E"/><stop offset="1" stop-color="#11152B"/></linearGradient>',
         f'<linearGradient id="capT" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="{WHITE}"/><stop offset="1" stop-color="#B8BDD8"/></linearGradient>',
         bi_grad("slotG", *P(lit_u, 0.1), *P(lit_u, 0.9), BLUE, IRIS),
         bi_grad("ringG", sx - 70, sy - 70, sx + 70, sy + 70),
         f'<clipPath id="slabTop"><polygon points="{pts([FL, FR, BR, BL])}"/></clipPath>']
    b = ['<rect x="100" y="100" width="824" height="824" fill="url(#sky)"/>']
    b.append(bg_stars(3, 8, avoid=((sx, sy, 170),), box=(140, 140, 884, 520)))
    b.append(amber_star(250, 280, 10))
    b.append(six_ray_star(sx, sy, core=32, main_len=230, diag_len=180, w=6.5, ring_r=62, glow_r=320))
    b.append(f'<line x1="{sx}" y1="{sy+74}" x2="{f(top_end[0])}" y2="{f(top_end[1]-12)}" stroke="{WHITE}" stroke-width="3.5" stroke-linecap="round" stroke-dasharray="0.1 15" opacity=".65"/>')
    cxm = (FL[0] + FR[0] + BL[0] + BR[0]) / 4
    b.append(f'<ellipse cx="{f(cxm+30)}" cy="800" rx="360" ry="70" fill="#020414" opacity=".7" filter="url(#b30)"/>')
    FLd, FRd, BLd = (FL[0], FL[1]+T), (FR[0], FR[1]+T), (BL[0], BL[1]+T)
    b.append(f'<polygon points="{pts([BL, FL, FLd, BLd])}" fill="#070915" stroke="#070915" stroke-width="22" stroke-linejoin="round"/>')
    b.append(f'<polygon points="{pts([FL, FR, FRd, FLd])}" fill="url(#frontF)" stroke="#0D1024" stroke-width="22" stroke-linejoin="round"/>')
    b.append(f'<polygon points="{pts([FL, FR, BR, BL])}" fill="url(#topF)" stroke="url(#topF)" stroke-width="22" stroke-linejoin="round"/>')
    b.append(f'<polyline points="{pts([BL, BR])}" fill="none" stroke="{IRIS}" stroke-width="3" stroke-linecap="round" opacity=".7" transform="translate(0 -10)"/>')
    b.append(f'<line x1="{FL[0]}" y1="{FL[1]+11}" x2="{FR[0]}" y2="{FR[1]+11}" stroke="{WHITE}" stroke-width="2" opacity=".14"/>')
    sp = P(lit_u, 0.62)
    b.append(f'<g clip-path="url(#slabTop)"><ellipse cx="{f(sp[0])}" cy="{f(sp[1])}" rx="170" ry="130" fill="{IRIS}" opacity=".38" filter="url(#b30)"/></g>')
    us = [0.16, 0.32, 0.50, lit_u, 0.84]
    caps = [0.36, 0.58, 0.28, 0.80, 0.50]
    for u, cv in zip(us, caps):
        lit = abs(u - lit_u) < 1e-6
        p0, p1 = P(u, 0.1), P(u, 0.9)
        if lit:
            ticks = []
            for j in range(9):
                v = 0.1 + j * 0.1
                a0, a1 = P(u - 0.045, v), P(u - (0.075 if j % 4 == 0 else 0.06), v)
                ticks.append(f"M{f(a0[0])} {f(a0[1])}L{f(a1[0])} {f(a1[1])}")
            b.append(f'<path d="{"".join(ticks)}" stroke="{WHITE}" stroke-width="2" opacity=".35"/>')
            b.append(f'<line x1="{f(p0[0])}" y1="{f(p0[1])}" x2="{f(p1[0])}" y2="{f(p1[1])}" stroke="url(#slotG)" stroke-width="56" stroke-linecap="round" opacity="1" filter="url(#b18)"/>')
            b.append(f'<line x1="{f(p0[0])}" y1="{f(p0[1])}" x2="{f(p1[0])}" y2="{f(p1[1])}" stroke="url(#slotG)" stroke-width="13" stroke-linecap="round"/>')
            b.append(f'<line x1="{f(p0[0])}" y1="{f(p0[1])}" x2="{f(p1[0])}" y2="{f(p1[1])}" stroke="{WHITE}" stroke-width="5" stroke-linecap="round" opacity=".9"/>')
        else:
            b.append(f'<line x1="{f(p0[0])}" y1="{f(p0[1])}" x2="{f(p1[0])}" y2="{f(p1[1])}" stroke="#04050B" stroke-width="13" stroke-linecap="round"/>')
        hw, hd = 0.055, 0.045
        c = [P(u - hw, cv - hd), P(u + hw, cv - hd), P(u + hw, cv + hd), P(u - hw, cv + hd)]
        ch = 22
        front = [c[0], c[1], (c[1][0], c[1][1] + ch), (c[0][0], c[0][1] + ch)]
        side = [c[3], c[0], (c[0][0], c[0][1] + ch), (c[3][0], c[3][1] + ch)]
        sidec, frontc = ("#B9A8FF", "#DCD3FF") if lit else ("#4E5472", "#7E84A2")
        b.append(f'<ellipse cx="{f((c[0][0]+c[2][0])/2+6)}" cy="{f((c[0][1]+c[2][1])/2+18)}" rx="44" ry="18" fill="#000" opacity=".45" filter="url(#b10)"/>')
        b.append(f'<polygon points="{pts(side)}" fill="{sidec}" stroke="{sidec}" stroke-width="6" stroke-linejoin="round"/>')
        b.append(f'<polygon points="{pts(front)}" fill="{frontc}" stroke="{frontc}" stroke-width="6" stroke-linejoin="round"/>')
        b.append(f'<polygon points="{pts(c)}" fill="{"#FFFFFF" if lit else "url(#capT)"}" stroke="{"#FFFFFF" if lit else "#C9CCE4"}" stroke-width="6" stroke-linejoin="round"/>')
        mid0, mid1 = lerp(c[0], c[3], .5), lerp(c[1], c[2], .5)
        b.append(f'<line x1="{f(mid0[0])}" y1="{f(mid0[1])}" x2="{f(mid1[0])}" y2="{f(mid1[1])}" stroke="{IRIS if lit else "#454B68"}" stroke-width="3" stroke-linecap="round"/>')
        if lit:
            ccx, ccy = (c[0][0]+c[2][0])/2, (c[0][1]+c[2][1])/2
            b.append(f'<circle cx="{f(ccx)}" cy="{f(ccy)}" r="70" fill="{BLUE}" opacity=".45" filter="url(#b18)"/>')
    return mac_wrap("".join(d), "".join(b))


def lerp(p, q, t):
    return (p[0] + (q[0] - p[0]) * t, p[1] + (q[1] - p[1]) * t)


def mac_frost():
    """Frosted matte glass slab with the Gemini constellation lit inside it."""
    tx, ty, rot = 500, 520, -8
    pw, ph, pr = 452, 560, 70
    d = [f'<linearGradient id="bg" gradientUnits="userSpaceOnUse" x1="140" y1="100" x2="880" y2="924">'
         f'<stop offset="0" stop-color="{NAVY_0}"/><stop offset=".45" stop-color="{NAVY_1}"/>'
         f'<stop offset=".8" stop-color="{BLUE}"/><stop offset="1" stop-color="{IRIS}"/></linearGradient>',
         bi_grad("ringO", 140, 300, 900, 760, WHITE, IRIS),
         bi_grad("ringG", -130, -230, -50, -150),
         f'<linearGradient id="frost" x1="0" y1="0" x2="0.6" y2="1"><stop offset="0" stop-color="{WHITE}" stop-opacity=".30"/>'
         f'<stop offset=".5" stop-color="{WHITE}" stop-opacity=".12"/><stop offset="1" stop-color="{WHITE}" stop-opacity=".06"/></linearGradient>',
         f'<linearGradient id="edge" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="{WHITE}" stop-opacity=".9"/>'
         f'<stop offset=".45" stop-color="{WHITE}" stop-opacity=".15"/><stop offset="1" stop-color="{WHITE}" stop-opacity=".45"/></linearGradient>',
         f'<clipPath id="plate"><rect x="{-pw/2}" y="{-ph/2}" width="{pw}" height="{ph}" rx="{pr}" transform="translate({tx} {ty}) rotate({rot})"/></clipPath>']
    scene = (f'<g transform="rotate(-16 512 560)"><ellipse cx="512" cy="560" rx="400" ry="138" fill="none" stroke="url(#ringO)" stroke-width="40" opacity=".45" filter="url(#b18)"/>'
             f'<ellipse cx="512" cy="560" rx="400" ry="138" fill="none" stroke="url(#ringO)" stroke-width="14"/></g>'
             f'<circle cx="760" cy="300" r="240" fill="url(#starglow)"/>'
             f'<circle cx="760" cy="300" r="26" fill="#FFFFFF"/>')
    b = ['<rect x="100" y="100" width="824" height="824" fill="url(#bg)"/>']
    b.append(bg_stars(9, 8, avoid=((760, 300, 140), (500, 520, 330)), box=(140, 140, 884, 884)))
    b.append(scene)
    b.append(f'<g transform="translate({tx+26} {ty+40}) rotate({rot})"><rect x="{-pw/2}" y="{-ph/2}" width="{pw}" height="{ph}" rx="{pr}" fill="#020418" opacity=".55" filter="url(#b30)"/></g>')
    b.append(f'<g transform="translate({tx+10} {ty+16}) rotate({rot})"><rect x="{-pw/2}" y="{-ph/2}" width="{pw}" height="{ph}" rx="{pr}" fill="{WHITE}" opacity=".38"/></g>')
    b.append(f'<g clip-path="url(#plate)"><rect x="100" y="100" width="824" height="824" fill="url(#bg)"/>'
             f'<g filter="url(#b26)">{scene}</g>'
             f'<rect width="{W}" height="{W}" fill="{WHITE}" opacity=".10"/></g>')
    p = [f'<g transform="translate({tx} {ty}) rotate({rot})">']
    p.append(f'<rect x="{-pw/2}" y="{-ph/2}" width="{pw}" height="{ph}" rx="{pr}" fill="url(#frost)"/>')
    stars = {
        "castor": (-92, -190), "c2": (-104, -62), "c3": (-122, 62), "c4": (-146, 188),
        "pollux": (74, -160), "p2": (62, -40), "p3": (84, 84), "p4": (112, 200),
        "ca": (-176, -100), "pa": (152, -78), "pb": (160, 110),
    }
    edges = [("castor", "c2"), ("c2", "c3"), ("c3", "c4"), ("pollux", "p2"), ("p2", "p3"), ("p3", "p4"),
             ("castor", "pollux"), ("c2", "p2"), ("c2", "ca"), ("p2", "pa"), ("p3", "pb")]
    ed = "".join(f"M{stars[a][0]} {stars[a][1]}L{stars[c][0]} {stars[c][1]}" for a, c in edges)
    p.append(f'<path d="{ed}" stroke="{IRIS}" stroke-width="22" stroke-linecap="round" opacity=".55" filter="url(#b10)"/>')
    p.append(f'<path d="{ed}" stroke="{WHITE}" stroke-width="7" stroke-linecap="round"/>')
    for name, (x, y) in stars.items():
        if name == "pollux":
            p.append(amber_star(x, y, 17))
            continue
        r = 16 if name == "castor" else (11 if name in ("c2", "p2", "c3", "p3") else 9)
        p.append(f'<circle cx="{x}" cy="{y}" r="{r*2.6}" fill="{WHITE}" opacity=".45" filter="url(#b10)"/>'
                 f'<circle cx="{x}" cy="{y}" r="{r}" fill="#FFFFFF"/>')
    p.append(f'<circle cx="{stars["castor"][0]}" cy="{stars["castor"][1]}" r="34" fill="none" stroke="url(#ringG)" stroke-width="5"/>')
    p.append(f'<rect x="{-pw/2}" y="{-ph/2}" width="{pw}" height="{ph}" rx="{pr}" fill="none" stroke="url(#edge)" stroke-width="3"/>')
    p.append('</g>')
    b.append("".join(p))
    return mac_wrap("".join(d), "".join(b))


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    for old in os.listdir(OUT):
        if old.endswith(".svg"):
            os.remove(os.path.join(OUT, old))
    ios = {
        "ios-a-window": ios_a("default"),
        "ios-a-window-dark": ios_a("dark"),
        "ios-a-window-tinted": ios_a("tint"),
        "ios-a-window-tinted-blue": ios_a("tint-blue"),
        "ios-a-window-tinted-amber": ios_a("tint-amber"),
        "ios-b-northstar": ios_b(),
        "ios-c-glass": ios_c(),
    }
    for name, (defs, body) in ios.items():
        write(f"{name}.svg", svg(defs, body))
        write(f"{name}-mask.svg", svg(defs, body, mask=True))
    for name, (defs, body) in {"mac-1-console": mac_console(), "mac-2-frost": mac_frost()}.items():
        write(f"{name}.svg", svg(defs, body))
    print("\n".join(sorted(os.listdir(OUT))))
