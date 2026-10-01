#!/usr/bin/env python3
"""Regenerate the animated README illustrations: python3 scripts/readme-assets.py assets"""
import os, sys

OUT = sys.argv[1] if len(sys.argv) > 1 else "assets"
os.makedirs(OUT, exist_ok=True)

FONT = "-apple-system,BlinkMacSystemFont,'Segoe UI','PingFang SC','Hiragino Sans GB','Microsoft YaHei','Noto Sans CJK SC',Helvetica,Arial,sans-serif"
MONO = "'SF Mono',Menlo,Consolas,'Liberation Mono',monospace"


def tw(text, fs):
    """Rough text width estimate."""
    w = 0.0
    for ch in text:
        if ord(ch) > 0x2E80:
            w += fs * 1.0
        elif ch in "il.,:;'|!·":
            w += fs * 0.3
        elif ch == " ":
            w += fs * 0.3
        elif ch.isupper() or ch in "mwMW≈":
            w += fs * 0.68
        else:
            w += fs * 0.55
    return w


def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


# --------------------------------------------------------------------------- hero
def hero(static=False):
    """static=True renders a 1280x640 social-preview card without animation."""
    W, H = (1280, 640) if static else (1280, 440)
    dy = 100 if static else 0
    chips = ["Native Swift + AppKit", "≈ 1 MB", "Zero dependencies", "Encrypted snapshots", "43 tests passing"]
    fs = 17
    pad = 18
    gap = 14
    widths = [tw(c, fs) + pad * 2 + 18 for c in chips]
    total = sum(widths) + gap * (len(chips) - 1)
    x = (W - total) / 2
    chip_svg = []
    for i, (c, w) in enumerate(zip(chips, widths)):
        chip_svg.append(f'''<g class="chip" style="animation-delay:{0.6 + i * 0.15:.2f}s">
  <rect x="{x:.1f}" y="352" width="{w:.1f}" height="38" rx="19" fill="#ffffff" fill-opacity=".07" stroke="#ffffff" stroke-opacity=".16"/>
  <circle cx="{x + pad + 4:.1f}" cy="371" r="4" fill="#34d399"/>
  <text x="{x + pad + 16:.1f}" y="377" font-size="{fs}" fill="#e5e7ff">{esc(c)}</text>
</g>''')
        x += w + gap

    lines = [
        ("Switch between your own Factory accounts in one click", "菜单栏一键切换你自己的多个 Factory 账号"),
        ("5-hour, weekly and monthly quota at a glance", "5 小时 / 周 / 月额度，一眼看清"),
        ("Back up first. Roll back automatically on failure.", "先备份再切换，失败自动回滚"),
    ]
    tag_svg = []
    for i, (en, zh) in enumerate(lines[:1] if static else lines):
        tag_svg.append(f'''<g class="tag" style="animation-delay:{i * 4}s">
  <text x="640" y="268" text-anchor="middle" font-size="27" font-weight="500" fill="#f5f3ff">{esc(en)}</text>
  <text x="640" y="306" text-anchor="middle" font-size="21" fill="#a5b4fc">{esc(zh)}</text>
</g>''')

    svg = f'''<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" role="img" aria-label="Factory Switcher — multi-account switcher for Factory Droid on macOS">
<title>Factory Switcher</title>
<defs>
  <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">
    <stop offset="0" stop-color="#0b1022"/><stop offset=".55" stop-color="#140f35"/><stop offset="1" stop-color="#1d1147"/>
  </linearGradient>
  <linearGradient id="title" x1="0" y1="0" x2="1" y2="0">
    <stop offset="0" stop-color="#ffffff"/><stop offset=".5" stop-color="#c4b5fd"/><stop offset="1" stop-color="#67e8f9"/>
  </linearGradient>
  <linearGradient id="icon" x1="0" y1="0" x2="1" y2="1">
    <stop offset="0" stop-color="#8b5cf6"/><stop offset="1" stop-color="#06b6d4"/>
  </linearGradient>
  <filter id="blur" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="60"/></filter>
  <pattern id="grid" width="40" height="40" patternUnits="userSpaceOnUse">
    <path d="M40 0H0V40" fill="none" stroke="#ffffff" stroke-opacity=".045"/>
  </pattern>
  <clipPath id="clip"><rect width="{W}" height="{H}" rx="{0 if static else 22}"/></clipPath>
</defs>
<style>
  text {{ font-family: {FONT}; }}
  .b1 {{ animation: drift1 14s ease-in-out infinite alternate; }}
  .b2 {{ animation: drift2 17s ease-in-out infinite alternate; }}
  .b3 {{ animation: drift3 11s ease-in-out infinite alternate; }}
  @keyframes drift1 {{ to {{ transform: translate(160px, 60px); }} }}
  @keyframes drift2 {{ to {{ transform: translate(-200px, -50px); }} }}
  @keyframes drift3 {{ to {{ transform: translate(-90px, 70px); }} }}
  .fade-up {{ animation: up .9s cubic-bezier(.2,.8,.2,1) both; }}
  .chip {{ animation: up .7s cubic-bezier(.2,.8,.2,1) both; }}
  @keyframes up {{ from {{ opacity: 0; transform: translateY(14px); }} to {{ opacity: 1; transform: none; }} }}
  .tag {{ opacity: 0; animation: tag 12s ease-in-out infinite; }}
  @keyframes tag {{
    0% {{ opacity: 0; transform: translateY(10px); }}
    4%, 29% {{ opacity: 1; transform: none; }}
    33%, 100% {{ opacity: 0; transform: translateY(-10px); }}
  }}
  .ring {{ transform-origin: 1066px 18px; animation: ring 2.4s ease-out infinite; }}
  @keyframes ring {{ from {{ opacity: .7; transform: scale(.6); }} to {{ opacity: 0; transform: scale(2.2); }} }}
  .pill {{ animation: glow 2.4s ease-in-out infinite; }}
  @keyframes glow {{ 0%,100% {{ fill-opacity: .25; }} 50% {{ fill-opacity: .55; }} }}
  .shine {{ animation: shine 6s ease-in-out infinite; }}
  @keyframes shine {{ 0%, 60% {{ transform: translateX(-700px); }} 100% {{ transform: translateX(900px); }} }}
</style>
<g clip-path="url(#clip)">
  <rect width="{W}" height="{H}" fill="url(#bg)"/>
  <rect width="{W}" height="{H}" fill="url(#grid)"/>
  <g filter="url(#blur)">
    <circle class="b1" cx="220" cy="140" r="170" fill="#7c3aed" fill-opacity=".55"/>
    <circle class="b2" cx="1080" cy="360" r="190" fill="#0891b2" fill-opacity=".45"/>
    <circle class="b3" cx="760" cy="10" r="130" fill="#db2777" fill-opacity=".28"/>
  </g>

  <!-- macOS-style menu bar -->
  <rect width="{W}" height="36" fill="#ffffff" fill-opacity=".06"/>
  <rect y="36" width="{W}" height="1" fill="#ffffff" fill-opacity=".08"/>
  <circle cx="26" cy="18" r="6" fill="#ff5f57"/><circle cx="46" cy="18" r="6" fill="#febc2e"/><circle cx="66" cy="18" r="6" fill="#28c840"/>
  <circle class="ring" cx="1066" cy="18" r="16" fill="none" stroke="#a78bfa" stroke-width="2"/>
  <rect class="pill" x="1038" y="6" width="56" height="24" rx="6" fill="#a78bfa"/>
  <text x="1066" y="24" text-anchor="middle" font-size="15" font-weight="700" fill="#ffffff">FS</text>
  <g fill="none" stroke="#e5e7eb" stroke-width="2" stroke-linecap="round" opacity=".85">
    <path d="M1112 16a12 12 0 0 1 16 0"/><path d="M1116 20a6 6 0 0 1 8 0"/>
  </g>
  <circle cx="1120" cy="24" r="1.6" fill="#e5e7eb"/>
  <rect x="1142" y="11" width="26" height="13" rx="3" fill="none" stroke="#e5e7eb" stroke-opacity=".85" stroke-width="1.5"/>
  <rect x="1145" y="14" width="17" height="7" rx="1.5" fill="#e5e7eb" fill-opacity=".85"/>
  <text x="1250" y="24" text-anchor="end" font-size="15" fill="#e5e7eb">9:41</text>

  <g transform="translate(0 {dy})">
  <!-- title block -->
  <g class="fade-up">
    <rect x="455" y="92" width="370" height="32" rx="16" fill="#ffffff" fill-opacity=".08" stroke="#ffffff" stroke-opacity=".18"/>
    <text x="640" y="114" text-anchor="middle" font-size="15" letter-spacing=".5" fill="#c7d2fe">macOS MENU-BAR APP · 菜单栏工具</text>
  </g>
  <g class="fade-up" style="animation-delay:.15s">
    <rect x="300" y="146" width="76" height="76" rx="18" fill="url(#icon)"/>
    <rect x="300" y="146" width="76" height="38" rx="18" fill="#ffffff" fill-opacity=".12"/>
    <text x="338" y="197" text-anchor="middle" font-size="32" font-weight="800" fill="#ffffff">FS</text>
    <text x="400" y="210" font-size="72" font-weight="800" letter-spacing="-1.5" fill="url(#title)">Factory Switcher</text>
  </g>
  {''.join(tag_svg)}
  {''.join(chip_svg)}
  </g>
  <rect class="shine" x="0" y="0" width="160" height="{H}" fill="#ffffff" fill-opacity=".035" transform="skewX(-20)"/>
</g>
</svg>
'''
    if static:
        start, end = svg.index("<style>"), svg.index("</style>") + len("</style>")
        svg = svg[:start] + "<style>text { font-family: " + FONT + "; }</style>" + svg[end:]
    return svg


# --------------------------------------------------------------------- menu demo
def menu_demo():
    W, H = 1280, 820
    T = 14  # seconds per loop
    # ---- left: steps
    steps = [
        ("1", "Pick an account", "在菜单里点选账号"),
        ("2", "Confirm the restart", "确认重启 Factory"),
        ("3", "Quit · back up · swap · relaunch", "退出 · 备份 · 替换 · 重开"),
        ("4", "Done — check email & org", "完成，核对邮箱与组织"),
    ]
    # active windows (percent) for each step
    windows = [(0, 27), (27, 44), (44, 74), (74, 100)]
    step_css = []
    step_svg = []
    for i, ((n, en, zh), (a, b)) in enumerate(zip(steps, windows)):
        y = 214 + i * 118
        cls = f"s{i}"
        # keyframes: off before a, on [a+1, b-1], off after
        a1, b1 = (a + 1.5 if a > 0 else 0), (b - 1.5 if b < 100 else 100)
        if a == 0:
            kf = f"0%, {b1}% {{ opacity: 1; }} {b}%, 100% {{ opacity: 0; }}"
        elif b == 100:
            kf = f"0%, {a}% {{ opacity: 0; }} {a1}%, 97% {{ opacity: 1; }} 100% {{ opacity: 0; }}"
        else:
            kf = f"0%, {a}% {{ opacity: 0; }} {a1}%, {b1}% {{ opacity: 1; }} {b}%, 100% {{ opacity: 0; }}"
        step_css.append(f".{cls} {{ animation: k{cls} {T}s linear infinite; }} @keyframes k{cls} {{ {kf} }}")
        step_svg.append(f'''<g>
  <rect x="56" y="{y}" width="500" height="98" rx="16" fill="#ffffff" fill-opacity=".035" stroke="#ffffff" stroke-opacity=".08"/>
  <g class="{cls}">
    <rect x="56" y="{y}" width="500" height="98" rx="16" fill="#8b5cf6" fill-opacity=".16" stroke="#a78bfa" stroke-opacity=".9" stroke-width="1.5"/>
    <rect x="56" y="{y + 18}" width="4" height="62" rx="2" fill="#a78bfa"/>
  </g>
  <circle cx="106" cy="{y + 49}" r="22" fill="#1e1b4b" stroke="#a78bfa" stroke-opacity=".6"/>
  <text x="106" y="{y + 57}" text-anchor="middle" font-size="21" font-weight="700" fill="#e9d5ff">{n}</text>
  <text x="146" y="{y + 44}" font-size="23" font-weight="650" fill="#ffffff">{esc(en)}</text>
  <text x="146" y="{y + 75}" font-size="19" fill="#a5b4fc">{esc(zh)}</text>
</g>''')

    # ---- right: scene with menu bar + NSMenu replica (dark mode)
    SX, SY, SW, SH = 600, 40, 640, 740
    mx, my, mw = SX + 120, SY + 44, 480
    rows = []  # (kind, text, h, extra)
    R, r = 32, 24
    rows.append(("title", "Factory 切号器", R))
    rows.append(("sep", "", 11))
    rows.append(("acct", "工作账号", R, "A"))
    rows.append(("info", "me@work.example", r))
    rows.append(("info", "5小时：剩余 63% · 周：剩余 80% · 月：剩余 91%", r))
    rows.append(("info", "查询于 21:40", r))
    rows.append(("acct", "个人账号", R, "B"))
    rows.append(("info", "me@personal.example", r))
    rows.append(("info", "5小时：剩余 100% · 周：剩余 74% · 月：剩余 88%", r))
    rows.append(("info", "查询于 21:40", r))
    rows.append(("sep", "", 11))
    for t in ["保存 / 同步当前账号", "添加账号（官方登录）…", "刷新所有账号额度"]:
        rows.append(("act", t, R))
    rows.append(("sep", "", 11))
    rows.append(("act", "共享所选会话（先备份）", R))
    rows.append(("act", "选择要共享的会话…（0）", R))
    for t in ["设置", "管理账号", "备份与恢复"]:
        rows.append(("sub", t, R))
    rows.append(("sep", "", 11))
    for t in ["打开 Factory", "使用说明…", "退出切号器"]:
        rows.append(("act", t, R))

    y = my + 8
    menu_items = []
    acct_rows = {}
    for row in rows:
        kind, text, h = row[0], row[1], row[2]
        base = y + h / 2 + 6
        if kind == "sep":
            menu_items.append(f'<rect x="{mx + 10}" y="{y + 5}" width="{mw - 20}" height="1" fill="#ffffff" fill-opacity=".13"/>')
        elif kind == "title":
            menu_items.append(f'<text x="{mx + 26}" y="{base}" font-size="17" font-weight="700" fill="#f4f4f5">{esc(text)}</text>')
        elif kind == "acct":
            acct_rows[row[3]] = y
            menu_items.append(f'<text x="{mx + 26}" y="{base}" font-size="17" fill="#f4f4f5">{esc(text)}</text>')
        elif kind == "info":
            menu_items.append(f'<text x="{mx + 42}" y="{base - 1}" font-size="14.5" fill="#a1a1aa">{esc(text)}</text>')
        elif kind == "act":
            menu_items.append(f'<text x="{mx + 26}" y="{base}" font-size="17" fill="#f4f4f5">{esc(text)}</text>')
        elif kind == "sub":
            menu_items.append(f'<text x="{mx + 26}" y="{base}" font-size="17" fill="#f4f4f5">{esc(text)}</text>')
            menu_items.append(f'<path d="M{mx + mw - 26} {y + h / 2 - 5}l5 5-5 5" fill="none" stroke="#d4d4d8" stroke-width="1.8" stroke-linecap="round"/>')
        y += h
    mh = y + 8 - my
    ay, by = acct_rows["A"], acct_rows["B"]

    # cursor keyframes (translate of the arrow tip)
    hover_x, hover_y = mx + 150, by + 18
    dlg_w, dlg_h = 470, 290
    dx, dy = SX + (SW - dlg_w) / 2, SY + 210
    btn_x, btn_y = dx + dlg_w - 24 - 110, dy + dlg_h - 24 - 40
    cur = [
        (0, SX + 560, SY + 700), (5, SX + 560, SY + 700), (19, hover_x, hover_y),
        (25, hover_x, hover_y), (34, hover_x, hover_y), (40, btn_x + 60, btn_y + 22),
        (44, btn_x + 60, btn_y + 22), (56, SX + 560, SY + 700), (100, SX + 560, SY + 700),
    ]
    cur_kf = " ".join(f"{p}% {{ transform: translate({x:.0f}px, {yv:.0f}px); }}" for p, x, yv in cur)

    progress = [
        ("正常退出 Factory", "Graceful quit"),
        ("保存最新登录并备份", "Sync & back up"),
        ("替换加密登录", "Swap encrypted login"),
        ("重新打开 Factory", "Relaunch"),
    ]
    px, py, pw = SX + (SW - 440) / 2, SY + 200, 440
    prog_svg, prog_css = [], []
    for i, (zh, en) in enumerate(progress):
        t0 = 47 + i * 6  # tick time
        yy = py + 92 + i * 56
        prog_css.append(
            f".pk{i} {{ animation: pk{i} {T}s linear infinite; }} @keyframes pk{i} {{ 0%, {t0}% {{ opacity: 0; transform: scale(.4); }} {t0 + 1.5}%, 100% {{ opacity: 1; transform: none; }} }}"
            f".ps{i} {{ animation: ps{i} {T}s linear infinite; }} @keyframes ps{i} {{ 0%, {t0 - 6 if i else 44}% {{ opacity: .25; }} {t0 - 5.5 if i else 45}%, {t0}% {{ opacity: 1; }} {t0 + .5}%, 100% {{ opacity: 0; }} }}"
        )
        cx, cy = px + 40, yy - 6
        prog_svg.append(f'''<g>
  <circle cx="{cx}" cy="{cy}" r="13" fill="none" stroke="#ffffff" stroke-opacity=".18" stroke-width="2.5"/>
  <g class="ps{i}"><g class="spin" style="transform-origin:{cx}px {cy}px"><path d="M{cx} {cy - 13}a13 13 0 0 1 13 13" fill="none" stroke="#a78bfa" stroke-width="2.5" stroke-linecap="round"/></g></g>
  <g class="pk{i}" style="transform-origin:{cx}px {cy}px"><circle cx="{cx}" cy="{cy}" r="13" fill="#10b981"/><path d="M{cx - 6} {cy}l4 4.5 8-9" fill="none" stroke="#fff" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round"/></g>
  <text x="{px + 68}" y="{yy}" font-size="18" fill="#f4f4f5">{esc(zh)}</text>
  <text x="{px + pw - 24}" y="{yy}" text-anchor="end" font-size="15" fill="#a1a1aa">{esc(en)}</text>
</g>''')

    css = f'''
  text {{ font-family: {FONT}; }}
  {' '.join(step_css)}
  {' '.join(prog_css)}
  .menu {{ animation: menu {T}s linear infinite; }}
  @keyframes menu {{ 0% {{ opacity: 0; }} 2%, 27% {{ opacity: 1; }} 30%, 74% {{ opacity: 0; }} 77%, 96% {{ opacity: 1; }} 100% {{ opacity: 0; }} }}
  .chkA {{ animation: chkA {T}s linear infinite; }}
  @keyframes chkA {{ 0%, 50% {{ opacity: 1; }} 51%, 100% {{ opacity: 0; }} }}
  .chkB {{ animation: chkB {T}s linear infinite; }}
  @keyframes chkB {{ 0%, 50% {{ opacity: 0; }} 51%, 100% {{ opacity: 1; }} }}
  .hover {{ animation: hover {T}s linear infinite; }}
  @keyframes hover {{ 0%, 18% {{ opacity: 0; }} 19%, 28% {{ opacity: 1; }} 29%, 100% {{ opacity: 0; }} }}
  .flash {{ animation: flash {T}s linear infinite; }}
  @keyframes flash {{ 0%, 78% {{ opacity: 0; }} 80% {{ opacity: .9; }} 90%, 100% {{ opacity: 0; }} }}
  .dlg {{ animation: dlg {T}s cubic-bezier(.2,.8,.2,1) infinite; transform-origin: {dx + dlg_w / 2}px {dy + dlg_h / 2}px; }}
  @keyframes dlg {{ 0%, 29% {{ opacity: 0; transform: scale(.94); }} 32%, 41.5% {{ opacity: 1; transform: none; }} 43.5%, 100% {{ opacity: 0; transform: scale(.97); }} }}
  .btn {{ animation: btn {T}s linear infinite; }}
  @keyframes btn {{ 0%, 40.5% {{ fill: #0a84ff; }} 41%, 42% {{ fill: #0060d0; }} 42.5%, 100% {{ fill: #0a84ff; }} }}
  .prog {{ animation: prog {T}s cubic-bezier(.2,.8,.2,1) infinite; }}
  @keyframes prog {{ 0%, 43.5% {{ opacity: 0; transform: translateY(12px); }} 46%, 73% {{ opacity: 1; transform: none; }} 75.5%, 100% {{ opacity: 0; transform: translateY(-8px); }} }}
  .spin {{ animation: spin .9s linear infinite; }}
  @keyframes spin {{ to {{ transform: rotate(360deg); }} }}
  .fs {{ animation: fs {T}s linear infinite; }}
  @keyframes fs {{ 0%, 43.5% {{ opacity: 1; }} 44%, 74% {{ opacity: 0; }} 74.5%, 100% {{ opacity: 1; }} }}
  .fsb {{ animation: fsb {T}s linear infinite; }}
  @keyframes fsb {{ 0%, 43.5% {{ opacity: 0; }} 44%, 74% {{ opacity: 1; }} 74.5%, 100% {{ opacity: 0; }} }}
  .fsbg {{ animation: fsbg {T}s linear infinite; }}
  @keyframes fsbg {{ 0%, 2% {{ fill-opacity: .18; }} 3%, 27% {{ fill-opacity: .32; }} 29%, 76% {{ fill-opacity: .18; }} 77%, 96% {{ fill-opacity: .32; }} 99%, 100% {{ fill-opacity: .18; }} }}
  .cursor {{ animation: cur {T}s cubic-bezier(.45,.05,.35,1) infinite; }}
  @keyframes cur {{ {cur_kf} }}
  .click {{ animation: click {T}s linear infinite; }}
  @keyframes click {{ 0%, 26% {{ opacity: 0; transform: scale(.3); }} 26.5% {{ opacity: .9; transform: scale(.3); }} 29% {{ opacity: 0; transform: scale(1.4); }} 40.5% {{ opacity: 0; transform: scale(.3); }} 41% {{ opacity: .9; transform: scale(.3); }} 43.5% {{ opacity: 0; transform: scale(1.4); }} 100% {{ opacity: 0; }} }}
'''
    fs_x = mx + 4

    svg = f'''<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" role="img" aria-label="Animated demo: switching Factory accounts from the menu bar">
<title>Switching accounts from the menu bar</title>
<defs>
  <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">
    <stop offset="0" stop-color="#0b1022"/><stop offset="1" stop-color="#160f3a"/>
  </linearGradient>
  <linearGradient id="wall" x1="0" y1="0" x2="1" y2="1">
    <stop offset="0" stop-color="#312e81"/><stop offset=".55" stop-color="#4c1d95"/><stop offset="1" stop-color="#0e7490"/>
  </linearGradient>
  <filter id="shadow" x="-20%" y="-20%" width="140%" height="140%"><feDropShadow dx="0" dy="14" stdDeviation="18" flood-color="#000" flood-opacity=".55"/></filter>
  <clipPath id="clip"><rect width="{W}" height="{H}" rx="22"/></clipPath>
  <clipPath id="scene"><rect x="{SX}" y="{SY}" width="{SW}" height="{SH}" rx="16"/></clipPath>
</defs>
<style>{css}</style>
<g clip-path="url(#clip)">
  <rect width="{W}" height="{H}" fill="url(#bg)"/>

  <text x="56" y="104" font-size="34" font-weight="800" fill="#ffffff">Switch in four steps</text>
  <text x="56" y="146" font-size="24" font-weight="600" fill="#a5b4fc">四步完成切换</text>
  <text x="56" y="182" font-size="16" fill="#94a3b8">Never automatic — every switch is your click. · 从不自动切换</text>
  {''.join(step_svg)}
  <g>
    <rect x="56" y="690" width="500" height="64" rx="14" fill="#10b981" fill-opacity=".1" stroke="#34d399" stroke-opacity=".45"/>
    <path d="M86 708l14 6v10c0 8-6 13-14 16-8-3-14-8-14-16v-10z" fill="none" stroke="#34d399" stroke-width="2.2" stroke-linejoin="round"/>
    <text x="120" y="717" font-size="17" font-weight="600" fill="#d1fae5">Any step fails → original login restored</text>
    <text x="120" y="742" font-size="15" fill="#6ee7b7">任何一步失败，自动恢复原登录</text>
  </g>

  <!-- scene -->
  <g clip-path="url(#scene)">
    <rect x="{SX}" y="{SY}" width="{SW}" height="{SH}" fill="url(#wall)"/>
    <rect x="{SX}" y="{SY}" width="{SW}" height="{SH}" fill="#000" fill-opacity=".25"/>
    <rect x="{SX}" y="{SY}" width="{SW}" height="34" fill="#18181b" fill-opacity=".72"/>
    <rect class="fsbg" x="{fs_x}" y="{SY + 5}" width="58" height="24" rx="6" fill="#ffffff" fill-opacity=".18"/>
    <text class="fs" x="{fs_x + 29}" y="{SY + 23}" text-anchor="middle" font-size="15" font-weight="600" fill="#ffffff">FS</text>
    <text class="fsb" x="{fs_x + 29}" y="{SY + 23}" text-anchor="middle" font-size="15" font-weight="600" fill="#ffffff">FS…</text>
    <text x="{SX + SW - 20}" y="{SY + 23}" text-anchor="end" font-size="15" fill="#e4e4e7">9:41</text>
    <rect x="{SX + SW - 92}" y="{SY + 11}" width="24" height="12" rx="3" fill="none" stroke="#e4e4e7" stroke-width="1.4"/>
    <rect x="{SX + SW - 89}" y="{SY + 14}" width="15" height="6" rx="1" fill="#e4e4e7"/>

    <g class="menu">
      <rect x="{mx}" y="{my}" width="{mw}" height="{mh}" rx="10" fill="#26262b" fill-opacity=".97" stroke="#ffffff" stroke-opacity=".14" filter="url(#shadow)"/>
      <rect class="hover" x="{mx + 6}" y="{by}" width="{mw - 12}" height="32" rx="6" fill="#0a84ff"/>
      <rect class="flash" x="{mx + 6}" y="{by}" width="{mw - 12}" height="32" rx="6" fill="#34d399" fill-opacity=".35"/>
      {''.join(menu_items)}
      <path class="chkA" d="M{mx + 9} {ay + 16}l4 4.5 7-9" fill="none" stroke="#f4f4f5" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
      <path class="chkB" d="M{mx + 9} {by + 16}l4 4.5 7-9" fill="none" stroke="#f4f4f5" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
    </g>

    <g class="dlg">
      <rect x="{dx}" y="{dy}" width="{dlg_w}" height="{dlg_h}" rx="14" fill="#2c2c31" stroke="#ffffff" stroke-opacity=".14" filter="url(#shadow)"/>
      <rect x="{dx + 24}" y="{dy + 24}" width="48" height="48" rx="11" fill="#8b5cf6"/>
      <text x="{dx + 48}" y="{dy + 55}" text-anchor="middle" font-size="18" font-weight="800" fill="#fff">FS</text>
      <text x="{dx + 88}" y="{dy + 55}" font-size="19" font-weight="700" fill="#f4f4f5">切换账号并重启 Factory？</text>
      <text x="{dx + 24}" y="{dy + 104}" font-size="15" fill="#f4f4f5">目标：个人账号</text>
      <text x="{dx + 24}" y="{dy + 136}" font-size="14.5" fill="#a1a1aa">工具会正常退出并重新打开 Factory。正在运行的任务</text>
      <text x="{dx + 24}" y="{dy + 160}" font-size="14.5" fill="#a1a1aa">会中断，请先保存工作。当前登录会保存；切换失败时</text>
      <text x="{dx + 24}" y="{dy + 184}" font-size="14.5" fill="#a1a1aa">会回滚。终端中的 Droid 需要先关闭。</text>
      <rect x="{btn_x - 122}" y="{btn_y}" width="110" height="40" rx="8" fill="#ffffff" fill-opacity=".12"/>
      <text x="{btn_x - 67}" y="{btn_y + 26}" text-anchor="middle" font-size="16" fill="#f4f4f5">取消</text>
      <rect class="btn" x="{btn_x}" y="{btn_y}" width="110" height="40" rx="8" fill="#0a84ff"/>
      <text x="{btn_x + 55}" y="{btn_y + 26}" text-anchor="middle" font-size="16" font-weight="600" fill="#ffffff">切换</text>
    </g>

    <g class="prog">
      <rect x="{px}" y="{py}" width="{pw}" height="{56 * 4 + 70}" rx="16" fill="#18181b" fill-opacity=".92" stroke="#a78bfa" stroke-opacity=".45" filter="url(#shadow)"/>
      <text x="{px + 24}" y="{py + 40}" font-size="15" font-weight="700" letter-spacing="1" fill="#c4b5fd">UNDER THE HOOD · 幕后发生的事</text>
      {''.join(prog_svg)}
    </g>

    <g class="cursor">
      <g class="click"><circle cx="0" cy="0" r="16" fill="none" stroke="#ffffff" stroke-width="2.5"/></g>
      <path d="M0 0v22l5.5-5.2 3.6 8.4 3.9-1.7-3.6-8.2h7.6z" fill="#111" stroke="#fff" stroke-width="1.6" stroke-linejoin="round"/>
    </g>
  </g>
  <rect x="{SX}" y="{SY}" width="{SW}" height="{SH}" rx="16" fill="none" stroke="#ffffff" stroke-opacity=".14"/>
  <text x="{SX + SW}" y="{SY + SH + 26}" text-anchor="end" font-size="13" fill="#64748b">Illustration based on the real menu (UI: Simplified Chinese) · 界面示意</text>
</g>
</svg>
'''
    return svg


# -------------------------------------------------------------------------- flow
def flow():
    W, H = 1280, 360
    T = 8
    nodes = [
        ("Confirm", "确认", "M0 0"),
        ("Quit gracefully", "正常退出 Factory", ""),
        ("Back up & verify", "备份并校验", ""),
        ("Swap login", "替换加密登录", ""),
        ("Relaunch", "重新打开", ""),
    ]
    n = len(nodes)
    x0, x1 = 120, 1160
    step = (x1 - x0) / (n - 1)
    cy = 150
    node_svg, css = [], []
    for i, (en, zh, _) in enumerate(nodes):
        cx = x0 + i * step
        t = 6 + i * 16
        css.append(f".n{i} {{ animation: n{i} {T}s ease-out infinite; transform-origin: {cx}px {cy}px; }} "
                   f"@keyframes n{i} {{ 0%, {t}% {{ opacity: 0; transform: scale(.6); }} {t + 4}% {{ opacity: 1; transform: scale(1.12); }} {t + 8}%, 92% {{ opacity: 1; transform: none; }} 100% {{ opacity: 0; }} }}")
        icon = [
            f'<path d="M{cx - 10} {cy}l6 7 14-15" fill="none" stroke="#fff" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"/>',
            f'<path d="M{cx} {cy - 13}v10M{cx - 9} {cy - 8}a12 12 0 1 0 18 0" fill="none" stroke="#fff" stroke-width="3" stroke-linecap="round"/>',
            f'<path d="M{cx} {cy - 14}l11 5v7c0 7-5 11-11 14-6-3-11-7-11-14v-7z" fill="none" stroke="#fff" stroke-width="2.6" stroke-linejoin="round"/>',
            f'<path d="M{cx - 12} {cy - 5}h20l-5-5M{cx + 12} {cy + 5}h-20l5 5" fill="none" stroke="#fff" stroke-width="2.8" stroke-linecap="round" stroke-linejoin="round"/>',
            f'<path d="M{cx + 10} {cy - 4}a11 11 0 1 1-4-8M{cx + 11} {cy - 15}v7h-7" fill="none" stroke="#fff" stroke-width="2.8" stroke-linecap="round" stroke-linejoin="round"/>',
        ][i]
        node_svg.append(f'''<g>
  <circle cx="{cx}" cy="{cy}" r="34" fill="#1e1b4b" stroke="#ffffff" stroke-opacity=".15" stroke-width="2"/>
  <g class="n{i}"><circle cx="{cx}" cy="{cy}" r="34" fill="url(#node)"/><circle cx="{cx}" cy="{cy}" r="44" fill="none" stroke="#a78bfa" stroke-opacity=".35" stroke-width="2"/></g>
  {icon}
  <text x="{cx}" y="{cy + 76}" text-anchor="middle" font-size="20" font-weight="650" fill="#ffffff">{esc(en)}</text>
  <text x="{cx}" y="{cy + 104}" text-anchor="middle" font-size="17" fill="#a5b4fc">{esc(zh)}</text>
</g>''')

    svg = f'''<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" role="img" aria-label="Switch pipeline: confirm, quit gracefully, back up and verify, swap login, relaunch; automatic rollback on failure">
<title>Safe switch pipeline</title>
<defs>
  <linearGradient id="bg" x1="0" y1="0" x2="1" y2="0"><stop offset="0" stop-color="#0b1022"/><stop offset="1" stop-color="#160f3a"/></linearGradient>
  <linearGradient id="node" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#8b5cf6"/><stop offset="1" stop-color="#06b6d4"/></linearGradient>
  <linearGradient id="line" gradientUnits="userSpaceOnUse" x1="120" y1="0" x2="1160" y2="0"><stop offset="0" stop-color="#8b5cf6"/><stop offset="1" stop-color="#22d3ee"/></linearGradient>
  <clipPath id="clip"><rect width="{W}" height="{H}" rx="22"/></clipPath>
</defs>
<style>
  text {{ font-family: {FONT}; }}
  {' '.join(css)}
  .track {{ stroke-dasharray: 1040; animation: track {T}s ease-in-out infinite; }}
  @keyframes track {{ 0%, 6% {{ stroke-dashoffset: 1040; }} 74% {{ stroke-dashoffset: 0; }} 92% {{ stroke-dashoffset: 0; opacity: 1; }} 100% {{ stroke-dashoffset: 0; opacity: 0; }} }}
</style>
<g clip-path="url(#clip)">
  <rect width="{W}" height="{H}" fill="url(#bg)"/>
  <text x="40" y="48" font-size="15" font-weight="700" letter-spacing="1.5" fill="#c4b5fd">WHAT HAPPENS WHEN YOU CLICK AN ACCOUNT · 点击账号后发生什么</text>
  <line x1="{x0}" y1="{cy}" x2="{x1}" y2="{cy}" stroke="#ffffff" stroke-opacity=".1" stroke-width="4" stroke-linecap="round"/>
  <line class="track" x1="{x0}" y1="{cy}" x2="{x1}" y2="{cy}" stroke="url(#line)" stroke-width="4" stroke-linecap="round"/>
  {''.join(node_svg)}
  <g>
    <rect x="{W / 2 - 420}" y="{H - 52}" width="840" height="36" rx="18" fill="#fb7185" fill-opacity=".1" stroke="#fb7185" stroke-opacity=".4"/>
    <text x="{W / 2}" y="{H - 28}" text-anchor="middle" font-size="16" fill="#fecdd3">✕ Any step fails → roll back &amp; reopen the original · 任一步失败 → 回滚并重新打开原账号</text>
  </g>
</g>
</svg>
'''
    return svg



# -------------------------------------------------------------------------- arch
def arch():
    W, H = 1280, 455

    def box(x, y, w, h, title, sub, zh, accent="#a78bfa", fill=".05"):
        return f'''<g>
  <rect x="{x}" y="{y}" width="{w}" height="{h}" rx="14" fill="#ffffff" fill-opacity="{fill}" stroke="{accent}" stroke-opacity=".55" stroke-width="1.5"/>
  <text x="{x + 20}" y="{y + 32}" font-size="19" font-weight="700" fill="#ffffff">{esc(title)}</text>
  <text x="{x + 20}" y="{y + 56}" font-size="14.5" fill="#cbd5e1">{esc(sub)}</text>
  <text x="{x + 20}" y="{y + 78}" font-size="13.5" fill="#a5b4fc">{esc(zh)}</text>
</g>'''

    def arrow(d, cls="flow"):
        return f'<path class="{cls}" d="{d}" fill="none" stroke="url(#ln)" stroke-width="2.4" stroke-linecap="round" marker-end="url(#ah)"/>'

    parts = []
    # app layer
    parts.append(box(40, 170, 250, 100, "FactorySwitcher", "AppKit menu · login terminal", "菜单 · 登录终端 · 退出/重开"))
    # core container
    parts.append(f'''<rect x="350" y="60" width="625" height="370" rx="20" fill="#8b5cf6" fill-opacity=".06" stroke="#a78bfa" stroke-opacity=".35" stroke-dasharray="6 6"/>
<text x="374" y="94" font-size="15" font-weight="700" letter-spacing="1.5" fill="#c4b5fd">SWITCHERCORE</text>''')
    parts.append(box(380, 170, 230, 100, "SwitcherEngine", "transaction + journal", "事务 + 恢复日志", accent="#22d3ee", fill=".08"))
    mods = [
        ("AccountStore", "encrypted snapshots", "加密快照", 100),
        ("Backups", "verify · restore", "校验 · 恢复", 186),
        ("QuotaClient", "limits · refresh", "额度 · 续期", 272),
        ("Sessions", "selected org markers", "所选会话组织标记", 358),
    ]
    for t, sub, zh, y in mods:
        parts.append(f'''<g>
  <rect x="680" y="{y - 6}" width="275" height="64" rx="12" fill="#ffffff" fill-opacity=".05" stroke="#ffffff" stroke-opacity=".18"/>
  <text x="698" y="{y + 20}" font-size="17" font-weight="650" fill="#ffffff">{esc(t)}</text>
  <text x="698" y="{y + 44}" font-size="13.5" fill="#a5b4fc">{esc(sub)} · {esc(zh)}</text>
</g>''')
        parts.append(arrow(f"M610 220 C 645 220, 640 {y + 26}, 672 {y + 26}"))
    parts.append(arrow("M290 220 H 372"))
    # keychain cylinder
    kx, ky = 1050, 96
    parts.append(f'''<g>
  <path d="M{kx} {ky + 12} v58 a90 14 0 0 0 180 0 v-58" fill="#10b981" fill-opacity=".1" stroke="#34d399" stroke-opacity=".7" stroke-width="1.5"/>
  <ellipse cx="{kx + 90}" cy="{ky + 12}" rx="90" ry="14" fill="#10b981" fill-opacity=".18" stroke="#34d399" stroke-opacity=".7" stroke-width="1.5"/>
  <text x="{kx + 90}" y="{ky + 54}" text-anchor="middle" font-size="17" font-weight="650" fill="#d1fae5">macOS Keychain</text>
  <text x="{kx + 90}" y="{ky + 76}" text-anchor="middle" font-size="13.5" fill="#6ee7b7">钥匙串 · keys only</text>
</g>''')
    parts.append(arrow(f"M955 126 H {kx - 8}"))
    # API pill
    parts.append(f'''<g>
  <rect x="{kx}" y="270" width="180" height="62" rx="31" fill="#06b6d4" fill-opacity=".1" stroke="#22d3ee" stroke-opacity=".7" stroke-width="1.5"/>
  <text x="{kx + 90}" y="297" text-anchor="middle" font-size="16" font-weight="650" fill="#cffafe">Official Factory API</text>
  <text x="{kx + 90}" y="318" text-anchor="middle" font-size="13.5" fill="#67e8f9">官方额度 / 续期接口</text>
</g>''')
    parts.append(arrow(f"M955 298 H {kx - 8}"))
    parts.append(f'''<text x="{kx + 90}" y="380" text-anchor="middle" font-size="13" fill="#94a3b8">No telemetry · 无遥测</text>''')

    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" role="img" aria-label="Architecture: the AppKit app drives SwitcherCore (engine, account store, backups, quota client, sessions), which uses the macOS Keychain and the official Factory API">
<title>Architecture</title>
<defs>
  <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#0b1022"/><stop offset="1" stop-color="#160f3a"/></linearGradient>
  <linearGradient id="ln" gradientUnits="userSpaceOnUse" x1="280" y1="0" x2="1040" y2="0"><stop offset="0" stop-color="#a78bfa"/><stop offset="1" stop-color="#22d3ee"/></linearGradient>
  <marker id="ah" viewBox="0 0 10 10" refX="7" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M0 0L10 5L0 10z" fill="#22d3ee"/></marker>
  <clipPath id="clip"><rect width="{W}" height="{H}" rx="22"/></clipPath>
</defs>
<style>
  text {{ font-family: {FONT}; }}
  .flow {{ stroke-dasharray: 7 7; animation: flow 1.1s linear infinite; }}
  @keyframes flow {{ to {{ stroke-dashoffset: -28; }} }}
</style>
<g clip-path="url(#clip)">
  <rect width="{W}" height="{H}" fill="url(#bg)"/>
  <text x="40" y="48" font-size="15" font-weight="700" letter-spacing="1.5" fill="#c4b5fd">ARCHITECTURE · 架构</text>
  {"".join(parts)}
</g>
</svg>
'''

for name, fn in [("hero.svg", hero), ("demo.svg", menu_demo), ("flow.svg", flow), ("arch.svg", arch)]:
    with open(os.path.join(OUT, name), "w", encoding="utf-8") as f:
        f.write(fn())
    print("wrote", os.path.join(OUT, name))

# Social-preview card (upload as PNG in repo Settings). Render it, e.g. with:
#   chrome --headless=new --window-size=1280,640 --screenshot=assets/social-preview.png social-preview.svg
with open(os.path.join(OUT, "social-preview.svg"), "w", encoding="utf-8") as f:
    f.write(hero(static=True))
