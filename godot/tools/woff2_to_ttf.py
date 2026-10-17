"""WOFF2 -> TTF for the bundled CJK font (fonts/README.md): the iPad showed boxes with the WOFF2 file, so the app
ships the font uncompressed. Needs fonttools and brotli (pip install fonttools brotli).
    python tools/woff2_to_ttf.py fonts/DroidSansFallbackFull.woff2 fonts/DroidSansFallbackFull.ttf
"""
import sys
from fontTools.ttLib import TTFont

src, dst = sys.argv[1], sys.argv[2]
font = TTFont(src)
print('source flavor:', font.flavor, ' glyphs:', len(font.getGlyphOrder()))
font.flavor = None
font.save(dst)
check = TTFont(dst)
cmap = check.getBestCmap()
probe = '宇宙設定蟲洞前進太陽系銀河'
print('saved', dst, ' flavor:', check.flavor, ' glyphs:', len(check.getGlyphOrder()),
      ' probe:', sum(1 for c in probe if ord(c) in cmap), '/', len(probe))
