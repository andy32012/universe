#!/usr/bin/env python3
"""Rebuild the JPL Horizons table of planet and moon positions embedded in index.html.

The app interpolates the solar system from this table while the clock is inside its window;
outside it, positions fall back to approximate orbits. Rebuild it before the window ends:

  python3 tools/update_ephemeris.py                     # from the first of this month, 365 days
  python3 tools/update_ephemeris.py --start 2027-01-01  # another window
  python3 tools/update_ephemeris.py --check             # how long the embedded window still lasts

It needs to reach ssd.jpl.nasa.gov and uses only the Python standard library. Every body is then
compared with Horizons at times between the samples (satellites also added to their planet and
compared with their position from the Sun), and nothing is written if the interpolation is off by
more than --max-error-km. The coverage dates quoted in README.md are updated with the table.
"""
import argparse
import base64
import datetime as dt
import hashlib
import json
import math
import re
import struct
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
API = 'https://ssd.jpl.nasa.gov/api/horizons.api'
AU_KM = 149597870.7
DAY_MS = 86400000
UNIX_JD = 2440587.5

# The order sets the layout of the binary. Satellites are stored relative to their planet's centre.
BODIES = [
    # key, Horizons target, centre, hours between samples
    ('Mercury', 199, 10, 6),
    ('Venus', 299, 10, 24),
    ('Earth', 399, 10, 12),
    ('Mars', 499, 10, 24),
    ('Jupiter', 599, 10, 6),
    ('Saturn', 699, 10, 6),
    ('Uranus', 799, 10, 24),
    ('Neptune', 899, 10, 24),
    ('Pluto', 999, 10, 6),
    ('Moon', 301, 399, 6),
    ('Io', 501, 599, 1),
    ('Europa', 502, 599, 2),
    ('Ganymede', 503, 599, 3),
    ('Callisto', 504, 599, 6),
    ('Titan', 606, 699, 6),
    ('Enceladus', 602, 699, 1),
]
PLANET_AT = {399: 'Earth', 599: 'Jupiter', 699: 'Saturn'}

# Check times fall between the samples of every step above: (first, hours apart).
CHECK = (dt.timedelta(hours=7, minutes=37), 17)
HELIO_CHECK = (dt.timedelta(hours=3, minutes=11), 133)

HEAD = 'var SOLAR_EPHEMERIS='
DATA_HEAD = "    var binary=atob('"
DATA_TAIL = "'),bytes=new Uint8Array(binary.length),hash=2166136261;"


def stamp(t):
    return t.strftime('%Y-%m-%d %H:%M')


def epoch_ms(t):
    return round((t - dt.datetime(1970, 1, 1)).total_seconds() * 1000)


def horizons_url(target, centre, first, last, hours):
    return API + '?' + urllib.parse.urlencode([
        ('format', 'json'), ('EPHEM_TYPE', "'VECTORS'"), ('REF_PLANE', "'ECLIPTIC'"), ('REF_SYSTEM', "'ICRF'"),
        ('VEC_TABLE', "'2'"), ('VEC_CORR', "'NONE'"), ('OUT_UNITS', "'AU-D'"), ('CSV_FORMAT', "'YES'"),
        ('TIME_TYPE', "'UT'"), ('OBJ_DATA', "'NO'"), ('COMMAND', "'%d'" % target), ('CENTER', "'500@%d'" % centre),
        ('START_TIME', "'%s'" % stamp(first)), ('STOP_TIME', "'%s'" % stamp(last)), ('STEP_SIZE', "'%d h'" % hours)])


def cache_path(cache, url):
    return cache / (hashlib.sha256(url.encode()).hexdigest()[:24] + '.json')


def fetch(url, cache):
    path = cache_path(cache, url) if cache else None
    if path and path.exists():
        body = path.read_text(encoding='utf-8')
    else:
        for attempt in range(5):
            try:
                with urllib.request.urlopen(url, timeout=180) as res:
                    body = res.read().decode('utf-8')
                break
            except urllib.error.HTTPError as error:
                if error.code < 500 or attempt == 4:
                    sys.exit('Horizons refused the request (%d): %s\n%s' % (error.code, error.read()[:1000].decode('utf-8', 'replace'), url))
            except (urllib.error.URLError, TimeoutError) as error:
                if attempt == 4:
                    sys.exit('Horizons could not be reached: %s\n%s' % (error, url))
            time.sleep(2 ** attempt)
    reply = json.loads(body)
    if 'error' in reply or 'result' not in reply:
        sys.exit('Horizons answered with an error: %s\n%s' % (reply.get('error', reply), url))
    if path and not path.exists():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(body, encoding='utf-8')
    return reply['result']


def vectors(target, centre, first, last, hours, cache):
    """States at first, first + hours, ... last, checked against the times asked for."""
    url = horizons_url(target, centre, first, last, hours)
    text = fetch(url, cache)
    lines = [line.strip() for line in text.splitlines()]
    if '$$SOE' not in lines or '$$EOE' not in lines:
        sys.exit('Horizons sent no table for %d@%d:\n%s\n%s' % (target, centre, text[:2000], url))
    soe, eoe = lines.index('$$SOE'), lines.index('$$EOE')
    names = next(([cell.strip() for cell in line.split(',')] for line in reversed(lines[:soe])
                  if 'VX' in [cell.strip() for cell in line.split(',')]), None)
    source = re.search(r'Target body name:.*?\{source:\s*([^}]*?)\s*\}', text)
    if not names or not source:
        sys.exit('Unexpected Horizons table layout for %d@%d:\n%s\n%s' % (target, centre, text[:2000], url))
    jd = next(i for i, name in enumerate(names) if name.startswith('JD'))
    columns = [names.index(name) for name in ('X', 'Y', 'Z', 'VX', 'VY', 'VZ')]
    rows = []
    for line in lines[soe + 1:eoe]:
        cells = line.split(',')
        rows.append(((float(cells[jd]) - UNIX_JD) * DAY_MS, [float(cells[i]) for i in columns]))
    count = int((last - first) / dt.timedelta(hours=hours)) + 1
    expected = [epoch_ms(first) + i * hours * 3600000 for i in range(count)]
    if len(rows) != count or any(abs(ms - want) > 1000 for (ms, _), want in zip(rows, expected)):
        sys.exit('Horizons returned %d rows for %d@%d, not the %d times asked for\n%s' % (len(rows), target, centre, count, url))
    if not all(math.isfinite(v) for _, state in rows for v in state):
        sys.exit('Horizons returned a non-finite value for %d@%d\n%s' % (target, centre, url))
    # The printed Julian dates carry only tens of microseconds; the times asked for are exact.
    return url, [(want, state) for want, (_, state) in zip(expected, rows)], source.group(1)


def check_times(start, stop, first, hours):
    """The first and last check time inside the window, and the hours between them."""
    begin = start + first
    return begin, begin + dt.timedelta(hours=hours * int((stop - begin) / dt.timedelta(hours=hours))), hours


def interpolate(values, entry, days):
    """index.html's solarEphemerisSample, in the table's own frame."""
    step = entry['stepDays']
    t = days / step
    i = min(math.floor(t), entry['count'] - 2)
    u = t - i
    u2, u3 = u * u, u * u * u
    p0, p1 = 2 * u3 - 3 * u2 + 1, -2 * u3 + 3 * u2
    v0, v1 = (u3 - 2 * u2 + u) * step, (u3 - u2) * step
    a = entry['offset'] + i * 6
    b = a + 6
    return [p0 * values[a + k] + v0 * values[a + k + 3] + p1 * values[b + k] + v1 * values[b + k + 3] for k in range(3)]


def largest_error_km(rows, start_ms, place):
    worst = 0.0
    for ms, state in rows:
        got = place((ms - start_ms) / DAY_MS)
        worst = max(worst, math.dist(got, state[:3]) * AU_KM)
    return worst


def fnv1a(data):
    h = 2166136261
    for byte in data:
        h = ((h ^ byte) * 16777619) & 0xFFFFFFFF
    return h


def build(start, days, cache):
    stop = start + dt.timedelta(days=days)
    start_ms = epoch_ms(start)
    values, bodies = [], {}
    for key, target, centre, hours in BODIES:
        print('Fetching %-9s every %2d h' % (key, hours), flush=True)
        url, rows, solution = vectors(target, centre, start, stop, hours, cache)
        bodies[key] = {'targetId': target, 'centerId': centre, 'stepHours': hours, 'stepDays': hours / 24,
                       'offset': len(values), 'count': len(rows), 'solution': solution, 'sourceUrl': url}
        for _, state in rows:
            values.extend(state)

    for key, target, centre, hours in BODIES:
        entry = bodies[key]
        print('Checking %-9s between samples' % key, flush=True)
        _, rows, _ = vectors(target, centre, *check_times(start, stop, *CHECK), cache)
        relative = largest_error_km(rows, start_ms, lambda d: interpolate(values, entry, d))
        entry.update({'maxMeasuredErrorKm': relative, 'validationSamples': len(rows),
                      'maxMeasuredRelativeErrorKm': relative, 'relativeValidationSamples': len(rows)})
        if centre in PLANET_AT:
            planet = bodies[PLANET_AT[centre]]
            _, helio, _ = vectors(target, 10, *check_times(start, stop, *HELIO_CHECK), cache)
            heliocentric = largest_error_km(helio, start_ms, lambda d: [
                p + s for p, s in zip(interpolate(values, planet, d), interpolate(values, entry, d))])
            entry.update({'maxMeasuredErrorKm': max(relative, heliocentric), 'validationSamples': len(rows) + len(helio),
                          'maxMeasuredHeliocentricErrorKm': heliocentric, 'heliocentricValidationSamples': len(helio)})

    data = struct.pack('<%dd' % len(values), *values)
    meta = {'version': 1, 'generatedUTC': dt.datetime.now(dt.timezone.utc).strftime('%Y-%m-%d'),
            'startMs': start_ms, 'endMs': epoch_ms(stop), 'durationDays': days,
            'coverage': {'startUTC': start.strftime('%Y-%m-%dT%H:%M:%SZ'), 'endUTC': stop.strftime('%Y-%m-%dT%H:%M:%SZ')},
            'valid': False,
            'maxMeasuredErrorKm': max(entry['maxMeasuredErrorKm'] for entry in bodies.values()),
            'validationSamples': sum(entry['validationSamples'] for entry in bodies.values()),
            'bodies': bodies, 'byteLength': len(data), 'checksumFNV1a': fnv1a(data)}
    return meta, data


def embedded_lines(lines):
    heads = [i for i, line in enumerate(lines) if line.startswith(HEAD)]
    datas = [i for i, line in enumerate(lines) if line.startswith(DATA_HEAD) and line.endswith(DATA_TAIL)]
    if len(heads) != 1 or len(datas) != 1:
        sys.exit('index.html does not hold exactly one embedded ephemeris')
    return heads[0], datas[0]


def read_embedded(html):
    lines = html.read_text(encoding='utf-8').split('\n')
    head, data = embedded_lines(lines)
    meta = json.loads(lines[head][len(HEAD):].rstrip(';'))
    return meta, base64.b64decode(lines[data][len(DATA_HEAD):-len(DATA_TAIL)])


def embed(html, meta, data):
    with open(html, encoding='utf-8', newline='') as f:
        lines = f.read().split('\n')
    head, body = embedded_lines(lines)
    lines[head] = HEAD + json.dumps(meta, separators=(',', ':')) + ';'
    lines[body] = DATA_HEAD + base64.b64encode(data).decode('ascii') + DATA_TAIL
    with open(html, 'w', encoding='utf-8', newline='') as f:
        f.write('\n'.join(lines))


def report(meta):
    print('\n%-9s %5s %6s  %-14s %s' % ('body', 'step', 'rows', 'solution', 'largest error between samples'))
    for key, entry in meta['bodies'].items():
        helio = entry.get('maxMeasuredHeliocentricErrorKm')
        print('%-9s %4dh %6d  %-14s %.3f km%s' % (key, entry['stepHours'], entry['count'], entry['solution'],
              entry['maxMeasuredRelativeErrorKm'], '' if helio is None else ' (added to its planet: %.3f km)' % helio))


def main(argv=None):
    today = dt.datetime.now(dt.timezone.utc).replace(tzinfo=None)
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--start', default=today.strftime('%Y-%m-01'), help='first day of the window, UTC (default: the first of this month)')
    parser.add_argument('--days', type=int, default=365, help='length of the window in days (default: 365; the embedded data grows with it)')
    parser.add_argument('--max-error-km', type=float, default=2.0, help='write nothing if any body interpolates worse than this (default: 2)')
    parser.add_argument('--cache', type=Path, help='keep Horizons replies here and reuse them, to rebuild offline')
    parser.add_argument('--html', type=Path, default=ROOT / 'index.html')
    parser.add_argument('--readme', type=Path, default=ROOT / 'README.md')
    parser.add_argument('--check', action='store_true', help='only report the embedded window; exit 1 if under 60 days remain')
    args = parser.parse_args(argv)

    old, _ = read_embedded(args.html)
    if args.check:
        left = (old['endMs'] - epoch_ms(today)) / DAY_MS
        print('Embedded ephemeris covers %s to %s: %.0f days left' % (old['coverage']['startUTC'], old['coverage']['endUTC'], left))
        return 0 if left >= 60 else 1

    start = dt.datetime.strptime(args.start, '%Y-%m-%d')
    if args.days < 2:
        parser.error('--days must be at least 2')
    if not start <= today < start + dt.timedelta(days=args.days):
        print('Note: this window does not include today, so the app will use approximate orbits until it does.')
    meta, data = build(start, args.days, args.cache)
    report(meta)
    if meta['maxMeasuredErrorKm'] > args.max_error_km:
        sys.exit('\nNot written: the interpolation is off by up to %.3f km, more than --max-error-km %.3f.'
                 % (meta['maxMeasuredErrorKm'], args.max_error_km))
    embed(args.html, meta, data)
    print('\nWrote %s: %s to %s, %d bytes, checked at %d times.' % (args.html.name, meta['coverage']['startUTC'],
          meta['coverage']['endUTC'], meta['byteLength'], meta['validationSamples']))

    span = lambda m: '%s 至 %s' % (m['coverage']['startUTC'][:10], m['coverage']['endUTC'][:10])
    if args.readme.exists() and span(old) != span(meta):
        text = args.readme.read_text(encoding='utf-8')
        if span(old) in text:
            args.readme.write_text(text.replace(span(old), span(meta)), encoding='utf-8')
            print('Updated the coverage dates in %s.' % args.readme.name)
        else:
            print('%s does not quote %s; update its coverage dates by hand.' % (args.readme.name, span(old)))
    return 0


if __name__ == '__main__':
    sys.exit(main())
