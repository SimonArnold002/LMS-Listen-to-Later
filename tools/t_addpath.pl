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

ll_require('DB', 'Sources', 'Browse', 'Played', 'Plugin');

# The add is gated on the service being REPLAYABLE — Sources::_serviceCan asks whether that
# plugin is installed and exposes its album call (Plugin::_isReplayableSource, 0.1.51: nothing
# unplayable is ever stored). None are installed here, so without these the gate rejects every
# streaming add and each assertion below would "pass" against an empty database. Declaring the
# one method each is checked for is the whole stub — no behaviour is faked, and the rejection
# cases at the end prove the gate is still live.
{
    no strict 'refs';
    *{'Plugins::Qobuz::Plugin::QobuzGetTracks'} = sub { };
    *{'Plugins::Qobuz::Plugin::QobuzPlaylistGetTracks'} = sub { };
    *{'Plugins::TIDAL::Plugin::getAlbum'}       = sub { };
    *{'Plugins::TIDAL::Plugin::getPlaylist'}    = sub { };
    *{'Plugins::Deezer::Plugin::getAlbum'}      = sub { };
    *{'Plugins::Deezer::Plugin::getPlaylist'}   = sub { };
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

section('playlist rows are detected and stored as playlists');
$r = add(name => 'Hi-Res Masters: 2016 / Qobuz UK', svc => 'qobuz', image => 'https://static.qobuz.com/images/playlists/69183531_x_rectangle.jpg', favurl => 'qobuz://album:whatever');
is('qobuz playlist stores kind=playlist', $r->{kind}, 'playlist');
is('...with qobuz source', $r->{source}, 'qobuz');
is('...and playlist_id ref', $r->{ref}{playlist_id}, '69183531');
is('...and no album_id ref', (defined $r->{ref}{album_id} ? 'present' : 'undef'), 'undef');

is('...and no rel_type', $r->{rel_type}, undef);
is('...and no track_count', $r->{track_count}, undef);

$r = add(name => 'Tidal favourites', svc => 'tidal', favurl => 'tidal://playlist:abcd-1234');
is('tidal playlist saves as kind=playlist', $r->{kind}, 'playlist');
is('...with tidal source', $r->{source}, 'tidal');
is('...and playlist id in ref', $r->{ref}{playlist_id}, 'abcd-1234');

$r = add(name => 'Dance Pop', svc => 'deezer', favurl => 'deezer://playlist:908622995');
is('deezer playlist saves as kind=playlist', $r->{kind}, 'playlist');
is('...with deezer source', $r->{source}, 'deezer');
is('...and playlist id in ref', $r->{ref}{playlist_id}, '908622995');

# The title is stored VERBATIM. The album path below strips a trailing "(YYYY)" (Material
# appends one to release labels), which would rename a playlist that is genuinely called
# this — so the playlist branch has to run ahead of that cleaning.
$r = add(name => 'Best of (2016)', svc => 'tidal', favurl => 'tidal://playlist:verbatim-1');
is('a playlist title keeps its (YYYY)', $r->{album_title}, 'Best of (2016)');
is('...and gains no year from it',      $r->{year},        undef);

# "Add to Wish List" on a playlist: you don't buy a playlist, so it lands in Listen Later
# instead of being dropped — the same rule a podcast episode follows.
$r = add(name => 'Wished Playlist', svc => 'tidal', favurl => 'tidal://playlist:wish-1', list => 'wishlist');
is('a playlist sent to the Wish List lands in Listen Later', $r->{status}, 'later');

# Re-adding the same playlist is a no-op, not a second row.
my $again = add(name => 'Dance Pop', svc => 'deezer', favurl => 'deezer://playlist:908622995');
is('re-adding the same playlist stores nothing', (defined $again ? 'stored' : 'already'), 'already');

# Same playlist id, different service = two rows. A playlist id is only unique WITHIN a
# service, and DB::findAnyByKey is cross-source — the key's source segment is what separates them.
$r = add(name => 'Dance Pop', svc => 'tidal', favurl => 'tidal://playlist:908622995');
is('the same id on another service IS a separate row', ($r ? $r->{source} : 'DROPPED'), 'tidal');

section('a playlist we cannot replay is refused, not stored broken');
# Bandcamp has no playlist call at all (and no playlists) — the Sources::_serviceCanPlaylist
# gate must refuse rather than store a row that could only fail at play time.
$r = add(name => 'Bandcamp Mix', svc => 'bandcamp', favurl => 'bandcamp://playlist:xyz');
is('a service with no playlist call stores nothing', (defined $r ? 'stored' : 'rejected'), 'rejected');
like('...and says which clause failed',
     reject_line(name => 'Bandcamp Mix 2', svc => 'bandcamp', favurl => 'bandcamp://playlist:xy2'),
     qr/service has no playlist call \(source 'bandcamp'\)/);

# The title is the row's whole identity, so an empty one is refused outright.
$r = add(name => '', svc => 'tidal', favurl => 'tidal://playlist:no-title');
is('a playlist with no title stores nothing', (defined $r ? 'stored' : 'rejected'), 'rejected');
like('...named as a title problem, not a source one',
     reject_line(name => '', svc => 'tidal', favurl => 'tidal://playlist:no-title-2'),
     qr/no playlist title/);


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
    # THE APOSTROPHE ELIDES — "tomorrows people", not "tomorrow s people" (LL 0.1.112,
    # fleet matcher sync). This assertion previously pinned the OPPOSITE, deliberately
    # and with a note saying so, and it is what caught the fold change: an apostrophe
    # used to become a SPACE like any other non-alphanumeric run, which split "Tomorrow's"
    # into two tokens and made `_artistMatch`'s token-subset test unable to reconcile it
    # with the plain "Tomorrows People" spelling — so Played never marked the record.
    # Still pinned, now to the new contract, so the next change is just as loud.
    is('...keyed without one',           $r->{dedupe_key}, 'tomorrows people|open soul|');
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
# Spotify IS an adapted service now, so this case says something different than it used to:
# it proves the ->can gate is still what decides. Spotty is not stubbed at this point in the
# file (its stubs are declared further down, immediately before the Spotify section), so
# _serviceCan finds no Plugins::Spotty::OPML::album and the add is refused — which is exactly
# what must happen on a server where the user has no Spotty installed.
like('an adapted service with its plugin ABSENT is still refused',
     reject_line(kind => 'track', trackname => 'A Track', svc => 'spotty',
                 favurl => 'spotify:track:x'),
     qr/rejected add — unsupported source 'spotify'/);

# ---------------------------------------------------------------------------
# (Placed here, not beside the playlist section, because two of these need what the block
# above set up: an album add inserts synchronously only when the type is already known
# ('&rt='), and the favurl-less Qobuz cover row resolves through the FakeQobuzAPI stub.)
section('positive controls — playlist detection must not widen');
# These are the rows that would break if the detector over-matched. Each must still store
# exactly what it stored before playlists existed.
$r = add(name => 'Tidal Album', svc => 'tidal', favurl => 'tidal://album:529626253?rt=album');
is('an album favurl still stores kind=album', $r->{kind},          'album');
is('...with its album id',                    $r->{ref}{album_id}, '529626253');

$r = add(name => 'Qobuz Browse Album', artist => 'Someone', svc => 'qobuz',
         image => 'https://static.qobuz.com/images/covers/tb/ta/o8cmpfxeqtatb_600.jpg');
is('a cover-URL album row still stores kind=album', $r->{kind},          'album');
is('...with the id recovered from the cover',       $r->{ref}{album_id}, 'o8cmpfxeqtatb');

# A TRACK row browsed INSIDE a playlist can carry that playlist's cover — so a track-shaped
# favurl has to beat the image half of the detector, or every such add would become a playlist.
$r = add(name => 'A Track In A Playlist', svc => 'qobuz', favurl => 'qobuz://312500115.flac',
         image => 'https://static.qobuz.com/images/playlists/69183531_x_rectangle.jpg');
is('a track favurl beats a playlist cover', $r->{kind},     'track');
is('...and keeps its play url',             $r->{ref}{url}, 'qobuz://312500115.flac');

# ---------------------------------------------------------------------------
section('a saved playlist never auto-moves to Played');
# Playlists are deliberately outside the Played machinery: a playlist is not a release, and
# a curated one changes under you, so "% of it heard" means nothing. This needs no playlist
# code in Played — every lookup _matchRecord makes is filtered to kind='album'/'track' — so
# what is asserted here is that the filtering actually holds end to end.
#
# The sharp case is a play whose album metadata EQUALS the playlist title (a real release
# called "Dance Pop", or a service reporting the playlist as the container): the title-only
# fallback lookup, findByAlbum, LIKEs '%|dance pop|%' — which the playlist key's own title
# segment matches — so only the kind filter stands between it and a wrong mark.
my $plRow = add(name => 'Dance Pop', svc => 'tidal', favurl => 'tidal://playlist:played-guard');
is('the guard row is a playlist', $plRow->{kind}, 'playlist');

my $plPlay = Plugins::ListenLater::Played::_matchRecord(
    undef, FakeTrack->new(artist => 'Some Artist', album => 'Dance Pop'), 'tidal://12345.flac');
is('a play matching a playlist title marks nothing',
   (defined $plPlay ? 'WRONGLY MATCHED' : 'no match'), 'no match');

# ...and with no artist at all, which is what a streaming track usually reports.
$plPlay = Plugins::ListenLater::Played::_matchRecord(
    undef, FakeTrack->new(artist => '', album => 'Dance Pop'), 'tidal://12345.flac');
is('...nor does an artist-less play',
   (defined $plPlay ? 'WRONGLY MATCHED' : 'no match'), 'no match');

# ---------------------------------------------------------------------------
section('Spotify — a bare Spotify URI must add exactly like a scheme url');
#
# Placed at the END of this file ON PURPOSE. Declaring the Spotty stubs here rather than with
# the others at the top means every test ABOVE ran with Spotty absent — including the refusal
# case in the rejection section, which proves the ->can gate still turns the service away when
# the plugin is not installed. Both states are therefore covered by one file, in order.
# The two node subs RECORD what they were handed, because the rebuild assertions at the end
# of this section turn on the passthrough being exactly right — a node that plays once and
# then loses its album on the next page open is the classic way an adapter passes review and
# fails in use, and the only thing that catches it is checking what the coderef receives.
our ($SPOTTY_ALBUM_ARG, $SPOTTY_PLAYLIST_ARG);
{
    no strict 'refs';
    *{'Plugins::Spotty::OPML::album'} = sub {
        my ($client, $cb, $params, $args) = @_;
        $SPOTTY_ALBUM_ARG = $args;
        $cb->({ items => [ map { { type => 'audio', url => "spotify://track:t$_" } } 1 .. 3 ] });
    };
    *{'Plugins::Spotty::OPML::playlist'} = sub {
        my ($client, $cb, $params, $args) = @_;
        $SPOTTY_PLAYLIST_ARG = $args;
        $cb->({ items => [ { type => 'audio', url => 'spotify://track:p1' } ] });
    };
    *{'Plugins::Spotty::OPML::_albumItem'}      = sub { };
    *{'Plugins::Spotty::Plugin::getAPIHandler'} = sub { undef };
}

# The album. Spotty sends 'spotify:album:<id>' with no '//', which before normaliseFavurl
# read as source 'library' and dropped the id on the floor. Both halves are asserted,
# because the id is what separates an exact replay from a fuzzy artist+album search.
$r = add(name => 'Random Access Memories', artist => 'Daft Punk', svc => 'spotty',
         favurl => 'spotify:album:4m2880jivSbbyEGAKfITCa?rt=album');
is('a Spotify URI stores an album',      $r->{kind},          'album');
is('...with source spotify, not library',$r->{source},        'spotify');
is('...and the album id off the URI',    $r->{ref}{album_id}, '4m2880jivSbbyEGAKfITCa');

# The track. Spotty's track favurl is 'spotify:track:<id>' while its PLAY url is
# 'spotify://track:<id>' — the normalised form is byte-for-byte the play url, so the stored
# ref needs no conversion. That equivalence is the whole reason the track leg is free.
$r = add(kind => 'track', trackname => 'Get Lucky', artist => 'Daft Punk', svc => 'spotty',
         favurl => 'spotify:track:69kOkLUCkxIZYexIgSG8rq');
is('a Spotify track URI stores a track', $r->{kind},      'track');
is('...with source spotify',             $r->{source},    'spotify');
is('...and a playable spotify:// url',   $r->{ref}{url},  'spotify://track:69kOkLUCkxIZYexIgSG8rq');

# The playlist, in both spellings Spotify uses. The legacy 'user:<name>:playlist:<id>' form
# must land the same id as the modern one, because _streamingPlaylistNode rebuilds the SHORT
# URI from whatever is stored and hands that to Spotty either way.
$r = add(name => 'Discover Weekly', svc => 'spotty', favurl => 'spotify:playlist:37i9dQZEVXcQ9COmYvdajy');
is('a Spotify playlist URI stores a playlist', $r->{kind},             'playlist');
is('...with source spotify',                   $r->{source},           'spotify');
is('...and the playlist id',                   $r->{ref}{playlist_id}, '37i9dQZEVXcQ9COmYvdajy');

$r = add(name => 'Old Style List', svc => 'spotty', favurl => 'spotify:user:bob:playlist:37i9dQZEVXcLEGACY');
is('the legacy playlist form also stores', $r->{kind},             'playlist');
is('...and lands the same short id',       $r->{ref}{playlist_id}, '37i9dQZEVXcLEGACY');

# An album row entered from the Spotify APP menu sends svc='spotty' — the browse command,
# not the service name. Without the alias that is not a known source, and the add would fall
# through to the cover sniff. Prove the name alone is enough, by giving it no cover at all.
$r = add(name => 'Homework', artist => 'Daft Punk', svc => 'spotty',
         favurl => 'spotify:album:2wart5Qjnvx1fd7LPdQxgJ?rt=album');
is("svc 'spotty' resolves to source spotify", $r->{source}, 'spotify');

# And the reverse of the earlier gate check: with Spotty present, the same shape that was
# refused above now stores. Nothing but the ->can gate changed between the two.
$r = add(kind => 'track', trackname => 'A Track', artist => 'Someone', svc => 'spotty',
         favurl => 'spotify:track:x');
is('the refusal above was the gate, not the shape', ($r ? $r->{source} : 'REFUSED'), 'spotify');

# THE REBUILD TEST — replaying a STORED row, which is the check most likely to be skipped
# and the one that catches a match that plays once and is then gone. Nothing above proves it:
# an add can store a perfectly good id and still be unreplayable, because the id has to be
# turned back into the service's own node with the shape that service expects.
#
# Spotty is unusually easy to get wrong here. Its album call reads a full URI out of
# $params->{uri} — API::album does `$args->{uri} =~ /album:(.*)/`, so a BARE id (what every
# other adapted service is handed) matches nothing and the replay silently returns an album
# with no tracks. Assert the URI was rebuilt, not just that some node came back.
$r = add(name => 'Discovery', artist => 'Daft Punk', svc => 'spotty',
         favurl => 'spotify:album:2noRn2Aes5aoNVsU6iWThc?rt=album');
my $spTracks;
Plugins::ListenLater::Sources::resolveTracks(undef, $r, sub { $spTracks = shift });
is('a stored Spotify album replays',        scalar(@{ $spTracks || [] }), 3);
is('...through a rebuilt full album URI',   $SPOTTY_ALBUM_ARG->{uri}, 'spotify:album:2noRn2Aes5aoNVsU6iWThc');
is('...and NOT a bare id',                  (($SPOTTY_ALBUM_ARG->{uri} // '') =~ /^spotify:album:/ ? 'uri' : 'bare id'), 'uri');

# The playlist mirror, including the legacy row: whichever spelling was added, the SHORT
# URI is what Spotty gets — its own getPlaylistUserAndId resolves the owner from its cache.
my $plRec = add(name => 'Weekly', svc => 'spotty', favurl => 'spotify:playlist:37i9dQZREBUILD');
my $spPl;
Plugins::ListenLater::Sources::resolveTracks(undef, $plRec, sub { $spPl = shift });
is('a stored Spotify playlist replays',     scalar(@{ $spPl || [] }), 1);
is('...through a short playlist URI',       $SPOTTY_PLAYLIST_ARG->{uri}, 'spotify:playlist:37i9dQZREBUILD');

my $lgRec = add(name => 'Weekly Legacy', svc => 'spotty', favurl => 'spotify:user:bob:playlist:37i9dQZLEG');
Plugins::ListenLater::Sources::resolveTracks(undef, $lgRec, sub { });
is('...and a legacy row rebuilds short too', $SPOTTY_PLAYLIST_ARG->{uri}, 'spotify:playlist:37i9dQZLEG');


section('a podcast SERIES is refused, wherever it comes from');
#
# Both of these were REPRODUCED ON THE TEST SERVER against 0.1.122 before the gate existed,
# from real browse rows, and both stored. They are the reason unsupportedContainer is a
# THIRD question and not a widening of one of the two gates that already ran here:
#   • the Spotify show passed _serviceCan (Spotty IS installed — the stubs above make that
#     true here too) and passed favurlIsTrack as a "container", i.e. an ALBUM, so it stored
#     as an album row with no album id, replayed by a fuzzy search on the show's blurb;
#   • the Deezer series never reached a container test at all — 'podcast:' is not in
#     favurlIsTrack's list, so it took the FAIL-OPEN branch and stored as a kind='track' row
#     pointing type => 'audio' at a series url.
# The Deezer half is what pins the PLACEMENT: move this gate inside favurlIsTrack and that
# row stops being a track and becomes an album instead — still stored, so the show assertion
# alone would stay green. Only asserting on both shapes catches that.
$r = add(name => 'Serial', artist => 'Serial Productions makes narrative podcasts.',
         svc => 'spotty', favurl => 'spotify:show:5wMPFS9B5V7gg6hZ3UZ7hf');
is('a Spotify show stores nothing',   (defined $r ? "stored as $r->{kind}" : 'rejected'), 'rejected');
$r = add(name => 'The Minimalists', artist => 'The Minimalists are Emmy-nominated',
         svc => 'deezer', favurl => 'deezer://podcast:19887');
is('a Deezer series stores nothing',  (defined $r ? "stored as $r->{kind}" : 'rejected'), 'rejected');
like('...and the reject names the container, not the service',
     reject_line(name => 'The Minimalists', svc => 'deezer', favurl => 'deezer://podcast:19888'),
     qr/'podcast' is a container this plugin has no adapter for \(source 'deezer'\)/);

# The EPISODE is the whole point of the distinction: we save podcast episodes, and only the
# series is out of scope. This is the row that must NOT move.
$r = add(kind => 'track', trackname => 'Mission Killer', artist => 'Serial', svc => 'spotty',
         favurl => 'spotify:episode:0tQdtR5srOLPVaevOrLyhR');
is('a Spotify EPISODE still stores',  $r->{kind},     'track');
is('...with source spotify',          $r->{source},   'spotify');
is('...and a playable episode url',   $r->{ref}{url}, 'spotify://episode:0tQdtR5srOLPVaevOrLyhR');

# ...and it must READ as a podcast, not as a Spotify track. Spotty gives an episode the same
# source tag and the same scheme as a music track, so the url is the only thing that says
# which it is — and until 0.1.126 nothing asked, so a Spotify episode drew the ♪ note, said
# "Track", and was allowed into the Wish List. The row is passed WHOLE to both renderers,
# because a predicate handed only the source cannot answer for this service at all.
is('...reads as a podcast episode',
    Plugins::ListenLater::Sources::isPodcastEpisode($r->{source}, $r->{ref}{url}), 1);
is('...so the row draws the podcast glyph, not the music note',
    Plugins::ListenLater::Browse::_glyphFor($r), "\x{275d}");
is('...and its type word is Podcast',
    Plugins::ListenLater::Browse::_typeLabel(undef, $r), 'PLUGIN_LL_TYPE_PODCAST');
# POSITIVE CONTROL, and the reason the url is tested rather than the source: an ordinary
# Spotify TRACK must be untouched by all of it. Without this, "spotify is always a podcast"
# would pass every assertion above and silently relabel the whole service.
{
    my $tr = add(kind => 'track', trackname => 'Just A Song', artist => 'Blondie',
                 svc => 'spotty', favurl => 'spotify:track:4cOdK2wGLETKBW3PvgPWqT');
    is('a Spotify TRACK is not a podcast',
        Plugins::ListenLater::Sources::isPodcastEpisode($tr->{source}, $tr->{ref}{url}), 0);
    is('...it keeps the single-note glyph',
        Plugins::ListenLater::Browse::_glyphFor($tr), "\x{266a}");
    is('...and still says Track',
        Plugins::ListenLater::Browse::_typeLabel(undef, $tr), 'PLUGIN_LL_TYPE_TRACK');
}

# TIDAL mixes ride the same gate, for a reason that is NOT "a mix is unaddable": TIDAL's own
# plugin routes them to getMix($params->{id}) and playlists to getPlaylist($params->{uuid}),
# two different API calls, so a mix id handed to the playlist path would fail. Refusing is
# the honest answer until a getMix adapter exists.
$r = add(name => 'My Mix 1', artist => 'Brent Faiyaz', svc => 'tidal',
         favurl => 'tidal://mix:0022a937b6860d3fec2d18d46be318');
is('a TIDAL mix stores nothing',      (defined $r ? "stored as $r->{kind}" : 'rejected'), 'rejected');

# ANTI-TEST for the type list: Spotify's own "mixes" are plain playlist URIs and are NOT
# affected by any of the above. If this ever goes red, the gate has widened onto real rows.
$r = add(name => 'Daily Mix 1', svc => 'spotty', favurl => 'spotify:playlist:37i9dQZF1E3DAILY');
is('a Spotify daily mix still stores', $r->{kind},             'playlist');
is('...as a playlist, with its id',    $r->{ref}{playlist_id}, '37i9dQZF1E3DAILY');


section('a Deezer podcast EPISODE stores (0.1.124)');
#
# Deezer browses episodes as 'deezerpodcast://<id>' — a scheme of its own, not 'deezer://'
# (verified live). Until 0.1.124 that was an unknown source and every one was refused:
#   LL: rejected add — unsupported source 'deezerpodcast' via container 'deezer'
# Nothing about it needed an adapter. A saved episode is kind='track' and a track row replays
# straight from its stored url, so the only question was whether a handler for the scheme
# exists — the same question 'podcast' has always asked. The stub below is that handler.
# NOT a chain onto the previous handlerForURL — there ISN'T one. `t_stubs.pl` never defines
# it, so every earlier `_hasPodcastHandler` in this file answered 0 (the eval fails), which
# is why the built-in podcast adds above are refused here. Taking `\&...handlerForURL` before
# assigning the glob would therefore create a FORWARD reference that resolves to this very
# sub at call time — infinite recursion, which is exactly what the first draft did. Answer
# for the one scheme this section is about and undef for everything else, i.e. leave the
# no-handler world every test above ran in exactly as it was.
{
    no strict 'refs';
    # Called as a CLASS method (`Slim::Player::ProtocolHandlers->handlerForURL($url)`), so the
    # url is $_[1] and $_[0] is the package name. Reading $_[0] here silently answers "no
    # handler" for every url and the whole section fails as a rejected add.
    *{'Slim::Player::ProtocolHandlers::handlerForURL'} = sub {
        return ($_[1] // '') =~ m{^deezerpodcast://} ? 'Plugins::Deezer::ProtocolHandler' : undef;
    };
}
$r = add(kind => 'track', trackname => 'The Floor', artist => 'The Minimalists',
         svc => 'deezer', favurl => 'deezerpodcast://927648401');
is('a Deezer episode stores',        (defined $r ? $r->{kind} : 'rejected'), 'track');
is('...under its own source tag',    $r->{source},   'deezerpodcast');
is('...keeping the play url intact', $r->{ref}{url}, 'deezerpodcast://927648401');

# The source tag is deliberately NOT folded onto 'deezer': the album adapter has nothing to
# do with an episode, and a tag of its own is what lets Browse mark the row as a podcast.
# These three are what Browse asks of it.
is('...and reads as a podcast episode',
    Plugins::ListenLater::Sources::isPodcastEpisode($r->{source}, $r->{ref}{url}), 1);
is('...labelled Deezer, not Deezerpodcast',
    Plugins::ListenLater::Sources::sourceLabel($r->{source}), 'Deezer');
is('...while plain deezer is not',
    Plugins::ListenLater::Sources::isPodcastEpisode('deezer'), 0);

# ANTI-TEST: the SERIES stays refused. Supporting episodes must not open the container.
$r = add(name => 'The Minimalists', svc => 'deezer', favurl => 'deezer://podcast:19887');
is('the Deezer SERIES is still refused', (defined $r ? "stored as $r->{kind}" : 'rejected'), 'rejected');

# ---------------------------------------------------------------------------
# The Wish List is for things you mean to BUY, so two kinds of row are redirected out of it:
# a podcast episode and a curated playlist. That rule had four consumers answering it
# separately — _savePodcastEpisode and _savePlaylistRecord each with their own
# `if ($list eq 'wishlist')`, _saveTrackRecord with none, and _contextMenuQuery testing
# `kind eq 'playlist'` — and the gaps between them were real: a DEEZER episode
# ('deezerpodcast://<id>', 0.1.124) stores through _saveTrackRecord, so it landed in the
# Wish List that the identical built-in episode was redirected out of, and the saved row
# then offered "Move to Wish List" on BOTH podcast sources, undoing the redirect in one tap.
#
# Everything below asks the ONE carrier (_wishListable) through the four paths that consult
# it, and the anti-tests either side pin what it must NOT catch — an ordinary streaming
# track and album still reach the Wish List, which is what the list is for.
section('nothing you cannot buy reaches the Wish List — by any route');

# Which list did it actually land in? add() only ever watches 'later', which is the right
# answer for a redirect but cannot tell "redirected" from "refused".
# 0.1.136 — WITH THE OVERRIDE GONE, what does the generic online-* Add do on a Podcasts-app
# row? The populated podcasts-* pair used to REPLACE that pair on those rows; removing it
# means the generic entry renders there instead. It must REJECT cleanly rather than store a
# row that cannot replay — and it must not silently do nothing.
sub podcast_row_add {
    my ($l) = landed_in(name => '47. The Fall of Constantinople', svc => 'podcasts',
                        image => '/imageproxy/https%3A%2F%2Fcdn.ex%2Fep.jpg/image.png');
    return $l;
}
sub landed_in {
    my (%params) = @_;
    my %before = map { my $l = $_;
        ($l => { map { $_->{id} => 1 } @{ Plugins::ListenLater::DB::list($l, 'added') } }) }
        qw(later wishlist);
    Plugins::ListenLater::Plugin::_addCtxCommand(FakeRequest->new(%params));
    for my $l (qw(later wishlist)) {
        my ($new) = grep { !$before{$l}{ $_->{id} } }
                         @{ Plugins::ListenLater::DB::list($l, 'added') };
        return ($l, $new) if $new;
    }
    return ('nothing stored', undef);
}

# Widen the scheme handler for the streaming-episode cases below. Installed HERE, at the end
# of the file, so every narrower assertion above runs in the world it expects.
#
# 0.1.136 removed the built-in Podcasts path, and with it the two stubs that used to sit in
# this block — Plugins::ListenLater::Podcast::hasFeeds and ::resolveEpisode. They are NOT
# reinstated: the package no longer exists, nothing in the plugin calls either sub, and a stub
# standing in for a deleted implementation can only ever MASK its absence, never catch it. The
# built-in row's behaviour is asserted directly instead, at the end of this file, where it must
# now store nothing.
{
    no strict 'refs'; no warnings 'redefine';
    # The section above answers handlerForURL for 'deezerpodcast://' ONLY. Answer for the bare
    # 'podcast://' spelling too, so a fixture carrying one is not turned away by a missing
    # handler rather than by the gate under test. Defined fresh, NOT chained onto the existing
    # glob: capturing \&handlerForURL here resolves to THIS sub at call time and recurses
    # (see above).
    *{'Slim::Player::ProtocolHandlers::handlerForURL'} = sub {
        return ($_[1] // '') =~ m{^(?:deezer)?podcast://} ? 'Plugins::Deezer::ProtocolHandler'
                                                          : undef;
    };
}

my ($where) = landed_in(kind => 'track', trackname => 'Deezer Ep', artist => 'Someone',
                     svc => 'deezer', favurl => 'deezerpodcast://5551212',
                     list => 'wishlist');
is('a DEEZER episode is redirected too — it stores through _saveTrackRecord', $where, 'later');

# The third source, and the one 0.1.125 could not catch: Spotify says "episode" only in the
# url, so the redirect had nothing to key on and the episode went straight into the Wish List.
($where) = landed_in(kind => 'track', trackname => 'Spotify Ep', artist => 'Some Show',
                     svc => 'spotty', favurl => 'spotify:episode:5wMPFS9B5V7gg6hZ3UZ7hf',
                     list => 'wishlist');
is('a SPOTIFY episode is redirected too — the url is what says so', $where, 'later');

# ANTI-TEST for that one specifically: the guard is the episode ref, not the service.
($where) = landed_in(kind => 'track', trackname => 'Buyable Spotify Track',
                     artist => 'Some Other Band', svc => 'spotty',
                     favurl => 'spotify:track:1cOdK2wGLETKBW3PvgPWqT', list => 'wishlist');
is('...while an ordinary Spotify TRACK still reaches the Wish List', $where, 'wishlist');

# ANTI-TESTS. The redirect keys on what the row IS, not on the word "wishlist", so an
# ordinary track and an ordinary album must still get there.
# Identities unused anywhere else in this file: the cross-kind single dedupe is live here,
# and re-adding a title the suite already stored reads as 'nothing stored', not as a refusal.
($where) = landed_in(kind => 'track', trackname => 'Buyable Track', artist => 'Some Band',
                     svc => 'qobuz', favurl => 'qobuz://93012480.flac', list => 'wishlist');
is('an ordinary streaming TRACK still reaches the Wish List', $where, 'wishlist');
($where) = landed_in(name => 'Buyable Album', svc => 'qobuz', list => 'wishlist',
                     favurl => 'qobuz://album:wish-album-1?a=Some%20Band&rt=album');
is('...and an ordinary ALBUM does too', $where, 'wishlist');

# The rule on its own, at the two ends that matter: both podcast SOURCES, not one spelling.
is('_wishListable: a Deezer podcast episode',
    Plugins::ListenLater::Plugin::_wishListable('track', 'deezerpodcast'), 0);
is('_wishListable: a playlist',
    Plugins::ListenLater::Plugin::_wishListable('playlist', 'tidal'), 0);
is('_wishListable: an ordinary streaming track',
    Plugins::ListenLater::Plugin::_wishListable('track', 'deezer'), 1);
is('_wishListable: an album',
    Plugins::ListenLater::Plugin::_wishListable('album', 'qobuz'), 1);
is('_wishListable: no record to judge (kind undef) fails OPEN',
    Plugins::ListenLater::Plugin::_wishListable(undef, undef), 1);
# Spotify, both ways round — the source is identical, so ONLY the third argument separates
# them. Drop the url at any of the four consumers and the episode becomes buyable again.
is('_wishListable: a Spotify podcast episode',
    Plugins::ListenLater::Plugin::_wishListable('track', 'spotify',
        'spotify://episode:0tQdtR5'), 0);
is('_wishListable: an ordinary Spotify track',
    Plugins::ListenLater::Plugin::_wishListable('track', 'spotify',
        'spotify://track:0tQdtR5'), 1);

# --- the saved row's own menu, and the command behind it ---------------------
# The menu is presentation; the command is the enforcement. Both are asked, because Material
# replays a history page without re-querying it — a "Move to Wish List" rendered before this
# build is still tappable — and a CLI caller never saw a menu at all.
sub menu_titles {
    my ($id) = @_;
    my $req = FakeRequest->new(id => $id);
    Plugins::ListenLater::Plugin::_contextMenuQuery($req);
    return join ' ', map { $_->[3] } grep { $_->[2] eq 'text' } @{ $req->{loop} || [] };
}
sub move_to {
    my ($id, $status) = @_;
    Plugins::ListenLater::Plugin::_moveCommand(FakeRequest->new(id => $id, status => $status));
    my $rec = Plugins::ListenLater::DB::get($id);
    return $rec ? $rec->{status} : '(gone)';
}

# The BANDCAMP entry, which is the other consumer of the row's stored ref in that sub. It was
# uncovered until 2026-09-10 — every menu assertion here is about the Wish List rule, so the
# suite stayed green whatever the Buy entry did. It reads the ref that the Wish List rule
# reads: one extraction, where there used to be two identical ones, the second defended in a
# comment as "its own narrower copy". These pin the fold by its OUTPUT, since no return value
# shows which variable was read. ANTI-TEST: point the Buy entry at an empty hash and the
# weblink cases fall back to the drill (3 red).
sub menu_entry {
    my ($id, $want) = @_;
    my $req = FakeRequest->new(id => $id);
    Plugins::ListenLater::Plugin::_contextMenuQuery($req);
    my %by;                                     # index => { key => value }
    $by{ $_->[1] }{ $_->[2] } = $_->[3] for @{ $req->{loop} || [] };
    for my $i (sort { $a <=> $b } keys %by) {
        next unless ($by{$i}{text} // '') eq $want;
        return $by{$i};
    }
    return {};
}
{
    my ($known) = Plugins::ListenLater::DB::add({
        source => 'bandcamp', kind => 'album', artist => 'Cola', album_title => 'Deep In View',
        ref_kind => 'url', ref => { album_url => 'https://cola.bandcamp.com/album/deep-in-view' },
    }, 'later');
    my $e = menu_entry($known, 'PLUGIN_LL_BUY_BANDCAMP');
    is('a Bandcamp row with a stored album url opens it directly',
        ($e->{weblink} // '(none)'), 'https://cola.bandcamp.com/album/deep-in-view');
    is('...so it needs no drill into the buy query',
        (exists $e->{actions} ? 'drills' : 'no drill'), 'no drill');

    # buy_url wins over album_url — the cached resolve is the better page.
    my ($cached) = Plugins::ListenLater::DB::add({
        source => 'bandcamp', kind => 'album', artist => 'Cola', album_title => 'Cost Of Living',
        ref_kind => 'url', ref => { album_url => 'https://cola.bandcamp.com/album/a',
                                    buy_url   => 'https://cola.bandcamp.com/album/b' },
    }, 'later');
    is('a cached buy url is preferred over the one captured at add time',
        (menu_entry($cached, 'PLUGIN_LL_BUY_BANDCAMP')->{weblink} // '(none)'),
        'https://cola.bandcamp.com/album/b');

    # The older-save case: no url in the ref at all, so the entry must still appear and drill.
    my ($bare) = Plugins::ListenLater::DB::add({
        source => 'bandcamp', kind => 'album', artist => 'Cola', album_title => 'Blank Curtain',
        ref_kind => 'search', ref => {},
    }, 'later');
    my $b = menu_entry($bare, 'PLUGIN_LL_BUY_BANDCAMP');
    is('a Bandcamp row with no stored url still offers Buy',
        (%$b ? 'offered' : 'missing'), 'offered');
    is('...as a drill into the buy query, not a weblink',
        (($b->{actions} && !$b->{weblink}) ? 'drills' : 'weblink'), 'drills');

    # The control: a non-Bandcamp row must not get the entry at all.
    my ($qobuz) = Plugins::ListenLater::DB::add({
        source => 'qobuz', kind => 'album', artist => 'Cola', album_title => 'Not Bandcamp',
        ref_kind => 'search', ref => { album_url => 'https://cola.bandcamp.com/album/x' },
    }, 'later');
    is('a non-Bandcamp row never offers Buy, whatever its ref holds',
        (%{ menu_entry($qobuz, 'PLUGIN_LL_BUY_BANDCAMP') } ? 'offered' : 'absent'), 'absent');
}

# The stored ref goes in as well, because for Spotify it is the ONLY thing separating the
# episode from the track: both rows below are kind='track', source='spotify'.
for my $c ( [ 'a Deezer podcast episode',   'deezerpodcast','track',    0, 'deezerpodcast://1' ],
            [ 'a Spotify podcast episode',  'spotify',      'track',    0, 'spotify://episode:e1' ],
            [ 'an ordinary Spotify track',  'spotify',      'track',    1, 'spotify://track:t1' ],
            [ 'a playlist',                 'tidal',        'playlist', 0, undef ],
            [ 'an ordinary album',          'qobuz',        'album',    1, undef ] ) {
    my ($what, $source, $kind, $allowed, $url) = @$c;
    my ($id) = Plugins::ListenLater::DB::add({
        source => $source, kind => $kind, artist => 'A',
        track_title => ($kind eq 'track' ? "T-$what" : undef),
        album_title => "Al-$what", ref_kind => 'search',
        ref => (defined $url ? { url => $url } : {}),
    }, 'later');
    is("menu on $what: Move to Wish List " . ($allowed ? 'offered' : 'withheld'),
        (menu_titles($id) =~ /PLUGIN_LL_MOVE_WISHLIST/ ? 'offered' : 'withheld'),
        ($allowed ? 'offered' : 'withheld'));
    is("...and the move command " . ($allowed ? 'allows it' : 'refuses it'),
        move_to($id, 'wishlist'), ($allowed ? 'wishlist' : 'later'));
    # Whatever the verdict, the OTHER moves are untouched — the guard is Wish-List-only.
    is('...while Move to Played is unaffected', move_to($id, 'played'), 'played');
}

# ---------------------------------------------------------------------------
# A podcast episode's browse row is DISPLAY-shaped, and the fix is judged by whether PLAYED
# can find the row afterwards — not by whether the row looks tidy.
#
# THE CONTRACT BEING TESTED (Played.pm): a track row's identity is its play URL.
# `_markPlayedTrack` matches `DB::findTrackByUrl($source, $url)` FIRST — an exact string
# compare — and only falls back to `findSavedTrack(source, artist, album, title)` when that
# misses. So the URL is what must be right, and the naming is the fallback.
#
# The naming is still worth getting right, and there is exactly ONE honest source for it:
# `Sources::playingMeta`, which is `handlerForURL($url)->getMetadataFor(...)` — the very sub
# Played falls back to. Asking it at ADD time is what makes the two ends agree by
# construction. Previous attempts asked each service's own API instead and had to guess what
# it would return; this asks the thing that will actually be compared against.
section('a podcast episode stores what the handler will report while playing');

# The handler stub is modelled on MEASURED output — Spotty's own getMetadataFor for a
# spotify:// url, read from the live server log 2026-09-04:
#     url => "spotify://track:5Oby…", album => "Save My Love",
#     artist => "Kygo, Khalid, Gryffin", title => "Save My Love"
# Note what that shape does NOT contain: any album id, and any separate publisher field. The
# handler answers a flat trio of strings, which is all this path needs.
#
# EVERY FIXTURE ALSO CARRIES A `duration`, and that is not decoration — it is the fact
# `_fillFromPlayingMeta` gates the whole fill on. Read from both handlers' source 2026-09-04:
# Spotty's cache hit sets `duration => $cached->{duration_ms}/1000` and lms-deezer's complete
# episode meta carries the API's `duration`, so a real answer always has one, while the three
# shapes that answer a NAME without describing an episode do not. A fixture without a duration
# therefore models a handler that knows nothing — which is what the §fallback case below uses
# it for deliberately. Do not "tidy" durations in or out; they decide which branch runs.
our %HANDLER_META;
our $HANDLER_ASKED;
{
    no strict 'refs'; no warnings 'redefine';
    *{'Slim::Player::ProtocolHandlers::handlerForURL'} = sub {
        my $u = $_[1] // '';
        return 'Plugins::Deezer::ProtocolHandler' if $u =~ m{^(?:deezer)?podcast://};
        return 'FakeSpotifyHandler'               if $u =~ m{^spotify://};
        return undef;
    };
    *{'FakeSpotifyHandler::getMetadataFor'} = sub {
        my ($self, $client, $url) = @_;
        $HANDLER_ASKED = $url;
        return $HANDLER_META{$url} || {};
    };
}

my $EPCL  = bless {}, 'FakePlayingClient';
my $EPURL = 'spotify://episode:9wMPFS9B5V7gg6hZ3UZ7hf';
$HANDLER_META{$EPURL} = {
    title    => 'Mission Killer',
    album    => 'Serial',
    artist   => 'Serial Productions',
    duration => 2732,
};

$r = add(_client => $EPCL,
         name => '2026-01-05 - Mission Killer',
         artist => 'In this episode we follow a case that has haunted the department for '
                 . 'thirty years, and the detective who would not let it go...',
         svc => 'spotty', favurl => 'spotify:episode:9wMPFS9B5V7gg6hZ3UZ7hf');

is('the episode stores', ($r ? $r->{kind} : 'nothing'), 'track');
is('...the release-date prefix is off the title', $r->{track_title}, 'Mission Killer');
is('...the description is NOT stored as the artist', $r->{artist}, 'Serial Productions');
is('...the show is stored as the parent album',      $r->{album_title}, 'Serial');
is('...and the handler was asked about the STORED url',  $HANDLER_ASKED, $EPURL);

# THE ASSERTION THIS SECTION EXISTS FOR — both routes Played::_markPlayedTrack takes, driven
# with exactly what the handler reports.
is('PLAYED finds it by url — the PRIMARY route, and the one that must never depend on naming',
    (Plugins::ListenLater::DB::findTrackByUrl('spotify', $EPURL) || {})->{id}, $r->{id});
# AND THE METADATA FALLBACK DELIBERATELY DOES NOT FIND IT — this is the trade the url-based
# episode key makes, and it is recorded as an assertion so it can never be lost silently.
# DB::findSavedTrack matches a key shaped 'artist|album|%|t:<title>'; an episode's key ends in
# '|e:<source>:<url>' and has no '|t:' segment at all, so it cannot match by construction.
#
# That costs nothing REAL, for two reasons worth keeping. (1) It could not match in the field
# anyway: a streaming episode stores no artist and no show (measured — the browse row carries
# neither and getMetadataFor answers nothing for an unplayed episode url), while the handler
# reports a publisher and a show at play time, so the two sides never lined up. The old green
# assertion here only passed because the STUB filled values the real path does not have.
# (2) The fallback exists for url DRIFT, which episode URIs do not have — 'spotify://episode:<id>'
# and 'deezerpodcast://<id>' are stable ids, not signed or expiring urls like a Qobuz stream.
# So the primary route below is the whole story, and it is the one asserted.
is('the metadata fallback does NOT find an episode — it is url-keyed, by design',
    (Plugins::ListenLater::DB::findSavedTrack('spotify', 'Serial Productions', 'Serial',
                                              'Mission Killer') || {})->{id}, undef);

# THE WHOLE REASON THE EPISODE KEY IS URL-BASED. Two episodes with the SAME TITLE from
# different shows — "Trailer", "Episode 1", "Introduction" and "Chapter I" are titles dozens of
# shows share. A streaming episode row stores no artist and no show, so under the plain track
# key both collapse to '|||t:trailer': DB::add returns the FIRST row, the user gets a
# confirmation toast, and the single row left in the list plays the WRONG episode.
# ANTI-TEST: revert episodeKey and these two go red with 'collided'.
{
    my $u1 = 'spotify://episode:aaaaaaaaaaaaaaaaaaaaaa';
    my $u2 = 'spotify://episode:bbbbbbbbbbbbbbbbbbbbbb';
    my $e1 = add(_client => $EPCL, name => '2026-01-01 - Trailer', artist => 'blurb one',
                 svc => 'spotty', favurl => 'spotify:episode:aaaaaaaaaaaaaaaaaaaaaa');
    my $e2 = add(_client => $EPCL, name => '2026-02-02 - Trailer', artist => 'blurb two',
                 svc => 'spotty', favurl => 'spotify:episode:bbbbbbbbbbbbbbbbbbbbbb');
    is('two same-titled episodes from different shows BOTH store',
        (($e1 && $e2 && $e1->{id} != $e2->{id}) ? 'two rows' : 'collided'), 'two rows');
    is('...told apart by the play url, which is the row identity everywhere else',
        $e2->{dedupe_key}, '|trailer||e:spotify:' . $u2);
    # And each still resolves to its OWN episode — the failure was not just "not saved", it
    # was a row that played someone else's audio.
    is('...and each row keeps its own play url',
        (Plugins::ListenLater::DB::findTrackByUrl('spotify', $u1) || {})->{id}, $e1->{id});
    is('...both ways round',
        (Plugins::ListenLater::DB::findTrackByUrl('spotify', $u2) || {})->{id}, $e2->{id});
}

# THE FALLBACK, and it is the important case rather than an edge one: a handler that knows
# nothing about this url. The row must still store, still be playable, and still be findable
# by PLAYED via the url — because the url never depended on the lookup.
{
    my $u = 'spotify://episode:cc3cc3cc3cc3cc3cc3cc3c';
    my $f = add(_client => $EPCL, name => '2026-03-03 - Unresolvable',
                artist => 'a blurb the row supplied', svc => 'spotty',
                favurl => 'spotify:episode:cc3cc3cc3cc3cc3cc3cc3c');
    is('an episode the handler cannot describe still stores', ($f ? $f->{kind} : 'nothing'), 'track');
    is('...with the date prefix still stripped',   $f->{track_title}, 'Unresolvable');
    is('...and the blurb still kept out of the artist', $f->{artist}, undef);
    is('...and PLAYED still finds it by url, which is what actually matters',
        (Plugins::ListenLater::DB::findTrackByUrl('spotify', $u) || {})->{id}, $f->{id});
}

# FILL-ONLY: a track-context add (queue / Now Playing) already carries the handler's values,
# and the row the user tapped must not be replaced by a second lookup.
{
    my $u = 'spotify://episode:6wMPFS9B5V7gg6hZ3UZ7hf';
    $HANDLER_META{$u} = { title => 'Episode Two', album => 'A Different Show',
                          artist => 'A Different Publisher', duration => 1810 };
    my $r2 = add(_client => $EPCL,
                 kind => 'track', trackname => 'Episode Two', name => 'Serial',
                 artist => 'A Publisher The Row Knew', svc => 'spotty',
                 favurl => 'spotify:episode:6wMPFS9B5V7gg6hZ3UZ7hf');
    is('a track-context episode keeps the artist the row supplied',
        $r2->{artist}, 'A Publisher The Row Knew');
    is('...and the album it supplied', $r2->{album_title}, 'Serial');
}

# ANTI-TEST: none of this touches an ordinary Spotify TRACK. The tidy and the fill are both
# gated on the row being a podcast episode, so a music track keeps what Material sent and the
# handler is never consulted for it.
{
    $HANDLER_ASKED = undef;
    my $r3 = add(_client => $EPCL,
                 kind => 'track', trackname => 'Heart of Glass', artist => 'Blondie',
                 svc => 'spotty', favurl => 'spotify:track:7wMPFS9B5V7gg6hZ3UZ7hf');
    is('an ordinary Spotify track keeps its artist', $r3->{artist}, 'Blondie');
    is('...and the handler is never asked about it', $HANDLER_ASKED, undef);
}

# THE FAILURE SHAPE THE FILL MUST REFUSE, and the reason the guard is a duration rather than
# a "does it differ" test. Spotty's getMetadataFor has two EARLY RETURNS — no credentials, and
# no SSL — that set BOTH `artist` and `title` to a localised hint string and `duration => 0`
# (read verbatim from Spotty ProtocolHandler.pm, 2026-09-04). Those strings are non-empty and
# they differ from whatever the row holds, so the pre-fix code took them: the episode was
# stored titled "Please authorize this player…", permanently, with the same string as its
# artist and inside its dedupe key.
#
# It is reachable at ADD time in a way it is not at play time — this sub runs against a row
# the user tapped in a browse list, which is NOT the playing track, so nothing else has had to
# succeed against the service first.
#
# ANTI-TEST: drop the duration gate and both of these go red, the first naming the hint string
# it stored as the title. The positive controls above are what stop the gate being widened
# into refusing every fill.
{
    my $hint = 'Please authorize this player on your Spotify account';
    for my $c ([ 'dd3dd3dd3dd3dd3dd3dd3d', 'no credentials' ],
               [ 'ee3ee3ee3ee3ee3ee3ee3e', 'no SSL' ]) {
        my ($id, $why) = @$c;
        # duration => 0 is the shape, not an omission: the hint branches build a full hash.
        $HANDLER_META{"spotify://episode:$id"} = {
            title => $hint, artist => $hint, album => '', duration => 0,
        };
        my $b = add(_client => $EPCL, name => '2026-04-04 - Real Episode Title',
                    artist => 'a blurb the row supplied', svc => 'spotty',
                    favurl => "spotify:episode:$id");
        is("Spotty answering a $why hint does NOT become the title",
            ($b ? $b->{track_title} : 'nothing'), 'Real Episode Title');
        is("...nor the artist",  ($b ? $b->{artist} : 'nothing'), undef);
    }
}

# ...and the neighbouring shape, for the same reason: a cache MISS. Spotty returns `{}` with
# no title at all here (it fires an async fetch and answers what it has), so the fill has
# nothing to take even before the gate — asserted so that "the miss is harmless" is a checked
# fact rather than an assumption about a third party's code.
{
    $HANDLER_META{'spotify://episode:ff3ff3ff3ff3ff3ff3ff3f'} = {
        bitrate => '320k VBR', type => 'Ogg Vorbis (Spotify)',
    };
    my $m = add(_client => $EPCL, name => '2026-05-05 - Cache Cold',
                svc => 'spotty', favurl => 'spotify:episode:ff3ff3ff3ff3ff3ff3ff3f');
    is('a cold Spotty cache leaves the row exactly as it arrived',
        ($m ? $m->{track_title} : 'nothing'), 'Cache Cold');
}

# A DEEZER episode takes the identical path — this is the "no different from other services"
# assertion. Same fill, same reader, no per-service branch.
{
    my $u = 'deezerpodcast://927648402';
    $HANDLER_META{$u} = { title => 'The Floor', album => 'The Minimalists',
                          duration => 3122 };
    my $d = add(_client => $EPCL, kind => 'track', trackname => 'The Floor',
                svc => 'deezer', favurl => 'deezerpodcast://927648402');
    is('a Deezer episode stores', ($d ? $d->{kind} : 'nothing'), 'track');
    is('...and PLAYED finds it by url, exactly as for Spotify',
        (Plugins::ListenLater::DB::findTrackByUrl('deezerpodcast', $u) || {})->{id}, $d->{id});
}


# ---------------------------------------------------------------------------
# A TRACK ROW'S IDENTITY IS ITS PLAY URL, at the ADD end as well as the Played end.
#
# Played::_markPlayedTrack has always matched findTrackByUrl FIRST and only then looked at
# names. The add path decided sameness purely by NAME, behind two guards that both require
# `length $artist` — so the two ends disagreed about what a duplicate is. An artist-less track
# added from two surfaces (a queue row sends $ALBUMNAME, a browse row does not) skipped both
# guards, keyed differently, and stored TWICE for one url; Played then marked whichever row
# came back first and the twin sat in the list for ever.
# ANTI-TEST: remove the findTrackByUrl check in _insertTrackRow and the first two go red.
section('the same play url is the same track, whatever the row called it');
{
    my $u = 'qobuz://999111.flac';
    my $a = add(kind => 'track', trackname => 'Untitled', svc => 'qobuz', favurl => $u);
    # Same url, same (absent) artist, but a DIFFERENT album — the surface difference that used
    # to produce two keys and therefore two rows.
    my $b = add(kind => 'track', trackname => 'Untitled', name => 'Some Album',
                svc => 'qobuz', favurl => $u);
    is('an artist-less track stores once', ($a ? $a->{kind} : 'nothing'), 'track');
    is('...and the same url from another surface does NOT store again',
        (defined $b ? 'stored twice' : 'deduped'), 'deduped');
    is('...the surviving row is the first one, and still resolves by url',
        (Plugins::ListenLater::DB::findTrackByUrl('qobuz', $u) || {})->{id}, $a->{id});

    # ANTI-REGRESSION: a different track still stores separately — the url check must not
    # over-dedupe.
    my $c = add(kind => 'track', trackname => 'Something Else', svc => 'qobuz',
                favurl => 'qobuz://999222.flac');
    is('a different track still stores separately',
        (($c && $c->{id} != $a->{id}) ? 'two rows' : 'wrongly deduped'), 'two rows');

    # THE RESIDUAL THIS BLOCK USED TO PIN AS A LIMITATION IS FIXED (2026-09-10). Two genuinely
    # different tracks that are both artist-less AND share a title used to collapse: the name
    # key is '|||t:<title>' for both, and DB::add dedupes on it BEFORE _insertTrackRow's url
    # check is ever consulted, so the second add was reported "already saved" and lost. It was
    # left alone on the grounds that it needs a track with no artist at all and a second one
    # sharing its title, and that the obvious fix — re-keying every track row on its url —
    # owed a migration rung on a UNIQUE column.
    #
    # It does not, and that is the point of the fix: the collision is disambiguated LAZILY, at
    # the moment it happens, so no row already in the database is touched and no stored key is
    # rewritten. The first row keeps '|||t:<title>' for ever; only the SECOND row gets the
    # '|u:<source>:<url>' tail, and that row did not exist at all before.
    my $u2 = 'qobuz://999333.flac';
    my $d  = add(kind => 'track', trackname => 'Untitled', svc => 'qobuz', favurl => $u2);
    is('a second artist-less track sharing a title is STORED, not swallowed',
        (($d && $d->{id} != $a->{id}) ? 'two rows' : 'collapsed'), 'two rows');
    is('...the FIRST row keeps the key it already had — nothing owes a migration',
        Plugins::ListenLater::DB::get($a->{id})->{dedupe_key}, '|||t:untitled');
    is('...and only the second carries the url tail',
        ($d ? $d->{dedupe_key} : 'nothing'), '|untitled||u:qobuz:' . $u2);
    # Both must still be reachable by the identity they are keyed on, or Played loses one.
    is('the first still resolves by ITS url',
        (Plugins::ListenLater::DB::findTrackByUrl('qobuz', $u) || {})->{id}, $a->{id});
    is('...and the second by its own',
        (Plugins::ListenLater::DB::findTrackByUrl('qobuz', $u2) || {})->{id}, $d->{id});
    # The re-add, which is where a lazy fix goes wrong: it computes the NAMELESS key again and
    # lands on the first row again, so it must find its way to its OWN row. Asked through
    # DB::add directly, because what has to be right is the ANSWER, not just the row count.
    # Going through the add command cannot tell the two apart: with the url lookup removed the
    # INSERT hits UNIQUE(source,dedupe_key) and DIES, the command evals it away, and "nothing
    # was stored" then looks exactly like a clean dedupe from outside — while the user gets no
    # confirmation and the log gets a DBI error. Measured: this pair passed WITHOUT the lookup
    # until it was asked this way.
    my ($reId, $reDup) = eval {
        Plugins::ListenLater::DB::add({ source => 'qobuz', kind => 'track',
            track_title => 'Untitled', ref_kind => 'url', ref => { url => $u2 } }, 'later');
    };
    is('re-adding the second track answers "already saved" rather than dying',
        ($@ ? 'died' : ($reDup ? 'already saved' : 'stored again')), 'already saved');
    is('...and it names ITS row, not the title twin', ($reId // 'none'), $d->{id});
    is('...and there are exactly two rows with that title',
        scalar @{ Plugins::ListenLater::DB::dbh()->selectall_arrayref(
            "SELECT id FROM albums WHERE kind='track' AND track_title='Untitled'") }, 2);

    # THE CONTROLS. A key that carries a NAME must keep deduping on it, or this fix has
    # quietly disabled cross-surface and cross-source track dedupe.
    #
    # ANTI-TESTS for this whole block, measured: disable the disambiguation and 3 go red;
    # drop the second findAnyByKey and 2 go red, one of them showing the real consequence (the
    # INSERT hits the UNIQUE constraint and DIES); widen _keyIsNamelessTrack to every track
    # key and 2 go red. The last two only discriminate through DB::add directly — the add
    # command has its own earlier guards, and both assertions passed against a broken build
    # until they were asked at this level.
    my $n1 = add(kind => 'track', trackname => 'Named Song', artist => 'A Band',
                 svc => 'qobuz', favurl => 'qobuz://888111.flac');
    my $n2 = add(kind => 'track', trackname => 'Named Song', artist => 'A Band',
                 svc => 'qobuz', favurl => 'qobuz://888222.flac');
    is('a track WITH an artist still dedupes by name, different url or not',
        (defined $n2 ? 'stored twice' : 'deduped'), 'deduped');
    # ...and the same control at the level the narrowing actually lives. Through the add
    # command an artist-bearing track never reaches DB::add at all — _insertTrackRow's
    # findTrackByArtistTitle guard catches it first — so the assertion above passes whatever
    # DB::add does with a named key. Measured: widening _keyIsNamelessTrack to every track key
    # left the whole suite green until this pair existed.
    my ($nId, $nDup) = Plugins::ListenLater::DB::add({ source => 'qobuz', kind => 'track',
        artist => 'A Band', track_title => 'Named Song', ref_kind => 'url',
        ref => { url => 'qobuz://888999.flac' } }, 'later');
    is('DB::add itself still dedupes a NAMED track key across different urls',
        ($nDup ? 'already saved' : 'stored a second row'), 'already saved');
    is('...answering with the row that already held the name', $nId, $n1->{id});
    is('...and the row it deduped to is the first one',
        ($n1 ? Plugins::ListenLater::DB::get($n1->{id})->{dedupe_key} : 'nothing'),
        'a band|||t:named song');
    # An artist-less track with no url has nothing better to key on, so it keeps the old
    # behaviour deliberately — the safer of two guesses, and stated so it is not read as an
    # oversight.
    my $f1 = add(kind => 'track', trackname => 'No Url Song', svc => 'qobuz',
                 favurl => 'qobuz://888333.flac');
    is('a nameless track with a url stores', ($f1 ? 'stored' : 'collapsed'), 'stored');
}

section('0.1.136 — a Podcasts-app row now falls to the generic online-* Add');
is('a built-in podcast row stores NOTHING through the generic action',
   podcast_row_add(), 'nothing stored');

printf "\n%d passed, %d failed\n", $pass, $fail;
exit($fail ? 1 : 0);
