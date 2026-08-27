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
sub like {
    my ($desc, $got, $re) = @_;
    my $ok = defined $got && $got =~ $re;
    $ok ? $pass++ : $fail++;
    printf "%s %-58s got=%s\n", ($ok ? 'ok  ' : 'FAIL'), $desc,
        (defined $got ? "'$got'" : '(undef)');
}
sub section { printf "\n== %s\n", $_[0] }

# The request surface the add path uses. Six methods, taken from a sweep of every
# `$request->` in Plugin.pm — the reject path reports through addResult, which a sweep of
# just _addCtxCommand/_finishAlbumAdd misses.
{
    package FakeRequest;
    # `_client` is pulled OUT of the params (it isn't one) — pass it only for the Now
    # Playing cases, since a live client is what opens the now-playing fallback.
    sub new      { my ($c, %p) = @_; my $cl = delete $p{_client};
                   return bless { p => \%p, cl => $cl, done => 0, res => {} }, $c }
    sub getParam { return $_[0]{p}{ $_[1] } }
    sub client   { return $_[0]{cl} }             # undef by default: background jobs no-op
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

# The reject is SILENT to the user by necessity (Material renders no toast for a custom-action
# command), so this one warn line is the entire trace it leaves — and triage of "Add did
# nothing" is driven by it. Since 0.1.96 an unrecognised container verb leaves $source an
# EMPTY STRING, which '// ?' does not catch, so the line said "unsupported source ''" and
# named neither the source nor the surface. Assert on what it actually prints.
sub reject_line {
    my (%p) = @_;
    Slim::Utils::Log::clear();
    add(%p);
    my ($l) = grep { /rejected add/ } Slim::Utils::Log::lines();
    return $l // '(nothing logged)';
}
like('an empty source is named as such, not as an empty quote',
     reject_line(name => 'Darko.Audio #123', svc => 'favorites',
                 image => 'https://darko.audio/ep123.jpg'),
     qr/unsupported source \(none identified\)/);
like('...and the container verb is named, since that IS the surface',
     reject_line(name => 'Darko.Audio #123', svc => 'favorites',
                 image => 'https://darko.audio/ep123.jpg'),
     qr/via container 'favorites'/);
like('a source we DID identify is still quoted as before',
     reject_line(name => 'Something', svc => 'spotify', favurl => 'spotify://album:x'),
     qr/unsupported source 'spotify'/);
like('...and an add with no container verb claims none',
     reject_line(name => 'Mystery Row'),
     qr/unsupported source \(none identified\) \(Mystery Row\)/);

section('a home-shelf browse verb is not a service name (the QobuzExtrasqobuz bug)');
# Material's $SERVICE is the browse COMMAND (`data.params[1][0]`), and on a HOME SHELF that
# command is the home-extra id — verified live: the stock Qobuz plugin registers
# `3rdparty_QobuzExtrasqobuz` ("Qobuz"), and `["QobuzExtrasqobuz","items",…]` returns the
# identical 11-item Qobuz app menu. So entering Qobuz from the home screen rather than Apps
# sends a svc that merely LOOKS like a service tag. The old `^[a-z0-9]+$` shape test accepted
# it, made $svc truthy, and short-circuited the `||` before the cover sniff — which had the
# right answer all along, in the static.qobuz.com URL.
my $qcover = '/imageproxy/https%3A%2F%2Fstatic.qobuz.com%2Fimages%2Fcovers%2Fve%2Fdj%2Fvafgxaiq1djve_600.jpg/image.jpg';

# A favurl-less browse row carries no '&rt=', so this path goes through _classifyThenAdd and
# only inserts once the service answers. Qobuz answers from its album OBJECT, so stub that one
# call and let it call back inline — everything else on the path stays real, including the
# album id, which _addCtxCommand recovers from the cover URL and passes to getAlbum.
{
    no strict 'refs';
    *{'Plugins::Qobuz::Plugin::getAPIHandler'} = sub { bless {}, 'FakeQobuzAPI' };
    package FakeQobuzAPI;
    sub can     { my ($s,$m) = @_; return $m eq 'getAlbum' ? \&getAlbum : undef }
    sub getAlbum { my ($s,$cb,$id) = @_; $cb->({ release_type => 'album', tracks_count => 12 }) }
}

$r = add(name => 'Hazel Eyes (Hi-Res)', artist => 'Sam Smith',
         svc => 'QobuzExtrasqobuz', image => $qcover);
is('a home-shelf verb still resolves to the service', ($r ? $r->{source} : 'REJECTED'), 'qobuz');
# Not just stored under the right name — the cover is also where the album id comes from, so
# this proves the whole downstream identity survived rather than merely the gate passing.
is('and the album id is still recovered',
   ($r ? ($r->{ref}{album_id} // 'none') : 'REJECTED'), 'vafgxaiq1djve');

# The Apps route sends the bare tag for the very same row; it must be untouched.
$r = add(name => 'Hazel Eyes 2 (Hi-Res)', artist => 'Sam Smith', svc => 'qobuz', image => $qcover);
is('the Apps browse verb is unaffected',   ($r ? $r->{source} : 'REJECTED'), 'qobuz');

# Its HYPHENATED sibling shelves always worked — they failed the shape test and so fell through
# to the cover sniff by accident. That accident is now the deliberate path; pin it, because it
# is the evidence that this was never a Material bug to wait on.
$r = add(name => 'Hazel Eyes 3 (Hi-Res)', artist => 'Sam Smith',
         svc => 'QobuzExtrasnew-releases-full', image => $qcover);
is('a hyphenated shelf verb keeps working', ($r ? $r->{source} : 'REJECTED'), 'qobuz');

# A REAL service name still wins over the cover, even when the two disagree and the named one
# can't be replayed. knownSource is not a replayability test — spotify belongs in it precisely
# so this add is refused under its own name instead of being re-sniffed into a qobuz row.
is('a known-but-unsupported svc is not re-sniffed from the cover',
   (defined add(name => 'Wrong Service', artist => 'X', svc => 'spotify', image => $qcover)
        ? 'stored' : 'rejected'),
   'rejected');

# And an unrecognised verb with nothing to fall back on is still refused — the 0.1.53 rule.
# The existing case uses a hyphenated svc, which the OLD shape test also rejected; this one is
# all-alphanumeric, so only knownSource can be what turns it away.
is('an all-alphanumeric unknown verb with no service cover is rejected',
   (defined add(name => 'New Releases for You', svc => 'LBFForYou',
                image => 'plugins/ListenBrainz/weekly.png') ? 'stored' : 'rejected'),
   'rejected');

section('an add from OUR OWN surfaces is refused by the command, not just hidden');
# Every row in our list view / home shelf is ALREADY saved, so re-adding one bounces a Played
# album back to Listen Later. The empty 'listenlater-*'/'LLHome-*' categories hide the button,
# but a written category is not a gate — Material caches customactions.json (the 0.1.57
# post-upgrade window), and a home shelf's $SERVICE is the shelf id, which those categories
# were never certain to match.
#
# This used to be gated by ACCIDENT: the old shape test made svc='LLHome' the $source, and an
# unreplayable source was rejected downstream. knownSource leaves it empty so a home-shelf row
# can be identified from its cover — and OUR cards carry the original streaming cover, so the
# sniff answers 'qobuz' and the re-add went through. That is what the reject list closes.
# Every case below uses a DISTINCT title on purpose. Sharing one lets the cross-kind dedupe
# drop the second add, which reads as "rejected" here and would let these pass with the guard
# removed — anti-tested, and that is exactly how it failed.
is('a card in our own home shelf is not re-addable, cover or no cover',
   (defined add(name => 'Own Shelf Album', artist => 'Sam Smith',
                svc => 'LLHome', image => $qcover) ? 'stored' : 'rejected'),
   'rejected');
is('...nor a row in the plugin list view',
   (defined add(name => 'Own List Album', artist => 'Sam Smith',
                svc => 'listenlater', image => $qcover) ? 'stored' : 'rejected'),
   'rejected');
# A stale actions.json outlives the rename, so the pre-rebrand spellings must be refused too.
is('...nor either pre-rebrand spelling',
   join(',', map {
       defined add(name => "Pre-rebrand $_", artist => 'Sam Smith',
                   svc => $_, image => $qcover) ? 'stored' : 'rejected'
   } qw(LtLHome listentolater)),
   'rejected,rejected');
# The guard sits ahead of EVERY branch, so neither a track-shaped favurl nor a kind:podcast
# category can route around it — both are rows that are already in the list as well.
is('a track row in our own surface takes the same answer',
   (defined add(name => 'Own Shelf Track', svc => 'LLHome', kind => 'track',
                favurl => 'qobuz://12345.flac') ? 'stored' : 'rejected'),
   'rejected');
# On the podcast branch the assertion has to be the REASON, not the outcome: with no feeds
# subscribed in this harness the episode is refused anyway, so "rejected" alone proves nothing
# about the guard. The reject line names which gate turned it away.
like('...and a saved podcast episode is turned away by THIS gate, not the empty-feeds one',
     reject_line(name => 'Own Shelf Episode', svc => 'LLHome', kind => 'podcast',
                 image => 'https://darko.audio/ep123.jpg'),
     qr/row is already in Listen Later/);
like('the log says the row was already ours, not that the source was unsupported',
     reject_line(name => 'Own Shelf Album 2', artist => 'Sam Smith',
                 svc => 'LLHome', image => $qcover),
     qr/row is already in Listen Later.*via container 'LLHome'/);
# Positive control, and the same exact-match discipline knownSource is held to: the list is of
# NAMES, never prefixes. A foreign command that merely starts with one of ours is not ours, and
# widening the test would quietly start refusing another plugin's adds.
is('a verb that merely BEGINS with one of ours is not treated as ours',
   (add(name => 'Hazel Eyes 4 (Hi-Res)', artist => 'Sam Smith',
        svc => 'LLHomeworkHelper', image => $qcover) || {})->{source} // 'REJECTED',
   'qobuz');

section('the Now Playing fallback is for Now Playing, not for every empty source');
# The fallback recovers the source from the PLAYING track when an add arrives with nothing to
# identify it. It has to fail OPEN on the match guard, because a streaming Track row exposes
# no album/artist to match against (Qobuz/Tidal serve that dynamically) — so what stops it
# adopting an unrelated playing track is the gate at the call site, not the guard inside it.
#
# 0.1.96 widened that hole: `svc` is now only believed when it NAMES a service, so every
# CONTAINER command that isn't one (favorites, search, bbcsounds, a home-shelf id) leaves
# $source empty — which is exactly what opens the gate. A podcast episode added from
# Favourites while a Qobuz track played would be stored as a qobuz album. The gate therefore
# also requires that NO svc arrived at all: Material's Now Playing action ($trackCmd) carries
# no `svc:` param, so a populated one means a browse row, not the Now Playing panel.
{
    package FakeSong;
    sub new          { my ($c, $t) = @_; return bless { t => $t }, $c }
    sub track        { return $_[0]{t} }
    sub currentTrack { return $_[0]{t} }
    package FakeNPTrack;
    # A streaming track as LMS really holds one: a service play url and NO metadata —
    # ->albumname/->artistName come back empty (confirmed live on a qobuz:// track).
    sub new        { my ($c, %p) = @_; return bless {%p}, $c }
    sub url        { return $_[0]{url} }
    sub album      { return undef }
    sub albumname  { return '' }
    sub artistName { return '' }
    # The one thing a streaming Track DOES answer. Named here so the track-path cases below
    # can tell "stored the playing song" from "stored the row that was tapped".
    sub title      { return $_[0]{title} }
    package FakeClient;
    sub new        { my ($c, $s) = @_; return bless { s => $s }, $c }
    sub playingSong { return $_[0]{s} }
    sub id          { return 'aa:bb:cc:dd:ee:ff' }
}
my $playing = FakeClient->new(FakeSong->new(
    FakeNPTrack->new(url => 'qobuz://12345.flac', title => 'TRACK ONE (playing)')));

# The reported shape: a podcast episode from Favourites. No favurl, no id, a container verb
# that is not a service, an image no cover sniff recognises — and a Qobuz track playing.
$r = add(_client => $playing,
         name   => 'Darko.Audio podcast #123',
         artist => 'Darko.Audio',
         svc    => 'favorites',
         image  => 'https://darko.audio/wp-content/uploads/ep123.jpg');
is('a browse row does NOT adopt the playing track',
   (defined $r ? "STORED as $r->{source}" : 'rejected'), 'rejected');

# ...and the fallback itself still works, or the line above would pass by simply being off.
# No svc at all + a live client = the Now Playing panel, which is what it exists for.
$r = add(_client => $playing, name => 'Moisturizer II (2025)', artist => 'Wet Leg');
is('a real Now Playing add still recovers the source',
   (defined $r ? $r->{source} : 'REJECTED'), 'qobuz');
is('...with the year stripped off Material\'s "Album (YYYY)" label', ($r ? $r->{year} : undef), 2025);
is('...and the label itself cleaned', ($r ? $r->{album_title} : undef), 'Moisturizer II');

# ---------------------------------------------------------------------------
section('the TRACK path has the same fallback, and needs a gate of its own');
# _nowPlayingTrackFallback has NO match guard by design, so the call-site gate is the only
# thing standing between a tapped row and whatever is playing. The album path's "no svc"
# test does not transfer on its own: `queue-track` and the Now Playing panel are the SAME
# lmscommand ($trackCmd), so a queue row also arrives with no svc. The track id is what
# separates them — the Now Playing item has neither id nor favurl to substitute, while any
# real row carries one.

# Tap "Add" on a queue row while row 1 plays, with an id that resolves to NOTHING on this
# server (a stale row from a browser tab whose queue has moved on). There is no play url to
# be had, and adopting the playing song for it is the bug — so it is refused.
$r = add(_client => $playing, kind => 'track',
         trackname => 'Track Seven (tapped)', name => 'Some Album', artist => 'The Band',
         trackid => '-1', favurl => '');
is('a tapped row whose id resolves to nothing does NOT adopt the playing song',
   (defined $r ? "STORED '" . ($r->{track_title} // '') . "'" : 'rejected'), 'rejected');

# An online track row whose service sent no favurl. Here svc IS populated, so this one the
# album path's test would have caught — assert it anyway, since it is a second live shape.
$r = add(_client => $playing, kind => 'track',
         trackname => 'Some Stream', artist => 'Someone', svc => 'qobuz', favurl => '');
is('...nor does an online-track row with a container verb',
   (defined $r ? "STORED '" . ($r->{track_title} // '') . "'" : 'rejected'), 'rejected');

# ...and the fallback still works, or both assertions above pass with it simply switched off.
# No svc, no trackid, no favurl, a live client: the Now Playing panel.
$r = add(_client => $playing, kind => 'track',
         name => 'Moisturizer II', artist => 'Wet Leg');
is('a real Now Playing TRACK add still recovers the playing song',
   ($r ? $r->{track_title} : 'REJECTED'), 'TRACK ONE (playing)');
is('...as a track row, playable by the recovered url',
   ($r ? "$r->{kind}|$r->{ref}{url}" : undef), 'track|qobuz://12345.flac');

# ---------------------------------------------------------------------------
section('a REMOTE queue row is resolved by its id, not refused for having one');
# The gate above rejects on the PRESENCE of a track id, and a streaming queue row is the one
# shape that arrives with an id and nothing else: Material builds the row id as
# "track_id:"+i.id and substitutes it into $TRACKID, while queue rows carry no presetParams
# at all, so $FAVURL is empty. LMS gives a remote track a NEGATIVE id (verified live: the
# status query serves id=-94606967849352 for qobuz://420282127.flac), so refusing to resolve
# a non-positive id made every remote queue row unaddable — including the playing one.
# Resolve it instead: row 7 stores row 7, and the gate is untouched.
Slim::Schema::add_test_track(
    id => -94606967849352, url => 'qobuz://420282127.flac',
    title => 'Cleveland', artist => 'Squirrel Flower',
    album => 'Say a Prayer to the Gods of Getting Going');

$r = add(_client => $playing, kind => 'track',
         trackname => 'Cleveland', name => 'Say a Prayer to the Gods of Getting Going',
         artist => 'Squirrel Flower', trackid => '-94606967849352', favurl => '');
is('a remote queue row is stored', (defined $r ? 'stored' : 'REJECTED'), 'stored');
# The decisive one: TRACK ONE (playing) is what the now-playing fallback would have supplied.
is('...as the row that was TAPPED, not the song that was playing',
   ($r ? $r->{track_title} : undef), 'Cleveland');
is('...with the TAPPED row\'s play url',
   ($r ? $r->{ref}{url} : undef), 'qobuz://420282127.flac');
# The other half of the same edit: the id branch used to hardcode source 'library', which
# would have filed a qobuz:// url as a library row — unplayable, and it would never dedupe
# against the same album added from Qobuz.
is('...and the source read off that url, not hardcoded library',
   ($r ? $r->{source} : undef), 'qobuz');

# A LIBRARY queue row takes the same branch and must be unchanged — the metadata still comes
# from the Album row, which a remote track doesn't have.
Slim::Schema::add_test_track(
    id => 476336, url => 'file:///music/pnhaeu.flac',
    title => 'Pnhaeu samnieng', artist => 'Various Artists',
    album => bless({ title => 'Cambodian Soul Sounds Vol 1', year => 2019 }, 'Slim::Schema::Album'));

$r = add(_client => $playing, kind => 'track',
         trackname => 'Pnhaeu samnieng', name => 'Cambodian Soul Sounds Vol 1',
         artist => 'Various Artists', trackid => '476336', favurl => '');
is('a library queue row still resolves by id',
   ($r ? "$r->{source}|$r->{ref}{url}" : 'REJECTED'), 'library|file:///music/pnhaeu.flac');
is('...taking its album from the Album row', ($r ? $r->{album_title} : undef),
   'Cambodian Soul Sounds Vol 1');
is('...and its year',                        ($r ? $r->{year}        : undef), 2019);

# ---------------------------------------------------------------------------
section('a BARE RemoteTrack must not wipe the metadata the row sent');
# The shape above is the friendly one: the test registered a title and an artist, so taking
# them off the object looked free. The real one is bare. Qobuz/Tidal serve track metadata
# dynamically through a metadata provider, so the RemoteTrack row itself holds the url and
# little else and answers '' — not undef — for ->title and ->artistName (the same emptiness
# _nowPlayingFallback has to fail open on). '' is DEFINED, so `//` treated it as a value and
# overwrote what Material substituted from the row: artist='' skips both dedupe guards in
# _insertTrackRow (they test `length $artist`), never matches in Played::_matchRecord and
# renders with no artist, while an emptied title is rejected by the add gate outright — the
# exact case resolving a negative id exists to fix.
Slim::Schema::add_test_track(id => -94606967849353, url => 'qobuz://420282128.flac');

$r = add(_client => $playing, kind => 'track',
         trackname => 'Pond Song', name => 'Moisturizer', artist => 'Wet Leg',
         trackid => '-94606967849353', favurl => '');
is('a bare RemoteTrack is still stored, by its own url',
   ($r ? $r->{ref}{url} : 'REJECTED'), 'qobuz://420282128.flac');
is('...keeping the title Material sent, not the object\'s \'\'',
   ($r ? $r->{track_title} : undef), 'Pond Song');
is('...and the artist, which the dedupe guards and Played both need',
   ($r ? $r->{artist} : undef), 'Wet Leg');

# ---------------------------------------------------------------------------
section('a silent reject names the clause that failed, not just the source');
# The warn is the whole trace a reject leaves, and the gate has three clauses. A track with a
# good source and an empty title reported "unsupported source 'qobuz'", which points triage
# at the service. The source is still worth printing — it just isn't the finding.
like('a missing play url says so',
     reject_line(kind => 'track', trackname => 'Some Stream', artist => 'Someone',
                 svc => 'qobuz', favurl => ''),
     qr/rejected add — no play url \(source 'qobuz'\)/);
like('an empty title says so, rather than blaming the service',
     reject_line(kind => 'track', trackname => '', artist => 'Someone',
                 svc => 'qobuz', favurl => 'qobuz://12345.flac'),
     qr/rejected add — no track title \(source 'qobuz'\)/);
like('an unreplayable source still reads exactly as it did',
     reject_line(kind => 'track', trackname => 'A Track', svc => 'spotify',
                 favurl => 'spotify://track:x'),
     qr/rejected add — unsupported source 'spotify'/);

printf "\n%d passed, %d failed\n", $pass, $fail;
exit($fail ? 1 : 0);
