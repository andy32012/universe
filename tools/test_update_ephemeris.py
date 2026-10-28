#!/usr/bin/env python3
"""Rebuilding from the table already in index.html, served back the way Horizons sends it, must reproduce it.

Runs offline: python3 tools/test_update_ephemeris.py
It checks the parsing, packing, checksum and embedding of update_ephemeris.py, not Horizons itself.
"""
import datetime as dt
import importlib.util
import json
import shutil
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
SCRIPT = HERE / 'update_ephemeris.py'
spec = importlib.util.spec_from_file_location('update_ephemeris', SCRIPT)
eph = importlib.util.module_from_spec(spec)
spec.loader.exec_module(eph)

COLUMNS = ('            JDUT,            Calendar Date (UT),                      X,                      Y,'
           '                      Z,                     VX,                     VY,                     VZ,')


def reply(target, centre, solution, rows):
    """A Horizons API reply in the layout of a CSV vector table."""
    lines = ['*' * 80,
             'Target body name: Body (%d)                     {source: %s}' % (target, solution),
             'Center body name: Centre (%d)                   {source: %s}' % (centre, solution),
             '*' * 80, COLUMNS, '*' * 80, '$$SOE']
    for t, state in rows:
        jd = (t - dt.datetime(1970, 1, 1)).total_seconds() / 86400 + eph.UNIX_JD
        lines.append('%.9f, A.D. %s:00.0000, %s,' % (jd, t.strftime('%Y-%b-%d %H:%M'), ', '.join('%.15E' % v for v in state)))
    lines += ['$$EOE', '*' * 80]
    return json.dumps({'signature': {'source': 'NASA/JPL Horizons API', 'version': '1.2'}, 'result': '\n'.join(lines)})


def serve(cache, target, centre, first, last, hours, solution, state_at):
    times, t = [], first
    while t <= last:
        times.append(t)
        t += dt.timedelta(hours=hours)
    url = eph.horizons_url(target, centre, first, last, hours)
    eph.cache_path(cache, url).write_text(reply(target, centre, solution, [(t, state_at(t)) for t in times]), encoding='utf-8')
    return url


def main():
    meta, data = eph.read_embedded(HERE.parent / 'index.html')
    values = struct.unpack('<%dd' % (len(data) // 8), data)
    start = dt.datetime.strptime(meta['coverage']['startUTC'], '%Y-%m-%dT%H:%M:%SZ')
    stop = start + dt.timedelta(days=meta['durationDays'])
    bodies = meta['bodies']
    days = lambda t: (t - start).total_seconds() / 86400
    place = lambda key, t: eph.interpolate(values, bodies[key], days(t)) + [0.0, 0.0, 0.0]

    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        cache = tmp / 'cache'
        cache.mkdir()
        for key, target, centre, hours in eph.BODIES:
            entry = bodies[key]
            at = lambda t, entry=entry, hours=hours: entry['offset'] + 6 * round(days(t) * 24 / hours)
            row = lambda t, at=at: list(values[at(t):at(t) + 6])
            url = serve(cache, target, centre, start, stop, hours, entry['solution'], row)
            assert url == entry['sourceUrl'], 'request differs from the embedded one for %s:\n%s\n%s' % (key, url, entry['sourceUrl'])
            serve(cache, target, centre, *eph.check_times(start, stop, *eph.CHECK), entry['solution'],
                  lambda t, key=key: place(key, t))
            if centre in eph.PLANET_AT:
                planet = eph.PLANET_AT[centre]
                serve(cache, target, 10, *eph.check_times(start, stop, *eph.HELIO_CHECK), entry['solution'],
                      lambda t, key=key, planet=planet: [p + s for p, s in zip(place(planet, t), place(key, t))])

        html, readme = tmp / 'index.html', tmp / 'README.md'
        shutil.copy(HERE.parent / 'index.html', html)
        shutil.copy(HERE.parent / 'README.md', readme)
        subprocess.run([sys.executable, str(SCRIPT), '--start', start.strftime('%Y-%m-%d'), '--days', str(meta['durationDays']),
                        '--cache', str(cache), '--html', str(html), '--readme', str(readme)], check=True, stdout=subprocess.DEVNULL)

        rebuilt, rebuilt_data = eph.read_embedded(html)
        assert rebuilt_data == data, 'the rebuilt table differs from the embedded one'
        for field in ('startMs', 'endMs', 'durationDays', 'coverage', 'valid', 'byteLength', 'checksumFNV1a'):
            assert rebuilt[field] == meta[field], field
        assert list(rebuilt['bodies']) == list(bodies)
        for key, entry in bodies.items():
            for field in ('targetId', 'centerId', 'stepHours', 'stepDays', 'offset', 'count', 'solution', 'sourceUrl',
                          'validationSamples', 'relativeValidationSamples', 'heliocentricValidationSamples'):
                assert rebuilt['bodies'][key].get(field) == entry.get(field), '%s %s' % (key, field)
            assert rebuilt['bodies'][key]['maxMeasuredErrorKm'] < 1e-6, key
        assert list(rebuilt) == list(meta) and all(list(rebuilt['bodies'][k]) == list(e) for k, e in bodies.items()), 'field order'
        assert eph.fnv1a(rebuilt_data) == rebuilt['checksumFNV1a']

        before = (HERE.parent / 'index.html').read_text(encoding='utf-8').split('\n')
        after = html.read_text(encoding='utf-8').split('\n')
        head, _ = eph.embedded_lines(before)
        assert len(before) == len(after) and all(a == b for i, (a, b) in enumerate(zip(before, after)) if i != head), 'other lines changed'
        assert readme.read_text(encoding='utf-8') == (HERE.parent / 'README.md').read_text(encoding='utf-8')
    print('ok: rebuilding the embedded ephemeris reproduces all %d bytes' % len(data))


if __name__ == '__main__':
    main()
