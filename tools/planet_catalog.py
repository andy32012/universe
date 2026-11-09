#!/usr/bin/env python3
"""Build a deterministic, quality-filtered exoplanet catalog from NASA Exoplanet Archive.
Usage: python tools/planet_catalog.py --input nasa_pscomppars.json --output assets/planet-catalog-100.json
Download JSON with the documented query URL in docs/planet-catalog.md.
"""
import argparse
import json
import math
from pathlib import Path

FIELDS = ("pl_name", "hostname", "disc_year", "pl_rade", "pl_bmasse",
          "pl_orbper", "pl_orbsmax", "sy_dist", "ra", "dec", "st_teff", "st_rad")
SOURCE = "https://exoplanetarchive.ipac.caltech.edu/"
def finite(value):
    try:
        x = float(value)
        return x if math.isfinite(x) else None
    except (ValueError, TypeError):
        return None

def build(rows, limit=100):
    seen = set()
    candidates = []
    for row in rows:
        name = str(row.get("pl_name") or "").strip()
        host = str(row.get("hostname") or "").strip()
        if not name or not host or name.casefold() in seen:
            continue
        radius, period = finite(row.get("pl_rade")), finite(row.get("pl_orbper"))
        distance = finite(row.get("sy_dist"))
        ra, dec = finite(row.get("ra")), finite(row.get("dec"))
        if radius is None or radius <= 0 or period is None or period <= 0:
            continue
        if distance is None or distance <= 0 or ra is None or dec is None or not (0 <= ra < 360 and -90 <= dec <= 90):
            continue
        seen.add(name.casefold())
        mass, axis = finite(row.get("pl_bmasse")), finite(row.get("pl_orbsmax"))
        teff, stellar_radius = finite(row.get("st_teff")), finite(row.get("st_rad"))
        score = int(mass is not None and mass > 0) + int(axis is not None and axis > 0)
        score += int(teff is not None and teff > 0) + int(stellar_radius is not None and stellar_radius > 0)
        candidates.append(((-score, distance, name.casefold()), {
            "name": name, "host": host, "ra_deg": ra, "dec_deg": dec,
            "distance_pc": distance, "radius_earth": radius, "period_days": period,
            "mass_earth": mass if mass and mass > 0 else None,
            "axis_au": axis if axis and axis > 0 else None,
            "stellar_temperature_k": teff if teff and teff > 0 else None,
            "stellar_radius_solar": stellar_radius if stellar_radius and stellar_radius > 0 else None,
            "surface": "illustrative", "orbit_orientation": "illustrative",
            "position": "catalog_direction_and_distance",
            "source": SOURCE
        }))
    return {"schema": 1, "source": SOURCE, "selection": "complete radius, period, distance and sky position; ranked by extra measured/modelled fields and proximity",
            "count": min(limit, len(candidates)),
            "planets": [item for _, item in sorted(candidates)[:limit]]}

def main():
    p = argparse.ArgumentParser()
    p.add_argument("--input", required=True)
    p.add_argument("--output", required=True)
    p.add_argument("--limit", type=int, default=100)
    args = p.parse_args()
    if args.limit <= 0:
        p.error("--limit must be positive")
    rows = json.loads(Path(args.input).read_text(encoding="utf-8"))
    if not isinstance(rows, list):
        p.error("input must be a JSON array")
    result = build(rows, args.limit)
    if result["count"] != args.limit:
        p.error(f"only {result['count']} valid unique planets, requested {args.limit}")
    target = Path(args.output)
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"Validated {result['count']} planets -> {target}")

if __name__ == "__main__":
    main()
