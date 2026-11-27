#!/usr/bin/env python3
"""Generate hero + pipeline SVGs (dark/light) for the README, system font stack, no binaries in repo."""
from pathlib import Path

HERE = Path(__file__).parent
OUT = HERE.parent / "assets"
OUT.mkdir(exist_ok=True)


T = {
    "dark": dict(bg="none", fg="#e6edf3", dim="#8b949e", chip="#21262d", chipln="#30363d",
                 accent="#3fb950", accent2="#58a6ff", warn="#d29922"),
    "light": dict(bg="none", fg="#1f2328", dim="#59636e", chip="#f6f8fa", chipln="#d1d9e0",
                  accent="#1a7f37", accent2="#0969da", warn="#9a6700"),
}

def font_css():
    # No embedded fonts: GitHub renders <img> SVGs with the viewer's system UI
    # font, which is exactly the stack below. The repo carries no binaries.
    return ("text{font-family:system-ui,-apple-system,'Segoe UI',Roboto,'Helvetica Neue',Arial,sans-serif}")

def chip(x, y, w, label, th, fill=None, stroke=None, fg=None, size=15, weight=500):
    f = fill or th["chip"]
    s = stroke or th["chipln"]
    c = fg or th["fg"]
    return (f'<rect x="{x}" y="{y}" width="{w}" height="34" rx="17" fill="{f}" stroke="{s}" stroke-width="1.2"/>'
            f'<text x="{x + w/2}" y="{y + 22}" text-anchor="middle" font-size="{size}" font-weight="{weight}" fill="{c}">{label}</text>')

def hero(theme):
    th = T[theme]
    lanes = ["vanilla", "turboquant", "prism", "atomic", "imp", "infernix", "basalt", "unsloth"]
    xs = [16, 112, 224, 304, 384, 452, 548, 648]
    ws = [88, 104, 72, 72, 60, 88, 92, 92]
    parts = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 800 250" width="800" height="250"><style>{font_css()}</style>']
    parts.append(f'<text x="20" y="62" font-size="44" font-weight="800" fill="{th["fg"]}">llama-swap <tspan fill="{th["accent2"]}">CUDA</tspan></text>')
    parts.append(f'<text x="21" y="96" font-size="17" font-weight="500" fill="{th["dim"]}">eight CUDA 13.4 engines · one image · built nightly for sm_120</text>')
    for name, x, w in zip(lanes, xs, ws):
        accent = name in ("basalt", "infernix")  # not-llama.cpp engines
        parts.append(chip(x, 124, w, name, th,
                          fill=(th["chip"]), stroke=(th["accent"] if accent else th["chipln"]),
                          fg=(th["accent"] if accent else th["fg"]), size=14))
    parts.append(f'<text x="20" y="196" font-size="13" font-weight="500" fill="{th["dim"]}">green border = not a llama.cpp fork: MoE engine + NInfer-lineage engine</text>')
    stats = [("8.1 GB", "image on disk, 8 engines"), ("~9 s", "slot cold-boot"), ("470-570 tok/s", "MoE decode, RTX 5090")]
    x = 20
    for val, lab in stats:
        w = 250
        parts.append(f'<text x="{x}" y="232" font-size="21" font-weight="800" fill="{th["accent"]}">{val}</text>')
        parts.append(f'<text x="{x + 4}" y="248" font-size="13" font-weight="500" fill="{th["dim"]}">{lab}</text>')
        x += w
    return "\n".join(parts) + "\n</svg>"

def pipeline(theme):
    th = T[theme]
    p = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 800 344" width="800" height="344"><style>{font_css()}</style>']
    def arrow(x1, y1, x2, y2, col):
        return (f'<line x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}" stroke="{col}" stroke-width="2" marker-end="url(#arr{theme})"/>'
                f'<defs><marker id="arr{theme}" markerWidth="8" markerHeight="8" refX="7" refY="4" orient="auto">'
                f'<path d="M0,0 L8,4 L0,8 z" fill="{col}"/></marker></defs>')
    p.append(arrow(0, 0, 0, 0, th["dim"]))
    p.append(f'<text x="20" y="26" font-size="15" font-weight="800" fill="{th["fg"]}">8 upstreams</text>')
    lanes = ["vanilla", "turboquant", "prism", "atomic", "imp", "infernix", "basalt", "unsloth"]
    for i, name in enumerate(lanes):
        p.append(chip(20, 40 + i * 34, 130, name, th, size=13))
    p.append(chip(240, 90, 190, "builder lanes", th, stroke=th["accent2"], fg=th["accent2"], size=15, weight=800))
    p.append(f'<text x="240" y="150" font-size="13" font-weight="500" fill="{th["dim"]}">stable = last release tag</text>')
    p.append(f'<text x="240" y="170" font-size="13" font-weight="500" fill="{th["dim"]}">nightly = branch HEAD</text>')
    p.append(f'<text x="240" y="190" font-size="13" font-weight="500" fill="{th["warn"]}">dedup: nightly == stable: skip</text>')
    p.append(f'<text x="240" y="210" font-size="13" font-weight="500" fill="{th["warn"]}">moving-tag lanes: nightly_always</text>')
    p.append(arrow(160, 176, 236, 110, th["dim"]))
    p.append(arrow(160, 176, 236, 130, th["dim"]))
    p.append(chip(520, 100, 200, ":stable  +  :nightly", th, stroke=th["accent"], fg=th["accent"], size=15, weight=800))
    p.append(f'<text x="520" y="160" font-size="13" font-weight="500" fill="{th["dim"]}">immutable twin per build:</text>')
    p.append(f'<text x="520" y="180" font-size="13" font-weight="500" fill="{th["dim"]}">stable-20261126-4580237…</text>')
    p.append(f'<text x="520" y="200" font-size="13" font-weight="500" fill="{th["dim"]}">= the audit trail (release notes</text>')
    p.append(f'<text x="520" y="216" font-size="13" font-weight="500" fill="{th["dim"]}">list every engine tag inside)</text>')
    p.append(arrow(440, 120, 516, 116, th["dim"]))
    p.append(chip(300, 270, 240, "llama-swap slots", th, stroke=th["chipln"], size=15, weight=800))
    p.append(f'<text x="300" y="255" font-size="13" font-weight="500" fill="{th["dim"]}">mount your config.yaml, engines route per model</text>')
    p.append(arrow(690, 224, 545, 268, th["dim"]))
    return "\n".join(p) + "\n</svg>"

for theme in ("dark", "light"):
    (OUT / f"hero-{theme}.svg").write_text(hero(theme), encoding="utf-8")
    (OUT / f"pipeline-{theme}.svg").write_text(pipeline(theme), encoding="utf-8")
print("wrote:", sorted(p.name for p in OUT.glob("*.svg")))
