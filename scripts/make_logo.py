#!/usr/bin/env python3
# OPRivView's icon as a vector, redrawn from Gerry's Midjourney pick (2026-11-05): a road to the
# horizon seen through a gauge ring, green arc and green centre line. 1024 viewBox.
# Run it, then scripts/generate_icons.py, to remake every app icon (needs Playwright's Chromium)
import math
CX, CY = 512, 440          # ring centre
VP = (512, 492)            # vanishing point
DISC = 300                 # the view inside the ring
GREEN_R, GREEN_W = 322, 20
GREY_R, GREY_W = 352, 40
BOTTOM = 840               # where the road leaves the icon

def pt(r, deg):  # screen angles: 0 = right, 90 = down
    a = math.radians(deg)
    return CX + r * math.cos(a), CY + r * math.sin(a)

def arc(r, a0, a1):  # clockwise from a0 to a1 the long way over the top
    x0, y0 = pt(r, a0); x1, y1 = pt(r, a1)
    return f'M{x0:.1f},{y0:.1f} A{r},{r} 0 1 1 {x1:.1f},{y1:.1f}'

def lerp(a, b, t): return a + (b - a) * t
def edge(xb, y):  # x on the line from the vanishing point to (xb, BOTTOM) at height y
    t = (y - VP[1]) / (BOTTOM - VP[1]); return lerp(VP[0], xb, t)

ROAD_L, ROAD_R = 250, 774          # the road's edges where it leaves the icon
SHOULDER_L, SHOULDER_R = -120, 1144

def dashes():
    out = []
    # growing towards the viewer
    spec = [(500, 3, 2.5), (512, 5, 3), (528, 8, 4), (552, 12, 5), (588, 18, 6.5), (640, 26, 8.5), (712, 36, 11), (800, 46, 14)]
    for y, h, w in spec:
        out.append(f'<rect x="{512 - w / 2:.1f}" y="{y}" width="{w}" height="{h}" rx="{w / 4:.1f}" fill="#8BE04E"/>')
    return '\n'.join(out)

def svg(background=True, wordmark=False, size=1024, shift=None, radius=230):
    SHIFT = (0 if wordmark else 52) if shift is None else shift
    yb = BOTTOM
    road = f'M{VP[0] - 1},{VP[1]} L{VP[0] + 1},{VP[1]} L{ROAD_R},{yb} L{ROAD_L},{yb} Z'
    shoulders = (f'<path d="M{VP[0]},{VP[1]} L{ROAD_L - 6},{yb} L{SHOULDER_L},{yb} Z" fill="url(#shoulder)"/>'
                 f'<path d="M{VP[0]},{VP[1]} L{ROAD_R + 6},{yb} L{SHOULDER_R},{yb} Z" fill="url(#shoulder)"/>')
    lines = ''.join(f'<path d="M{VP[0]},{VP[1]} L{x - 9},{yb} L{x + 9},{yb} Z" fill="#E8E8E8"/>' for x in (ROAD_L, ROAD_R))
    faint = ''.join(f'<path d="M{VP[0]},{VP[1]} L{x - 5},{yb} L{x + 5},{yb} Z" fill="#6E6F72"/>' for x in (60, 964))
    # soft ridges either side, dipping to the horizon where the road goes
    mountains = ('M180,474 C230,462 262,440 300,436 C334,432 352,446 384,440 C418,434 440,458 470,472 '
                 'C490,481 500,484 512,484 C530,484 552,474 590,462 C630,450 664,444 700,436 '
                 'C730,430 760,440 790,434 C812,430 830,440 844,446 L844,520 L180,520 Z')
    bg = (f'<rect width="1024" height="1024" rx="{radius}" fill="url(#bg)"/>'
          f'<rect width="1024" height="1024" rx="{radius}" fill="url(#glow)"/>') if background else ''
    word = ('<text x="512" y="935" text-anchor="middle" font-family="Roboto, Arial" font-weight="800" '
            'font-size="88" letter-spacing="4" fill="#F2F2F2">OPRIVVIEW</text>') if wordmark else ''
    # the ring opens at the bottom where the road comes through
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="{size}" height="{size}" viewBox="0 0 1024 1024">
<defs>
  <radialGradient id="glow" cx="512" cy="300" r="420" gradientUnits="userSpaceOnUse">
    <stop offset="0" stop-color="#3ADB6D" stop-opacity=".16"/><stop offset="1" stop-color="#3ADB6D" stop-opacity="0"/></radialGradient>
  <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#141615"/><stop offset="1" stop-color="#0B0C0C"/></linearGradient>
  <linearGradient id="sky" x1="0" y1="{CY - DISC}" x2="0" y2="{VP[1]}" gradientUnits="userSpaceOnUse">
    <stop offset="0" stop-color="#1A1D1B"/><stop offset=".55" stop-color="#3E5A44"/><stop offset="1" stop-color="#86BE8E"/></linearGradient>
  <linearGradient id="ground" x1="0" y1="{VP[1]}" x2="0" y2="{BOTTOM}" gradientUnits="userSpaceOnUse">
    <stop offset="0" stop-color="#050505"/><stop offset="1" stop-color="#1A1B1C"/></linearGradient>
  <linearGradient id="asphalt" x1="0" y1="{VP[1]}" x2="0" y2="{BOTTOM}" gradientUnits="userSpaceOnUse">
    <stop offset="0" stop-color="#1C1D1E"/><stop offset="1" stop-color="#4A4B4D"/></linearGradient>
  <linearGradient id="shoulder" x1="0" y1="{VP[1]}" x2="0" y2="{BOTTOM}" gradientUnits="userSpaceOnUse">
    <stop offset="0" stop-color="#101011"/><stop offset="1" stop-color="#2C2D2F"/></linearGradient>
  <linearGradient id="ringGrey" x1="0" y1="{CY - GREY_R}" x2="0" y2="{CY + GREY_R}" gradientUnits="userSpaceOnUse">
    <stop offset="0" stop-color="#4A4B4E"/><stop offset="1" stop-color="#2A2B2D"/></linearGradient>
  <filter id="neon" x="-20%" y="-20%" width="140%" height="140%"><feGaussianBlur stdDeviation="9"/></filter>
  <clipPath id="view">
    <circle cx="{CX}" cy="{CY}" r="{DISC}"/>
    <path d="M{VP[0]},{VP[1]} L{SHOULDER_R},{BOTTOM} L{SHOULDER_L},{BOTTOM} Z"/>
  </clipPath>
  <clipPath id="below"><circle cx="{CX}" cy="{CY}" r="{GREY_R + GREY_W / 2}"/></clipPath>
</defs>
{bg}
<g transform="translate(0,{SHIFT})">
<g clip-path="url(#below)">
 <g clip-path="url(#view)">
  <rect x="0" y="0" width="1024" height="{VP[1]}" fill="url(#sky)"/>
  <path d="{mountains}" fill="#0A0B0A"/>
  <rect x="0" y="{VP[1]}" width="1024" height="{BOTTOM - VP[1]}" fill="url(#ground)"/>
  {shoulders}{faint}
  <path d="{road}" fill="url(#asphalt)"/>
  {lines}
  {dashes()}
 </g>
</g>
<path d="{arc(GREY_R, 122, 58)}" fill="none" stroke="url(#ringGrey)" stroke-width="{GREY_W}" stroke-linecap="butt"/>
<path d="{arc(GREEN_R, 126, 54)}" fill="none" stroke="#7CD84A" stroke-width="{GREEN_W + 10}" stroke-opacity=".55" filter="url(#neon)"/>
<path d="{arc(GREEN_R, 126, 54)}" fill="none" stroke="#8FE356" stroke-width="{GREEN_W}" stroke-linecap="butt"/>
</g>
{word}
</svg>'''

def render(svg_text, out, size, pad=0):
    """draw [svg_text] into a [size] PNG, the artwork inset by [pad] px, transparent around it"""
    from playwright.sync_api import sync_playwright
    inner = size - 2 * pad
    src = svg_text.replace('width="1024" height="1024" viewBox', f'width="{inner}" height="{inner}" viewBox', 1)
    with sync_playwright() as p:
        b = p.chromium.launch()
        pg = b.new_page(viewport={'width': size, 'height': size})
        pg.set_content(f'<html><body style="margin:0;background:transparent"><div style="padding:{pad}px;line-height:0">{src}</div></body></html>')
        pg.screenshot(path=out, omit_background=True, clip={'x': 0, 'y': 0, 'width': size, 'height': size})
        b.close()


if __name__ == '__main__':
    # writes assets/logo.svg and the PNGs scripts/generate_icons.py makes the app icons from
    import os
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    a = lambda *p: os.path.join(root, 'assets', *p)
    full = svg(radius=0)  # square: Android and iOS round it themselves; the menu rounds it too
    open(a('logo.svg'), 'w').write(full)
    render(full, a('logo.png'), 1024)
    # the menu's logo: closer in, the ring filling most of the tile so it reads at 120 px
    from PIL import Image
    big = a('icons', 'oprivview_logo.png')
    render(full, big, 1024)
    side = 2 * (GREY_R + GREY_W / 2) / 0.86
    cy = CY + 52
    box = (round(CX - side / 2), round(cy - side / 2), round(CX + side / 2), round(cy + side / 2))
    Image.open(big).convert('RGB').crop(box).resize((256, 256), Image.LANCZOS).save(big)
    # adaptive icon foreground: the ring alone, transparent, inside the 66 of 108 dp every mask keeps
    fg = svg(background=False)
    open(a('logo_foreground.svg'), 'w').write(fg)
    ring = 2 * (GREY_R + GREY_W / 2) / 1024        # the ring's share of the artwork
    inner = round(1024 * (66 / 108) / ring)
    render(fg, a('logo_foreground.png'), 1024, pad=(1024 - inner) // 2)
    print('logo written')
