# Save a streaming-service PLAYLIST to Listen Later

## Context

Listen Later can save an album, an individual track and a podcast episode. It cannot
save a **playlist offered by a streaming service** — and the failure is silent rather
than absent:

- **Tidal / Deezer** playlist rows carry `favorites_url: tidal://playlist:<uuid>` /
  `deezer://playlist:<id>`. `Sources::favurlIsTrack` correctly returns 0 for a
  `playlist:` container ref, so the row falls straight through to the **album** path in
  `_addCtxCommand`. No `album:` matches in the favurl, so it is stored as
  `ref_kind='search'` and replayed by searching the service for an *album* named
  "Dance Pop". A junk row that can never play.
- **Qobuz** playlist rows carry no favurl at all. They land in the no-favurl `else`
  branch, `svc='qobuz'` is believed, and `qobuzAlbumIdFromImage` is asked for an album id.
  For an editorial playlist the cover is `…/images/playlists/<id>_…` so it returns
  nothing and we get another search-replay junk row.

The intended outcome: adding a curated playlist stores it as a first-class
`kind='playlist'` row that plays and drills into the service's live tracklist, and a
playlist we cannot positively identify is refused rather than stored broken.

### Evidence gathered (probed, not assumed)

Live server `http://plex:9000` (LMS 9.1.2), plus the upstream plugin sources.

| Service | Playlists | Identity on the browse row | Replay coderef |
|---|---|---|---|
| Tidal | own + curated | `tidal://playlist:<uuid>` in `favorites_url` — one shared `_renderPlaylist` emits it for **every** playlist list | `Plugins::TIDAL::Plugin::getPlaylist`, passthrough `{ uuid }` |
| Deezer | own + curated | `deezer://playlist:<id>`, likewise one shared renderer (verified live on "Favourite tracks") | `Plugins::Deezer::Plugin::getPlaylist`, passthrough `{ id }` |
| Qobuz — editorial | yes | no favurl; cover is `static.qobuz.com/images/playlists/<ID>_<hash>_rectangle.jpg`. Verified: `69183531` → "Hi-Res Masters: 2016 / Qobuz UK", exactly the row text | `Plugins::Qobuz::Plugin::QobuzPlaylistGetTracks`, passthrough `{ playlist_id }` |
| Qobuz — personal | yes | **no durable identity** when the playlist has no artwork of its own — `API::Common::getPlaylistImage` falls back to a constituent track's album cover (`…/images/covers/…`) | n/a |
| Bandcamp | none | — | — |
| Spotify / Spotty | yes | already refused — not a replayable source | — |

All three coderefs take `($client, $cb, $args, $passthrough)` and call back
`{ items => [...] }`, i.e. exactly the shape `Sources::resolveTracks` already handles,
and their track items set `play`/`url` so `Sources::isPlayableTrack` counts them.

**No Material change is needed.** Playlist rows already resolve to the `online-album`
category — CLAUDE.md's 0.1.53 entry records an LB playlist tile firing `addctx`, which
proves Add appears on them. Nothing in the `actions.json` / `registerCustomAction`
machinery (the source of the last several review rounds) is touched.

Baseline before any change: `sh tools/t_all.sh` → **662 checks, 12 suites, all green**.

### Settled scope — write this into the Review Ledger

- **Curated / service-provided playlists only.** Personally-created playlists are not a
  target. Tidal and Deezer personal playlists happen to work because they share one
  renderer; a **Qobuz personal playlist with no artwork of its own has no recoverable
  id and is deliberately NOT supported.** It keeps today's behaviour (it is
  indistinguishable from an album row, so it cannot be detected to be refused). This is
  a decision, not a defect — do not re-raise it.
- **Playlists live in Listen Later only.** "Add to Wish List" on a playlist saves to
  Listen Later with a log line — the rule `_savePodcastEpisode` already applies, for the
  same reason (a Wish List is for things you might buy).
- **Playlists never auto-move to Played.** A playlist is not a release and a curated one
  changes under you, so a "% of it heard" threshold is meaningless. This needs no new
  code: every Played lookup is already filtered to `kind='album'` or `kind='track'`.
- The real long-term fix for the Qobuz hole is upstream: `Qobuz::Plugin::_playlistItem`
  emits no `favorites_url`, unlike Tidal and Deezer. A one-line PR adding
  `qobuz://playlist:<id>` would close it for everyone. Out of scope here.

---

## Step 0 — verify on the live box BEFORE writing any code

The one thing inferred rather than observed is **what Material actually sends** for a
playlist row (`$TITLE` / `$ARTISTNAME` / `$FAVURL` / `$IMAGE` / `$SERVICE`). That decides
the detector's inputs, so confirm it first. `_addCtxCommand` already logs its params at
WARN unconditionally, so no build is needed.

Simon runs (nothing to install):

1. In Material, tap **Add to Listen Later** on one row of each: a **Tidal** curated
   playlist (Tidal → Home → Popular playlists on TIDAL), a **Deezer** curated playlist,
   and a **Qobuz** editorial playlist (Qobuz → Qobuz Playlists → Hi-Res).
2. Then, from this machine:
   ```
   curl -s http://plex:9000/log.txt | grep -i "addctx\|LL: add\|rejected add"
   ```
3. And list what actually got stored, to document the junk rows:
   ```
   curl -s -X POST http://plex:9000/jsonrpc.js \
     -d '{"id":1,"method":"slim.request","params":["dc:a6:32:77:ea:e0",["listenlater","items","0","50"]]}'
   ```
   Remove the junk rows afterwards via the row's "…" → Remove.

Expected: three `LL: addctx params ->` lines showing a `favurl=tidal://playlist:…`,
a `favurl=deezer://playlist:…`, and a Qobuz line with **empty favurl** and
`image=…images%2Fplaylists%2F<id>_…`. If any of that differs, the detector below changes
shape — which is exactly why this comes first.

---

## Implementation

Version 0.1.106 → **0.1.107**. Per the repo conventions: bump `install.xml` +
`repo.xml`, bump `Podcast::CACHE_VER` (dev builds invalidate caches), update `CLAUDE.md`
version history + Review Ledger. **No CHANGELOG/README** (main-merge only) and **no
commit, tag or push** without explicit approval.

### 1. `Sources.pm` — detection and replay

**`playlistFromRow($favurl, $image)`** *(new)* — the single detector. Returns
`($source, $playlistId)` or `()`. Same discipline as `knownSource`/`ownSurface`: exact
shapes, no guessing.

```
favurl  =~ m{^(\w+)://.*?(?:[:/])playlist:([A-Za-z0-9._-]+)}  → (lc $1 via %SCHEME, $2)
                                                    # the hyphens in a Tidal uuid are covered
image   → URI::Escape::uri_unescape, then
          m{static\.qobuz\.com/images/playlists/(\d+)_}       → ('qobuz', $1)
```

Deliberately mirrors `qobuzAlbumIdFromImage` (which sits right above it and matches
`/images/covers/`, a disjoint path — the two can never both fire).

**`_serviceCanPlaylist($source)`** *(new, beside `_serviceCan`)** — `->can()` probes:
`Qobuz::Plugin::QobuzPlaylistGetTracks`, `TIDAL::Plugin::getPlaylist`,
`Deezer::Plugin::getPlaylist`. Same "don't store what we can't replay" gate the album
path uses; keeps `_serviceCan` itself untouched.

**`_streamingPlaylistNode($client, $source, $playlistId, $rec)`** *(new, mirrors
`_streamingAlbumNode`)* — `type => 'playlist'`, `url => <coderef>`, passthrough
`{ playlist_id }` / `{ uuid => $id, creatorId => '' }` / `{ id => $id, creatorId => '' }`.
Note `creatorId => ''` rather than omitted: Tidal's and Deezer's `getPlaylist` both do
`$api->userId eq $params->{creatorId}`, which warns under `use warnings` on an undef.

**`buildPlayableItems`** — one new branch, placed immediately after the existing
`kind eq 'track'` branch and before the `$source eq 'library'` branch:

```
if (($rec->{kind} || '') eq 'playlist') {
    my $item = _streamingPlaylistNode(...);
    return $cb->([$item]) if $item;
    return $cb->([{ name => cstring($client,'PLUGIN_LL_NO_MATCH'), type => 'text' }]);
}
```
**No search fallback** — a playlist cannot be found by an artist+album search, and
falling through to `_searchService` is exactly how today's junk rows arise.

**`resolveTracks`** — the same `kind eq 'playlist'` guard is not needed: it delegates to
`buildPlayableItems` and then invokes the node's coderef, which is already the right
behaviour for all three services. Verify only that the `{items=>…}` shape is handled — it
is.

**`hasDirectAlbumRef`** — no change required (a playlist ref carries no `album_id`, so it
already returns 0), but add a `kind eq 'playlist'` early `return 0` so the invariant is
stated rather than inherited.

### 2. `DB.pm` — a third kind

- Schema comment on `kind`: `'album' | 'track' | 'playlist'`. **No migration** —
  the column already exists and defaults to `'album'`; nothing is added or altered.
- `add()` line ~269: the hard binary
  `$kind = ($rec->{kind} && $rec->{kind} eq 'track') ? 'track' : 'album'` becomes a
  three-way whitelist.
- **New key form.** `playlistKey($source, $id, $title)` →
  `'' . '|' . _norm($title) . '|' . '' . '|p:' . lc($source) . ':' . $id`
  e.g. `|hires masters 2016||p:qobuz:69183531`. Three points, all load-bearing:
  - the **source is inside the id segment** — `findAnyByKey` is cross-source, so without
    it Qobuz playlist 123 and Deezer playlist 123 would dedupe into one row;
  - it has **≥ 2 pipes**, so the 0.1.43 year migration
    (`WHERE dedupe_key NOT LIKE '%|%|%'`) skips it;
  - the artist segment is **empty**, so a playlist's curator line can be stored and
    displayed without affecting dedupe.
- `ref_kind => 'playlist_id'`, `ref => { _svc, playlist_id }`. **Never write `album_id`
  into a playlist ref** — `findBySourceAlbumId` is the one finder with no `kind` filter
  and it keys on `ref.album_id`.

Everything else in DB.pm is already safe by construction — `findByArtistAlbum`,
`findByAlbum`, `findBySourceRefTitle` filter `kind='album'`; `findSavedTrack`,
`findTrackByArtistTitle`, `findTrackByUrl` filter `kind='track'`. A playlist row is
invisible to all six. `list()` is kind-agnostic and needs nothing.

### 3. `Plugin.pm` — the add path

**`_addCtxCommand`** — one new branch, placed **after** the `kind:podcast` branch and
**before** the track branch:

```
my ($plSource, $plId) = Sources::playlistFromRow($p{favurl}, $p{image});
return _savePlaylistRecord($request, $list, \%p, $plSource, $plId) if $plSource;
```

Position matters for a reason worth stating in the comment: the album path below strips
a trailing `(YYYY)` and format qualifiers off the title, which would mangle a playlist
named e.g. "Best of (2016)". A playlist title is taken **verbatim**.

**`_savePlaylistRecord`** *(new, modelled on `_insertTrackRow` — flat, synchronous, no
service round trip)*:

1. reject with no title (`_rejectAdd(..., 'no playlist title')`);
2. reject unless `_isReplayableSource($source)` **and** `_serviceCanPlaylist($source)`
   (`'service has no playlist call'`);
3. `$list = 'later'` if `wishlist`, with the same log line `_savePodcastEpisode` writes;
4. build the record and `DB::add($rec, 'later')`;
5. `showBriefly` via the existing `_addedMsg`, `addResult('count', …)`, `setStatusDone`.

It deliberately does **not** call `_finishAlbumAdd`. That tail runs the single/track
cross-kind dedupe, `_verifyRelease`, and `_backfillStreamingArtist` — all three are
release semantics that mean nothing for a playlist, and routing through it is how a
playlist would acquire a bogus `rel_type` or `track_count`.

**`_contextMenuQuery`** — suppress the "Move to Wish List" entry when
`kind eq 'playlist'` (one `next if` in the existing `for my $target` loop). The Bandcamp
"Buy" entry is already gated on `source eq 'bandcamp'` and Bandcamp has no playlists, so
it needs nothing.

### 4. `Browse.pm` — rendering

- `GLYPH_PLAYLIST => "\x{2261}"` (≡ — universally present in the fonts Material uses;
  swap freely, it is a taste call).
- `_glyphFor` — return it for `kind eq 'playlist'`, checked **after** the podcast test
  and before the track test.
- `_typeLabel` — return `PLUGIN_LL_TYPE_PLAYLIST` for `kind eq 'playlist'`.
- `_row` — dispatch `kind eq 'playlist'` to a new **`_playlistRow`**, mirroring
  `_trackRow`'s precedent rather than branching inside `_albumRow`: it is the same shape
  as `_albumRow` (`type => 'playlist'`, `url => \&_albumTracks`, the same
  `itemActions→info`) but the name is the **playlist title alone** — no `Artist –`
  prefix, no appended `(Year)` — and the subtitle is
  `≡ Playlist · <Source>[ · <curator>]`, the last segment only when an artist arrived.
- `_albumTracks` line ~312 — the guard `($rec->{kind}||'') ne 'track'` must become
  `eq 'album'`. This is the single most important edit in the file: left as-is, opening a
  playlist would write a `track_count` and a `rel_type` onto it from the playlist's length.

### 5. `strings.txt`

`PLUGIN_LL_TYPE_PLAYLIST` → `Playlist`, in the block with the other `PLUGIN_LL_TYPE_*`.

---

## Verification

### Offline suite — the gate

`sh tools/t_all.sh` must stay green and grow. Baseline **662 / 12 suites**.

Write the new cases against the **existing** harnesses, in the repo's style (assert on
the *stored row*, and anti-test every fix):

- **`t_addpath.pl`** — the main body of work. Declare the three playlist coderefs in the
  stub glob block beside the existing `QobuzGetTracks`/`getAlbum` stubs, then:
  - Tidal `favurl=tidal://playlist:<uuid>` → `kind='playlist'`, `source='tidal'`,
    `ref.playlist_id` = the uuid, `ref.album_id` **undef**, `rel_type` undef,
    `track_count` undef.
  - Deezer `deezer://playlist:<id>` → same.
  - Qobuz, **empty favurl**, `image=` a proxied `…/images/playlists/69183531_…` →
    `source='qobuz'`, `playlist_id='69183531'`.
  - `list:wishlist` on a playlist → row lands in `later`.
  - A title containing `(2016)` → stored **verbatim**, proving the branch runs ahead of
    the album title cleaning.
  - Re-adding the same playlist → `already`, one row.
  - Same playlist id on two different services → **two** rows (the cross-source
    `findAnyByKey` case the key's source segment exists for).
  - Reject: a playlist on a service with no playlist coderef → nothing stored.
  - **Positive controls against over-broad detection** — these are what stop the fix
    widening into damage: `tidal://album:529626253` must still store `kind='album'`;
    a Qobuz row whose image is `…/images/covers/tb/ta/o8cmpfxeqtatb_600.jpg` must still
    store `kind='album'` with that `album_id`; `qobuz://312500115.flac` must still store
    `kind='track'`.
- **`t_favurl.pl`** — `playlistFromRow` unit cases, including the decisive negatives:
  `…/images/covers/…` must not yield a playlist, and `favurlIsTrack` must still answer 0
  for every `playlist:` url.
- **`t_db.pl`** — `add()` accepts `kind='playlist'`; the key shape; a playlist row is
  returned by `list()` but by **none** of `findByArtistAlbum`, `findByAlbum`,
  `findBySourceRefTitle`, `findSavedTrack`, `findTrackByArtistTitle`,
  `findBySourceAlbumId`.
- **`t_played.pl`** — a saved playlist is never matched by `_matchRecord` and never
  auto-moves, including when a track *from that playlist* is playing.
- **`t_resolve_count.pl`** — `hasDirectAlbumRef` returns 0 for a playlist row.

**Anti-test each half separately** (the 0.1.104 lesson): neutering `playlistFromRow`
must fail the add cases and *not* the positive controls; reverting the
`ne 'track'` → `eq 'album'` guard in `_albumTracks` must fail the "playlist gains no
rel_type/track_count" case specifically.

Also run `perl -c` on every changed `.pm` **and** grep for calls to any renamed sub —
`perl -c` passes on calls to subs that do not exist.

### Live, after the build

Install (`ListenLater.zip` → the documented unzip/chown/restart), then over HTTP only:

1. Add a **Tidal**, a **Deezer** and a **Qobuz** curated playlist from Material.
2. `curl -s http://plex:9000/log.txt | grep "LL: playlist add\|rejected add"` — three
   adds, no rejects.
3. `["dc:a6:32:77:ea:e0",["listenlater","items","0","50"]]` — three rows reading
   `≡ Playlist · Tidal` etc., titles verbatim, no `Artist –` prefix, no `(Year)`.
4. Drill into each: the service's live tracklist appears. Play one: it plays.
5. Re-open the list — the playlist rows still say "Playlist", have gained no
   Album/EP/Single label and no track count.
6. Play a full playlist through and confirm it does **not** move to Played, while an
   album played alongside it still does (the regression that would matter most).
7. "…" → More on a playlist row: **Move to Played** and **Remove** present,
   **Move to Wish List** absent.
8. Add the same playlist again → no second row.

### What must be unchanged

Re-run the album, track and podcast paths end to end after the change — a Qobuz album
row, a Tidal album row, a track from inside a Qobuz playlist (which already works:
those rows carry `qobuz://<id>.flac` → `favurlIsTrack` → `kind='track'`), and a podcast
episode. None of them may change behaviour, and none of their stored fields may change
shape.
