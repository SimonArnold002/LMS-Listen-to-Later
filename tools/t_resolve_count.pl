#!/usr/bin/env perl
# Regression tests for what a RESOLVE writes back to the row (Browse::_albumTracks) — the
# 0.1.88 "refresh the count on every resolve" pass, and the failed-resolve hole in it.
#
# THE BUG THIS PROTECTS AGAINST
#
# _albumTracks filters the resolved items down to the playable ones, then keeps a display
# fallback so the drill view is never blank:
#
#     @playable = @$tracks unless @playable;
#
# On a FAILED resolve, Sources::_noMatch returns exactly one { type => 'text' } row. The
# filter drops it, the fallback puts it back — and the write-back then counted THAT as one
# playable track. So a failed resolve stamped track_count=1 and rel_type='single' on the row.
# Both are load-bearing: DB::updateTrackCount deliberately OVERWRITES (it's a
# re-measurement), so a real stored count was clobbered with 1, and Played::_totalTracks
# reads 1 as a genuine total — meaning a 10-track album whose resolve merely failed once got
# marked Played after a single track, then auto-purged played_retention_days later.
#
# The fix counts the REAL playable tracks before the display fallback can restore anything.
# Sources::_resolveCount already greps identically and yields undef on empty — the two call
# sites had drifted, and this suite pins them together.
#
# The resolve itself is stubbed (no service, no network): each case decides exactly what
# resolveTracks hands back, which is the only thing under test here.
use strict;
use warnings;
use FindBin;
use File::Temp qw(tempdir);
require "$FindBin::Bin/t_stubs.pl";

my $dir = tempdir(CLEANUP => 1);
Slim::Utils::Prefs::set_test_pref_ns('server', 'cachedir', $dir);

ll_require('DB', 'Sources', 'Podcast', 'Browse', 'Played');

my ($pass, $fail) = (0, 0);
sub is {
    my ($desc, $got, $want) = @_;
    my $ok = (!defined $got && !defined $want)
          || (defined $got && defined $want && "$got" eq "$want");
    $ok ? $pass++ : $fail++;
    printf "%s %-58s got=%-10s want=%s\n", ($ok ? 'ok  ' : 'FAIL'), $desc,
        (defined $got ? "'$got'" : '(undef)'), (defined $want ? "'$want'" : '(undef)');
}
sub section { printf "\n== %s\n", $_[0] }

# What the stubbed resolve will hand back for the next _albumTracks call.
our @RESOLVED;
{
    no warnings qw(redefine once);
    *Plugins::ListenLater::Sources::resolveTracks = sub {
        my ($client, $rec, $cb) = @_;
        return $cb->([@RESOLVED]);
    };
}

# The real shapes the services produce.
sub playable { return map { { name => "Track $_", type => 'audio', url => "qobuz://$_.flac" } } 1 .. $_[0] }
sub nomatch  { return ({ name => 'PLUGIN_LL_NO_MATCH', type => 'text' }) }               # Sources::_noMatch
sub bandcamp_helpers {                                                                    # 0.1.26: helper rows
    return ({ name => 'Download album from …', type => 'text' },
            { name => 'artist.bandcamp.com', weblink => 'https://artist.bandcamp.com/album/x' });
}

# Store a row, run the real _albumTracks over it, hand back the row as it now stands plus
# what the drill view was given.
sub resolve_row {
    my (%o) = @_;
    my ($id) = Plugins::ListenLater::DB::add({
        source      => $o{source} // 'qobuz',
        artist      => 'Wet Leg',
        album_title => $o{album} // ('Album ' . ++our $N),
        rel_type    => $o{rel},
        track_count => $o{count},
        ref_kind    => 'search',
        ref         => {},
    }, 'later');
    @RESOLVED = @{ $o{resolved} };
    my $shown;
    Plugins::ListenLater::Browse::_albumTracks(undef, sub { $shown = shift }, {}, { id => $id });
    return (Plugins::ListenLater::DB::get($id), scalar @{ $shown->{items} || [] });
}

# ---------------------------------------------------------------------------
section('a FAILED resolve must not record a 1-track release');

my ($r, $shown) = resolve_row(resolved => [ nomatch() ]);
is('no count invented',                  $r->{track_count}, undef);
is('no type invented',                   $r->{rel_type},    undef);
is('the view still shows the text row',  $shown, 1);

# The damaging half: the row already KNEW its size, and updateTrackCount overwrites.
($r) = resolve_row(count => 10, rel => 'album', resolved => [ nomatch() ]);
is('a real count is NOT clobbered',      $r->{track_count}, 10);
is('a real type is NOT clobbered',       $r->{rel_type},    'album');

# ...and what that clobbering did downstream, which is the reason it mattered.
Slim::Utils::Prefs::set_test_pref('played_threshold', 60);
is('a 10-track album still needs 10',
    Plugins::ListenLater::Played::_totalTracks($r), 10);
my ($bad) = resolve_row(count => 10, rel => 'album', resolved => [ nomatch() ]);
is('...not 1 (which marked it Played on track one)',
    (Plugins::ListenLater::Played::_totalTracks($bad) == 1 ? 'BROKEN' : 'ok'), 'ok');

section('a resolve of ONLY helper rows is also a failure (Bandcamp)');
($r, $shown) = resolve_row(count => 9, resolved => [ bandcamp_helpers() ]);
is('helper-only: count untouched',       $r->{track_count}, 9);
is('helper-only: no type invented',      $r->{rel_type},    undef);
is('...but the view is not blank',       $shown, 2);

# ---------------------------------------------------------------------------
section('a SUCCESSFUL resolve still writes back (0.1.88 must keep working)');

($r) = resolve_row(resolved => [ playable(11) ]);
is('count recorded',                     $r->{track_count}, 11);
is('type classified from the count',     $r->{rel_type},    'album');

($r) = resolve_row(count => 4, resolved => [ playable(11) ]);
is('a stale count IS re-measured',       $r->{track_count}, 11);

($r) = resolve_row(resolved => [ playable(1) ]);
is('one real track -> count 1',          $r->{track_count}, 1);
is('...classified single',               $r->{rel_type},    'single');

($r) = resolve_row(resolved => [ playable(3), bandcamp_helpers() ]);
is('helpers excluded from the count',    $r->{track_count}, 3);
is('...classified ep',                   $r->{rel_type},    'ep');

section('a claimed single that resolves to more IS corrected (0.1.88)');
($r) = resolve_row(rel => 'single', resolved => [ playable(3) ]);
is('single + 3 tracks -> ep',            $r->{rel_type},    'ep');
is('...count stored',                    $r->{track_count}, 3);
($r) = resolve_row(rel => 'single', resolved => [ playable(9) ]);
is('single + 9 tracks -> album not ep',  $r->{rel_type},    'album');
# ...but a FAILED resolve must not "correct" it to anything.
($r) = resolve_row(rel => 'single', count => 1, resolved => [ nomatch() ]);
is('failed resolve leaves the single',   $r->{rel_type},    'single');
is('...and its count',                   $r->{track_count}, 1);

section('library rows keep counting live, not from the column');
($r) = resolve_row(source => 'library', resolved => [ playable(7) ]);
is('no stored count for a library row',  $r->{track_count}, undef);

# ---------------------------------------------------------------------------
section('isPlayableTrack — counting REAL tracks, not rows');
# Fixtures reconstructed from LIVE payloads captured over jsonrpc.js on 2026-07-30 against
# four saved Qobuz releases. Two facts they encode, both verified rather than assumed:
#   • Qobuz returns 5-6 INFO rows with every album, and they carry NO `type` key at all
#     (Slim::Control::XMLBrowser emits `type` verbatim when present; these had none), so the
#     old deny-list — not 'text', no weblink — counted every one of them as a track.
#   • The counts below match the server's own `isaudio` flag exactly, because the predicate
#     is a port of the same hasAudio() the server sets that flag with.
# What it cost: adieu - Wanna me is ONE track and was recorded as 6, so Played wanted 4 of a
# possible 1 and the release could never be marked at all. That is the reported bug.
my $count = \&Plugins::ListenLater::Sources::countPlayableTracks;
sub qtrack { my ($n) = @_; return { name => $n, type => 'audio', url => "qobuz://$n.flac", play => "qobuz://$n.flac" } }
sub qinfo  { my ($n) = @_; return { name => $n, url => sub {} } }              # NO type key
sub qacts  { my ($n) = @_; return { name => $n, type => 'actions', url => sub {} } }
my @qobuz_info = (qinfo('Artist: X'), qinfo('Add Release to Qobuz favourites'),
                  qacts('Credits'), qinfo('Music Label: Y'), qinfo('Copyright'));

is('Wanna me: 1 track + 5 info rows',    $count->([ qtrack('t1'), @qobuz_info ]), 1);
is('MY FRIENDS: 3 tracks + 5 info rows', $count->([ (map { qtrack("m$_") } 1..3), @qobuz_info ]), 3);
is('Cost Of Living: 11 + 6 info rows',   $count->([ (map { qtrack("c$_") } 1..11), @qobuz_info, qinfo('Description') ]), 11);
is('Extra Mile: 9 + a SECOND artist row',$count->([ (map { qtrack("e$_") } 1..9), @qobuz_info, qinfo('Artist: Okkervil River') ]), 9);

# Bandcamp's helper rows were already excluded and must stay excluded.
is('bandcamp text + weblink still excluded',
   $count->([ (map { qtrack("b$_") } 1..4),
              { name => 'Download album from …', type => 'text' },
              { name => 'a.bandcamp.com', weblink => 'https://a.bandcamp.com/album/x' } ]), 4);

# The predicate itself, including the parts a guess would have got wrong.
my $is = \&Plugins::ListenLater::Sources::isPlayableTrack;
is('type audio counts',            $is->({ type => 'audio', url => 'x' }), 1);
is('type PLAYLIST counts too',     $is->({ type => 'playlist', url => 'x' }), 1);
is('a play key counts',            $is->({ play => 'x' }), 1);
is('an audio enclosure counts',    $is->({ enclosure => { type => 'audio/mpeg', url => 'x' } }), 1);
is('type audio with NOTHING to play does not',
                                   $is->({ type => 'audio' }), 0);
is('an untyped info row does NOT', $is->({ name => 'Copyright', url => sub {} }), 0);
is('an actions row does NOT',      $is->({ name => 'Credits', type => 'actions' }), 0);
is('a text row does NOT',          $is->({ name => 'no match', type => 'text' }), 0);
is('a weblink does NOT',           $is->({ name => 'buy', weblink => 'http://x' }), 0);
is('a non-hash cannot crash it',   $is->('junk'), 0);

# ---------------------------------------------------------------------------
section('the row glyph follows the MEASURED count, not the label');
# ♫ claims "more than one track" and ♪ claims "one". That is a statement about a NUMBER, so
# it is answered by the number once we have one. The type word beside it stays exactly as
# MusicBrainz or the service wrote it — 'Wanna me' is labelled an EP and holds one track, and
# it keeps saying EP; only the symbol, which is ours, stops contradicting the tracklist.
my $glyph = \&Plugins::ListenLater::Browse::_glyphFor;
my $ONE   = "\x{266a}";   # single note
my $MANY  = "\x{266b}";   # beamed notes
my $POD   = "\x{275d}";

is('measured 1 track -> single note, though labelled EP',
   $glyph->({ source=>'qobuz', rel_type=>'ep', track_count=>1 }), $ONE);
is('measured 3 tracks -> beamed, though labelled single',
   $glyph->({ source=>'qobuz', rel_type=>'single', track_count=>3 }), $MANY);
is('measured 11 tracks -> beamed',
   $glyph->({ source=>'qobuz', rel_type=>'album', track_count=>11 }), $MANY);

# Until it has been measured, the label is all there is.
is('unmeasured single falls back to the label',
   $glyph->({ source=>'qobuz', rel_type=>'single' }), $ONE);
is('unmeasured ep falls back to the label',
   $glyph->({ source=>'qobuz', rel_type=>'ep' }), $MANY);
is('a junk count is ignored, label used',
   $glyph->({ source=>'qobuz', rel_type=>'single', track_count=>'x' }), $ONE);
is('a zero count is ignored, label used',
   $glyph->({ source=>'qobuz', rel_type=>'single', track_count=>0 }), $ONE);

# The two rows that never consult either.
is('a saved individual track is always one note',
   $glyph->({ source=>'qobuz', kind=>'track', track_count=>9 }), $ONE);
is('a podcast episode is always the speech mark',
   $glyph->({ source=>'podcast', kind=>'track' }), $POD);

# ---------------------------------------------------------------------------
section('the row title prints the year once');
# A sibling feed labels its rows "Album (YYYY)" and Material hands that WHOLE label over as
# $ALBUMNAME, so the year lands inside the stored title — then the row appended it again:
# "Shearwater – The New World (2026) (2026)". Reported 2026-07-30.
my $row = sub { Plugins::ListenLater::Browse::_albumRow(undef, $_[0])->{name} };
is('a year already in the title is not repeated',
   $row->({ artist=>'Shearwater', album_title=>'The New World (2026)', year=>2026, track_count=>9 }),
   "Shearwater \x{2013} The New World (2026)");
is('a normal title still gets its year',
   $row->({ artist=>'Cola', album_title=>'Cost Of Living', year=>2026, track_count=>11 }),
   "Cola \x{2013} Cost Of Living (2026)");
is('a DIFFERENT year in the title is left alone',
   $row->({ artist=>'Band', album_title=>'Live (1971)', year=>2026, track_count=>8 }),
   "Band \x{2013} Live (1971) (2026)");
is('no year, nothing appended',
   $row->({ artist=>'Band', album_title=>'Untitled', track_count=>3 }),
   "Band \x{2013} Untitled");

# ---------------------------------------------------------------------------
section('the glyph belongs on the SUBTITLE, never the title');
# Reported 2026-07-30: 0.1.86 put the glyph on the NAME line, ahead of the artist, where it
# reads as part of the album title ("♫ aksfx – Radio: Fourth Space …"). It was never there
# before that release — pre-0.1.86 the name was a plain "Artist – Album (Year)" and there was
# no glyph at all. It belongs with the other metadata about the release, beside the type word
# and the service, which is where the subtitle already says what this row IS.
#
# Pinned on BOTH lines, in both directions: a title assertion alone would pass again if the
# glyph were ever moved back and the subtitle left as it was.
my $line2 = sub { Plugins::ListenLater::Browse::_albumRow(undef, $_[0])->{line2} };
my $rel   = { artist=>'aksfx', album_title=>'Radio: Fourth Space', year=>2026,
              source=>'qobuz', rel_type=>'album', track_count=>9 };
is('title carries NO glyph',    $row->($rel),   "aksfx \x{2013} Radio: Fourth Space (2026)");
is('subtitle LEADS with it',    $line2->($rel), "$MANY PLUGIN_LL_TYPE_ALBUM \x{00b7} Qobuz");

my $trk    = sub { Plugins::ListenLater::Browse::_trackRow(undef, $_[0]) };
my $trkRec = { artist=>'Four Tet', track_title=>'Into Dust', album_title=>'Three Drums',
               source=>'qobuz', kind=>'track' };
is('track title carries NO glyph', $trk->($trkRec)->{name}, "Four Tet \x{2013} Into Dust");
is('track subtitle LEADS with it', $trk->($trkRec)->{line2},
   "$ONE PLUGIN_LL_TYPE_TRACK \x{00b7} Three Drums \x{00b7} Qobuz");

# ---------------------------------------------------------------------------
section('hasDirectAlbumRef — is a tracklist CHEAP to fetch for this row?');
# One album call, or a whole service SEARCH? That is what decides whether optional
# background work is worth doing (Plugin::_verifyRelease) and which replay route
# buildPlayableItems takes. It lives in one sub because those two had drifted: the gate
# asked "is there an album id", which is the wrong question for Bandcamp, whose get_album
# scrapes the album PAGE url — so an id-only Bandcamp row costs the exact search the gate
# was written to avoid.
my $direct = \&Plugins::ListenLater::Sources::hasDirectAlbumRef;
is('qobuz with an album id',        $direct->({ source => 'qobuz',    ref => { album_id => 'abc' } }), 1);
is('qobuz with none',               $direct->({ source => 'qobuz',    ref => {} }), 0);
is('tidal with an album id',        $direct->({ source => 'tidal',    ref => { album_id => '123' } }), 1);
is('deezer via passthrough',        $direct->({ source => 'deezer',   ref => { passthrough => { album_id => '9' } } }), 1);
is('bandcamp with the PAGE url',    $direct->({ source => 'bandcamp', ref => { album_url => 'https://a.bandcamp.com/album/x' } }), 1);
is('bandcamp with only an id: NO',  $direct->({ source => 'bandcamp', ref => { album_id => '1234567' } }), 0);
is('bandcamp with neither',         $direct->({ source => 'bandcamp', ref => {} }), 0);
is('library is always direct',      $direct->({ source => 'library',  ref => {} }), 1);
is('a ref-less row cannot crash it',$direct->({ source => 'qobuz' }), 0);

printf "\n%d passed, %d failed\n", $pass, $fail;
exit($fail ? 1 : 0);
