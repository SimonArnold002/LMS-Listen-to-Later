#!/usr/bin/env perl
# Regression tests for the ADD PATH end to end: a Material custom action arrives at
# Plugin::_addCtxCommand and a row lands in SQLite. What goes in, what comes out.
#
# WHY THIS EXISTS
#
# This was the one path in the plugin with no coverage at all, and it is the path the 0.1.89
# '&tc=' bug walked straight through: the favurl parsing had a 24-check suite, the release
# types had their own, the DB had its own — and none of them joined the two ends, so a
# handshake that never delivered anything looked fully tested. Everything here is asserted on
# the STORED ROW, because that is what the rest of the plugin actually reads.
#
# It needs no service and no LMS: the whole path asks exactly three things of the request
# (client, getParam, setStatusDone), so a fake one drives it. With client => undef the two
# background jobs (_verifyRelease, showBriefly) return on their first guard, which keeps this
# a test of the add itself rather than of everything it kicks off. An add carrying '&rt='
# takes the immediate insert path; without it the add would block on _classifyThenAdd, which
# needs a service and belongs in t_reltype.pl.
use strict;
use warnings;
use FindBin;
use File::Temp qw(tempdir);
require "$FindBin::Bin/t_stubs.pl";

my $dir = tempdir(CLEANUP => 1);
Slim::Utils::Prefs::set_test_pref_ns('server', 'cachedir', $dir);

ll_require('DB', 'Sources', 'Podcast', 'Browse', 'Played', 'Plugin');

# The add is gated on the service being REPLAYABLE — Sources::_serviceCan asks whether that
# plugin is installed and exposes its album call (Plugin::_isReplayableSource, 0.1.51: nothing
# unplayable is ever stored). None are installed here, so without these the gate rejects every
# streaming add and each assertion below would "pass" against an empty database. Declaring the
# one method each is checked for is the whole stub — no behaviour is faked, and the rejection
# cases at the end prove the gate is still live.
{
    no strict 'refs';
    *{'Plugins::Qobuz::Plugin::QobuzGetTracks'} = sub { };
    *{'Plugins::TIDAL::Plugin::getAlbum'}       = sub { };
    *{'Plugins::Deezer::Plugin::getAlbum'}      = sub { };
    *{'Plugins::Bandcamp::Plugin::get_album'}   = sub { };
}

my ($pass, $fail) = (0, 0);
sub is {
    my ($desc, $got, $want) = @_;
    my $ok = (!defined $got && !defined $want)
          || (defined $got && defined $want && "$got" eq "$want");
    $ok ? $pass++ : $fail++;
    printf "%s %-58s got=%-14s want=%s\n", ($ok ? 'ok  ' : 'FAIL'), $desc,
        (defined $got ? "'$got'" : '(undef)'), (defined $want ? "'$want'" : '(undef)');
}
sub section { printf "\n== %s\n", $_[0] }

# The request surface the add path uses. Six methods, taken from a sweep of every
# `$request->` in Plugin.pm — the reject path reports through addResult, which a sweep of
# just _addCtxCommand/_finishAlbumAdd misses.
{
    package FakeRequest;
    sub new      { my ($c, %p) = @_; return bless { p => \%p, done => 0, res => {} }, $c }
    sub getParam { return $_[0]{p}{ $_[1] } }
    sub client   { return undef }                 # no player: background jobs no-op
    sub setStatusDone       { $_[0]{done}++ }
    sub setStatusProcessing { $_[0]{processing}++ }
    sub addResult           { $_[0]{res}{ $_[1] } = $_[2] }
    sub addResultLoop       { push @{ $_[0]{loop} }, [ @_[1 .. $#_] ] }
}

# Run one add and hand back the row it stored.
sub add {
    my (%params) = @_;
    my $before = Plugins::ListenLater::DB::list('later', 'added');
    Plugins::ListenLater::Plugin::_addCtxCommand(FakeRequest->new(%params));
    my $after = Plugins::ListenLater::DB::list('later', 'added');
    return undef if @$after == @$before;
    my %seen = map { $_->{id} => 1 } @$before;
    my ($new) = grep { !$seen{ $_->{id} } } @$after;
    return $new;
}

# A real LBF favurl: Qobuz album id + the private handshake params.
sub lbf {
    my (%o) = @_;
    my $u = 'qobuz://album:' . ($o{id} // 'dmuizydvpcxsy');
    my @q;
    push @q, 'a='  . ($o{artist} // 'Wet%20Leg');
    push @q, 'y='  . $o{year} if $o{year};
    push @q, 'rt=' . $o{rt}   if $o{rt};
    push @q, 'tc=' . $o{tc}   if defined $o{tc};
    return @q ? "$u?" . join('&', @q) : $u;
}

# ---------------------------------------------------------------------------
section("'&tc=' settles the TYPE but never becomes Played's total");
# The count is a CATALOGUE figure from the sibling (it reads it off the service's own album
# hash), so it can exceed what's playable in this region. Using it as the total would set the
# Played bar at 60% of a number some users can never reach — the bug the Qobuz path had.
# It is still the only zero-call way to disprove a claimed 'single' at insert.

my $r = add(name => 'Moisturizer', favurl => lbf(rt => 'single', tc => 3), svc => 'qobuz');
is('a 3-track MB "single" is stored as an ep', $r->{rel_type},    'ep');
is('...and stores NO total',                   $r->{track_count}, undef);
is('...artist came off the favurl',            $r->{artist},      'Wet Leg');

$r = add(name => 'Chaise Longue', favurl => lbf(id => 'aaa', rt => 'single', tc => 1), svc => 'qobuz');
is('a real 1-track single stays a single',     $r->{rel_type},    'single');
is('...and still stores no total',             $r->{track_count}, undef);

$r = add(name => 'Big Album', favurl => lbf(id => 'bbb', rt => 'single', tc => 12), svc => 'qobuz');
is('a 12-track "single" -> album, not ep',     $r->{rel_type},    'album');
is('...no total',                              $r->{track_count}, undef);

$r = add(name => 'No Count', favurl => lbf(id => 'ccc', rt => 'single'), svc => 'qobuz');
is('no tc: the claim stands (nothing to check)', $r->{rel_type},  'single');

# The reason the type must be right AT INSERT: a claimed single is matched against an
# already-saved track of the same name, and a wrong 'single' silently drops the whole add.
# No background correction can repair a row that was never inserted.
section('why the insert-time check matters: the cross-kind single dedupe');
Plugins::ListenLater::DB::add({
    source => 'qobuz', kind => 'track', artist => 'Wet Leg', track_title => 'Catch These Fists',
    album_title => '', ref_kind => 'search', ref => {},
}, 'later');

$r = add(name => 'Catch These Fists', favurl => lbf(id => 'ddd', rt => 'single', tc => 4), svc => 'qobuz');
is('disproved single is NOT eaten by the track', (defined $r ? $r->{rel_type} : 'DROPPED'), 'ep');

$r = add(name => 'Catch These Fists', favurl => lbf(id => 'eee', rt => 'single', tc => 1), svc => 'qobuz');
is('a REAL single IS deduped against it',        (defined $r ? 'inserted' : 'deduped'), 'deduped');

# ---------------------------------------------------------------------------
section('the favurl handshake reaches the stored row');
$r = add(name => 'Will Sheff - Extra Mile', svc => 'qobuz',
         favurl => 'qobuz://album:fff?al=Extra%20Mile&a=Will%20Sheff&y=2026&rt=album');
is('&al= wins over the polluted $TITLE',       $r->{album_title}, 'Extra Mile');
is('&a= gives the artist',                     $r->{artist},      'Will Sheff');
is('&y= gives the year',                       $r->{year},        2026);
is('&rt= gives the type',                      $r->{rel_type},    'album');
is('source read from the favurl scheme',       $r->{source},      'qobuz');

# The dedupe key is built from artist|album|year — the cleaned values, not the raw label.
is('...so the dedupe key is clean',
   (($r->{dedupe_key} // '') =~ /^will sheff\|extra mile\|2026$/ ? 'clean' : $r->{dedupe_key}), 'clean');

section('a native favurl still adds normally');
$r = add(name => 'Revolver', artist => 'The Beatles', svc => 'deezer', year => '1966',
         favurl => 'deezer://album:301234?rt=album');
is('deezer add stored',                        $r->{source},      'deezer');
is('...album id kept for replay',              $r->{ref}{album_id}, '301234');
is('...year from the param',                   $r->{year},        1966);
is('...and no total',                          $r->{track_count}, undef);

section('an UNKNOWN type does not insert synchronously (0.1.74-0.1.80)');
# The one add that waits. With no '&rt=' and no library id there is no label to show, and a
# row that appears as "Album" and flips to EP/Single on the next refresh is worse than a
# moment's wait — so this defers to _classifyThenAdd (async, service-backed) instead of
# inserting a guess. An ASSERTED type does NOT wait (decided 2026-07-29); that's the cases
# above, which all insert here and now.
Slim::Utils::Timers::clear();
is('no row inserted yet',
   (defined add(name => 'Unknown Thing', artist => 'Someone', svc => 'deezer',
                favurl => 'deezer://album:999') ? 'inserted' : 'deferred'), 'deferred');
is('...but the add is not dropped — a timeout is armed',
   (scalar Slim::Utils::Timers::armed() ? 'armed' : 'none'), 'armed');

section('a year the ADD did not carry is filled in before the row is stored');
# The classify-first path (an unknown type — i.e. a plain streaming browse row, which is
# exactly the add that has no year) fetches the service's album object anyway, so the year
# rides back with the type. Filling it BEFORE the insert matters: DB::add builds the dedupe
# key from artist|album|year, so a year arriving later would leave the key yearless.
{
    no warnings qw(redefine once);
    local *Plugins::ListenLater::Sources::classifyRelType = sub {
        my ($cl, $src, $aid, $rec, $cb, $claim) = @_;
        return $cb->('album', 9, 0, 2026);          # type, count, provisional, YEAR
    };
    my $r = add(name => 'New Wave Graveyard', artist => 'Josh Da Costa', svc => 'qobuz',
                favurl => 'qobuz://album:zzz1');
    is('the row is stored',              (defined $r ? 'yes' : 'no'), 'yes');
    is('...with the backfilled year',    $r->{year}, 2026);
    is('...and a key that carries it',   $r->{dedupe_key}, 'josh da costa|new wave graveyard|2026');
    is('...and the real count',          $r->{track_count}, 9);
}
{
    # A year the add DID carry is never replaced by the service's (reissue vs original).
    no warnings qw(redefine once);
    local *Plugins::ListenLater::Sources::classifyRelType = sub { $_[4]->('album', 9, 0, 2026) };
    my $r = add(name => 'Sweet F.A.', artist => 'Love and Rockets', svc => 'qobuz',
                year => '1996', favurl => 'qobuz://album:zzz2');
    is('the add wins over the service',  $r->{year}, 1996);
}
{
    # No year anywhere is still a valid row — it just keys without one, as before.
    no warnings qw(redefine once);
    local *Plugins::ListenLater::Sources::classifyRelType = sub { $_[4]->('album', 4, 0, undef) };
    my $r = add(name => 'Open Soul', artist => "Tomorrow's People", svc => 'qobuz',
                favurl => 'qobuz://album:zzz3');
    is('no year: still stored',          (defined $r ? 'yes' : 'no'), 'yes');
    # NB the apostrophe normalises to a SPACE ("tomorrow s people"), not away — DB::_norm
    # replaces every non-alphanumeric run with one. Pinned here so it can't drift silently.
    is('...keyed without one',           $r->{dedupe_key}, 'tomorrow s people|open soul|');
}

section('the EXACT favurl ListenBrainz Fresh Releases 0.9.144 emits');
# Copied verbatim from LBF's own _attachFavUrl output, not hand-written — the two strings
# below are what that sub produces for a Qobuz auto-match and a pinned Bandcamp match. LBF's
# tools/t_ll_handshake.pl checks the same round trip against both repos' live source; this
# checks the half that only a database can prove: what actually lands in the stored row and
# its dedupe key. Param ORDER here is LBF's real order (cover/b, a, al, y, rt), which differs
# from the hand-built cases above — worth pinning, since every param is stripped by a regex
# carrying its own leading delimiter and order is exactly what that has to survive.
# NB a DIFFERENT release from the &al= case earlier in this file — the same artist/album/year
# would (correctly) dedupe against it and store nothing, leaving these three asserting on an
# undef row.
$r = add(name => 'Cost Of Living Adjustment', svc => 'qobuz',
         favurl => 'qobuz://album:ggg?cover=https%3A%2F%2Fstatic.qobuz.com%2Fimages%2Fcovers%2F83%2F16%2Fx_600.jpg'
                 . '&a=Cola&al=Cost%20Of%20Living%20Adjustment&y=2026&rt=album');
is('qobuz: album title from &al=',             $r->{album_title}, 'Cost Of Living Adjustment');
is('...artist from &a=',                       $r->{artist},      'Cola');
is('...real cover art, not the service logo',
   (($r->{artwork} // '') =~ m{^https://static\.qobuz\.com/} ? 'cover' : $r->{artwork}), 'cover');

# The qualifier that matters. A trailing "(Album)" is ALREADY handled — the blocklist a few
# lines below in _addCtxCommand has stripped it since 0.1.35 — so a case built on that one
# would pass with or without the handshake and prove nothing. "(Deluxe Edition)" is NOT on
# that list, and today it reaches the stored title and the dedupe key with it.
$r = add(name => 'The Landfill (Deluxe Edition)', svc => 'bandcamp',
         favurl => 'bandcamp://album:57?b=https%3A%2F%2Ff4.bcbits.com%2Fimg%2Fa123_16.jpg'
                 . '%7Chttps%3A%2F%2Ffruitbats.bandcamp.com%2Falbum%2Fthe-landfill'
                 . '&a=Fruit%20Bats&al=The%20Landfill&y=2026&rt=album');
is('bandcamp: an off-blocklist qualifier does NOT reach the row', $r->{album_title}, 'The Landfill');
is('...and so the dedupe key is clean too',    $r->{dedupe_key}, 'fruit bats|the landfill|2026');
is('...the page url survives for exact replay',
   (($r->{ref}{album_url} // '') =~ m{fruitbats\.bandcamp\.com} ? 'kept' : 'LOST'), 'kept');
is('...as does the cover half of the same param',
   (($r->{artwork} // '') =~ m{^https://f4\.bcbits\.com/} ? 'cover' : $r->{artwork}), 'cover');

# THE POINT OF THE WHOLE HANDSHAKE. The same record arriving from somewhere that labels it
# plainly must be recognised as the one already saved. Without '&al=' the row above stores
# "The Landfill (Deluxe Edition)", which keys as "the landfill deluxe edition" — so this
# second add would NOT match it and would silently become a duplicate row.
# NB this cuts both ways and is the deliberate trade: a genuine deluxe edition and the
# standard one now share a key and collapse into one row. Right here (LBF matched both to
# the same MusicBrainz release) but worth knowing it is a behaviour change, not just tidying.
is('the same album added plainly is now a DUPLICATE, not a second row',
   (defined add(name => 'The Landfill', artist => 'Fruit Bats', svc => 'bandcamp', year => '2026',
                favurl => 'bandcamp://album:57?rt=album') ? 'stored again' : 'deduped'),
   'deduped');

section("0.1.92 — the SERVICE label is kept so Played can still find the row");
# THE HOLE '&al=' OPENED. The handshake above is right about the title, but MusicBrainz keeps
# a release's distinguisher OUTSIDE the title: all four American Football LPs are titled
# "American Football" and "LP2"/"LP3" live in MB's `disambiguation`, which neither the
# ListenBrainz feed nor the favurl carries. So '&al=' stores the bare shared name while the
# service — and therefore the PLAYING TRACK — says "American Football (LP2)".
#
# That matters because Played's streaming path matches on the album TITLE alone (there is no
# album-id anchor in _matchRecord), and DB::_norm deliberately KEEPS "(LP2)" so the dedupe key
# can tell editions apart. Bare name stored + qualified name playing = never marked Played,
# silently: the album plays perfectly and just never leaves the list.
#
# The fix keeps BOTH — MB's name for display and the key, the service's label for matching.
{
    package FakeTrack;
    sub new        { my ($c, %p) = @_; return bless {%p}, $c }
    sub remote     { 1 }
    sub artistName { return $_[0]{artist} }
    sub albumname  { return $_[0]{album} }
}

$r = add(name => 'American Football (LP2)', svc => 'qobuz',
         favurl => 'qobuz://album:lp2?al=American%20Football&a=American%20Football&y=2016&rt=album');
is('&al= still wins for the stored title',     $r->{album_title},     'American Football');
is('...and the service label is kept beside it', $r->{ref}{svc_title}, 'American Football (LP2)');

# The play. The track reports what the SERVICE calls the release, not what MusicBrainz does.
my $played = Plugins::ListenLater::Played::_matchRecord(
    undef,
    FakeTrack->new(artist => 'American Football', album => 'American Football (LP2)'),
    'qobuz://12345.flac');
is('a play of the QUALIFIED title finds the row',
   (defined $played ? $played->{id} : 'NO MATCH'), $r->{id});

# ...and the unqualified spelling still works, via the original title lookup.
$played = Plugins::ListenLater::Played::_matchRecord(
    undef,
    FakeTrack->new(artist => 'American Football', album => 'American Football'),
    'qobuz://12345.flac');
is('a play of the BARE title still finds it too',
   (defined $played ? $played->{id} : 'NO MATCH'), $r->{id});

# The guard that keeps this from being a loose title match: same label, different artist.
$played = Plugins::ListenLater::Played::_matchRecord(
    undef,
    FakeTrack->new(artist => 'Some Other Band', album => 'American Football (LP2)'),
    'qobuz://12345.flac');
is('...but NOT for a different artist',
   (defined $played ? 'WRONGLY MATCHED' : 'no match'), 'no match');

# Nothing is stored when the label adds nothing — an identical label is noise in every row.
$r = add(name => 'Cost Of Living Adjustment', svc => 'qobuz',
         favurl => 'qobuz://album:cola?al=Cost%20Of%20Living%20Adjustment&a=Cola&y=2026&rt=album');
is('an identical label is not stored',         $r->{ref}{svc_title}, undef);

# And it must not disturb what '&al=' was introduced to fix: the key still comes from the
# CLEAN title, so a deluxe and a standard edition still collapse into one row.
$r = add(name => 'Digital Ash in a Digital Urn (Remastered)', svc => 'qobuz',
         favurl => 'qobuz://album:ash?al=Digital%20Ash%20in%20a%20Digital%20Urn&a=Bright%20Eyes&y=2005&rt=album');
is('the dedupe key still ignores the label',   $r->{dedupe_key},
   'bright eyes|digital ash in a digital urn|2005');

section('unreplayable sources are refused, not stored');
is('an unsupported service is rejected',
   (defined add(name => 'Something', svc => 'spotty', favurl => 'spotify://album:x') ? 'stored' : 'rejected'),
   'rejected');
is('an unidentifiable row is rejected',
   (defined add(name => 'W/C 22 June', svc => 'material-skin-client',
                image => 'plugins/ListenBrainz/weekly.png') ? 'stored' : 'rejected'),
   'rejected');

printf "\n%d passed, %d failed\n", $pass, $fail;
exit($fail ? 1 : 0);
