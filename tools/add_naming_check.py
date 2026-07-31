#!/usr/bin/env python3
"""Are the album titles we STORE the ones the services will REPORT when they play?

    python3 tools/add_naming_check.py [--host plex:9000]

Played's streaming path matches on artist + album TITLE (Played::_matchRecord ->
DB::findByArtistAlbum), with no album-id anchor. So a stored title that differs from what
the service calls the release can NEVER be matched: the album plays perfectly, nothing is
logged, and the row silently never leaves the list. That is the hardest failure in this
plugin to notice, and it is invisible from the list itself.

Every add prints both halves into the log — Material's label (what the service calls it)
and the title that got stored — so the whole matrix of surfaces can be checked from one
log fetch, with no DB access and nothing to install. Add from each service and each
sibling plugin, then run this.

Three verdicts, and only one of them is a bug:

  OK     stored == label. Matching will work.
  strip  stored == label minus something _addCtxCommand removes ON PURPOSE — a trailing
         "(YYYY)", a format qualifier ("(Album)"/"(Hi-Res)"/"(Explicit)"/...), or a
         sibling's "Artist - " row prefix. These are correct: the qualifier is the
         PLUGIN'S label decoration, not part of the album name, so the service reports
         the stripped form and the stored title is the one that matches.
  **     stored is a DIFFERENT title. This is the bug — historically an '&al=' handshake
         handing over MusicBrainz's release name instead of the service's (rec 205,
         2026-07-30: MB "Radio: Fourth Space (Original Music from Big Walk)" vs Qobuz
         "... (Original Music from the Game \"Big Walk\")").

A '**' row needs fixing at the SENDER — the sibling plugin must pass the service's own
name — not by loosening the match here, which would start matching the wrong releases.
"""
import argparse, html, re, sys, urllib.request

# What _addCtxCommand strips on purpose, in the order it strips it.
YEAR = re.compile(r'\s*\((?:19|20)\d{2}\)\s*$')
QUAL = re.compile(r'\s*\((?:Hi-Res[^)]*|Explicit|Mono|Stereo|Album|Track)\)\s*$', re.I)
DASH = re.compile(r'^.+?\s+[-‐-―−]\s+')

ADD = re.compile(
    r"LL: addctx params -> name=(?P<name>.*?), artist=(?P<artist>.*?), albumid=.*?"
    r"favurl=(?P<favurl>.*?), image=.*?, svc=(?P<svc>.*?)\n")
ROW = re.compile(
    r"LL: add -> (?P<source>\w+) / (?P<title>.*?) "
    r"\(id=(?P<id>\d+), already=(?P<already>\d+), list=(?P<list>\w+), rel=(?P<rel>.*?)\)")


def classify(label, stored):
    """OK / strip / ** — see the module docstring."""
    if label.strip() == stored.strip():
        return 'OK', ''
    probe, notes = label, []
    for rx, why in ((YEAR, 'year'), (QUAL, 'qualifier')):
        new = rx.sub('', probe)
        if new != probe:
            probe, _ = new, notes.append(why)
    if probe.strip() == stored.strip():
        return 'strip', '+'.join(notes)
    new = DASH.sub('', probe)                       # a sibling's "Artist - Album" label
    if new.strip() == stored.strip():
        return 'strip', '+'.join(notes + ['artist-prefix'])
    return '**', ''


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--host', default='plex:9000')
    args = ap.parse_args()

    url = f"http://{args.host}/log.txt?lines=100000"
    raw = html.unescape(urllib.request.urlopen(url, timeout=40).read().decode('utf8', 'replace'))

    # Pair each addctx with the NEXT 'add ->' after it IN THE LOG, rather than zipping the
    # two streams positionally. They do not run in lockstep: a rejected add logs params and
    # never reaches _finishAlbumAdd, and a re-add that dedupes logs already=1 — either one
    # shifts a positional zip and silently reports the wrong stored title against the wrong
    # label (it printed one record twice before this was fixed).
    events = sorted(
        [(m.start(), 'add', m) for m in ADD.finditer(raw)]
        + [(m.start(), 'row', m) for m in ROW.finditer(raw)])
    pairs, pending = [], None
    for _, kind, m in events:
        if kind == 'add':
            if pending is not None:
                pairs.append((pending, None))     # logged, never stored → rejected
            pending = m
        elif pending is not None:
            pairs.append((pending, m))
            pending = None
    if pending is not None:
        pairs.append((pending, None))             # still in flight at log's end

    if not pairs:
        print("no adds in the log — add something from Material, then re-run")
        return 0

    # A dedupe no-op stores nothing new, so its title tells us nothing about naming.
    dropped = [(a, r) for a, r in pairs if r is None or r['already'] != '0']
    pairs = [(a, r) for a, r in pairs if r is not None and r['already'] == '0']
    if dropped:
        print(f"({len(dropped)} add(s) skipped — rejected, or already in the list)\n")

    rows = [r for _, r in pairs]
    adds = [a for a, _ in pairs]
    print(f"{len(rows)} add(s)\n")
    print(f"{'id':>4}  {'via':<26} {'src':<9} {'rel':<7} {'verdict':<16} title")
    print("-" * 108)
    bad = []
    for a, r in zip(adds, rows):
        label, stored = a['name'], r['title']
        verdict, why = classify(label, stored)
        tag = {'OK': 'OK', 'strip': f'strip({why})', '**': '** MISMATCH'}[verdict]
        print(f"{r['id']:>4}  {a['svc'] or '(native)':<26} {r['source']:<9} "
              f"{r['rel']:<7} {tag:<16} {label}")
        if verdict != 'OK':
            print(f"{'':>4}  {'':<26} {'':<9} {'':<7} {'':<16} -> stored: {stored}")
        if verdict == '**':
            bad.append((r['id'], a['svc'] or '(native)', r['source'], label, stored))

    print("\n=== titles that can NEVER match when played ===")
    for rid, svc, src, label, stored in bad:
        print(f"  rec {rid}  {src} via {svc}")
        print(f"    service reports: {label}")
        print(f"    we stored      : {stored}")
    if not bad:
        print("  none — every stored title is what its service will report")
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
