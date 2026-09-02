#!/usr/bin/env perl
# Regression tests for the PRIVATE favurl params — the sibling-plugin handshake
# (Plugin::_stripPrivateParams): '?cover=', '?b=', '&a=', '&y=', '&al=', '&rt=', '&tc='.
#
# WHY THIS SUITE EXISTS, AND WHY IT DRIVES THE REAL SUB
#
# 0.1.89 shipped the '&tc=' receiver with this line:
#
#     $favTracks = $1 + 0 if $1 =~ /^\d{1,3}$/ && $1 > 0;
#
# The strip works and $1 holds the count — but the validation match has no capture group of
# its own, and in Perl a SUCCESSFUL match still resets $1 to undef. So the second $1 was
# always undef, every count was silently discarded, and the whole handshake was inert (plus a
# "Use of uninitialized value $1 in numeric gt" warning on every LBF add).
#
# It shipped VERIFIED: a 24-check script pulled the seven strip regexes out of Plugin.pm by
# grep and applied them in source order. Every check passed, because the bug was not in the
# regexes — it was in the four lines of validation NEXT to them, which that script never ran.
# The sibling plugin's own '&tc=' had already failed the same way (its tests supplied the
# field they were meant to be checking for). Hence the rule in CLAUDE.md: an assertion must
# not be able to pass vacuously, and a test of extraction must call the extraction.
#
# So: no regexes are copied or re-derived here. Every case calls the shipped sub, on the real
# favurl shapes LBF/PFR/Qobuz/Tidal/Deezer/Bandcamp actually send, and asserts BOTH halves of
# its contract — what came out, AND that the favurl left behind is clean.
use strict;
use warnings;
use FindBin;
require "$FindBin::Bin/t_stubs.pl";

ll_require('DB', 'Sources', 'Podcast', 'Browse', 'Played', 'Plugin');

# Any warning is a failure. NOTE what this does and does not buy: the 0.1.89 bug WOULD have
# announced itself as "Use of uninitialized value $1 in numeric gt" on every single add — but
# Plugin.pm has `use strict` and NOT `use warnings` (unlike Browse/DB/Played/Sources), so on
# the server it was completely silent. Warnings are lexical to the file, so this handler
# cannot resurrect them for code inside Plugin.pm; it catches warnings from THIS file and
# from the modules that do enable them. Adding `use warnings` to Plugin.pm would have caught
# the bug on the first add — worth considering, but it is a change to a 2000-line module and
# belongs in its own pass, not smuggled in with a fix.
my @warnings;
$SIG{__WARN__} = sub { push @warnings, $_[0] };

my ($pass, $fail) = (0, 0);
sub is {
    my ($desc, $got, $want) = @_;
    my $ok = (!defined $got && !defined $want)
          || (defined $got && defined $want && "$got" eq "$want");
    $ok ? $pass++ : $fail++;
    printf "%s %-58s got=%-28s want=%s\n", ($ok ? 'ok  ' : 'FAIL'), $desc,
        (defined $got ? "'$got'" : '(undef)'), (defined $want ? "'$want'" : '(undef)');
}
sub section { printf "\n== %s\n", $_[0] }

# The one entry point under test. Returns ($fields, $residual_favurl).
sub strip {
    my ($favurl) = @_;
    my %p = (favurl => $favurl);
    my $out = Plugins::ListenLater::Plugin::_stripPrivateParams(\%p);
    return ($out, $p{favurl});
}

# ---------------------------------------------------------------------------
section('playlist detection from favurl/image');
my @playlist = (
    ['tidal://playlist:abc-def-123', 'https://example.com/cover.jpg', 'tidal', 'abc-def-123'],
    ['deezer://playlist:456789', 'https://example.com/cover.jpg', 'deezer', '456789'],
    ['qobuz://album:zzz', 'https://static.qobuz.com/images/playlists/69183531_x_rectangle.jpg', 'qobuz', '69183531'],
    ['qobuz://album:zzz', 'https://static.qobuz.com/images/covers/xx/yy/1234_600.jpg', undef, undef],
    ['tidal://album:529626253', 'https://example.com/cover.jpg', undef, undef],
);
# playlistFromRow returns a LIST — ($source, $id), or the empty list for "not a playlist".
for my $case (@playlist) {
    my ($fav, $img, $src, $id) = @$case;
    my @got  = Plugins::ListenLater::Sources::playlistFromRow($fav, $img);
    my $want = defined $src ? "$src|$id" : 'undef';
    is("playlistFromRow: $fav", (@got ? join('|', @got) : 'undef'), $want);
}

# The scheme and the container ref must be matched SEPARATELY: '^(\w+)://' eats both
# slashes, so a single anchored '^(\w+)://.*?[:/]playlist:' can never match the shape Tidal
# and Deezer actually send — i.e. the common case would be the silent failure.
is('a bare service://playlist: url matches (the anchoring trap)',
   join('|', Plugins::ListenLater::Sources::playlistFromRow('tidal://playlist:uuid-1', undef)),
   'tidal|uuid-1');
is('...and so does one with a path in front of it',
   join('|', Plugins::ListenLater::Sources::playlistFromRow('deezer://user/me/playlist:99', undef)),
   'deezer|99');
is('neither argument present: not a playlist',
   (Plugins::ListenLater::Sources::playlistFromRow(undef, undef) ? 'playlist' : 'no'), 'no');
is('a proxied Qobuz playlist cover is unescaped first',
   join('|', Plugins::ListenLater::Sources::playlistFromRow(undef,
       '/imageproxy/https%3A%2F%2Fstatic.qobuz.com%2Fimages%2Fplaylists%2F69183531_x_rectangle.jpg/image.jpg')),
   'qobuz|69183531');

# The other half of the invariant: a 'playlist:' url is a CONTAINER, so favurlIsTrack must
# keep answering 0 for it. If it ever said 1, the track branch would claim the row before the
# playlist branch is ever consulted — and it is checked first, deliberately (see
# Plugin::_addCtxCommand).
for my $u ('tidal://playlist:abc-def-123', 'deezer://playlist:456789', 'qobuz://playlist:69183531') {
    is("favurlIsTrack says 0 for $u", Plugins::ListenLater::Sources::favurlIsTrack($u), 0);
}

# ---------------------------------------------------------------------------
section("'&tc=' track count — the 0.1.89 regression");

my ($f, $u) = strip('qobuz://album:dmuizydvpcxsy?a=Temples&tc=3&y=2026');
is('tc=3 in the middle -> 3',            $f->{tracks}, 3);
is('...artist still read',               $f->{artist},  'Temples');
is('...year still read',                 $f->{year},    2026);
is('...favurl left clean',               $u, 'qobuz://album:dmuizydvpcxsy');

($f, $u) = strip('qobuz://album:abc?tc=12');
is('tc as the ONLY param -> 12',         $f->{tracks}, 12);
is('...favurl left clean',               $u, 'qobuz://album:abc');

($f, $u) = strip('qobuz://album:abc?a=Bjork&tc=1');
is('tc LAST -> 1',                       $f->{tracks}, 1);
is('...favurl left clean',               $u, 'qobuz://album:abc');

($f, $u) = strip('qobuz://album:abc?tc=999&y=2026');
is('tc FIRST, 3 digits -> 999',          $f->{tracks}, 999);
is('...favurl left clean',               $u, 'qobuz://album:abc');

# A count is a NUMBER downstream: Played::_totalTracks thresholds against it, so a string
# that merely looks numeric is not enough — '3' from a regex must arrive as 3.
($f) = strip('qobuz://album:abc?tc=3');
is('the count is numeric, not a string', (defined $f->{tracks} && $f->{tracks} == 3 ? 'num' : 'no'), 'num');

section('bogus counts are STRIPPED but REJECTED (never stored)');
# Both halves matter: a junk value must not reach track_count (60% of nonsense is an
# unreachable Played threshold), and it must not be left in the favurl either.
for my $bad (qw(0 abc 1000 -1 3.5 03x)) {
    my ($bf, $bu) = strip("qobuz://album:abc?tc=$bad");
    is("tc=$bad rejected",               $bf->{tracks}, undef);
    is("tc=$bad still stripped",         $bu, 'qobuz://album:abc');
}
my ($ef, $eu) = strip('qobuz://album:abc?tc=');
is('tc= (empty) rejected',               $ef->{tracks}, undef);
is('tc= (empty) still stripped',         $eu, 'qobuz://album:abc');

# ---------------------------------------------------------------------------
section("'&rt=' release type, and the pair that 0.1.88 depends on");
($f, $u) = strip('qobuz://album:abc?a=Wet+Leg&rt=single&tc=3');
is('rt read',                            $f->{rel_type}, 'single');
is('tc read alongside it',               $f->{tracks},   3);
is('favurl clean',                       $u, 'qobuz://album:abc');
# This is the whole point of the handshake: Sources::singleIsWrong must be able to disprove
# the MB claim at INSERT time, with no service call. Inert tc = it never could.
is('an MB single of 3 IS disproved',
    Plugins::ListenLater::Sources::singleIsWrong($f->{rel_type}, $f->{tracks}), 1);
is('...and reclassifies as ep',
    Plugins::ListenLater::Sources::relTypeFor(service => $f->{rel_type}, count => $f->{tracks}), 'ep');

($f) = strip('qobuz://album:abc?rt=single&tc=1');
is('a real 1-track single stands',
    Plugins::ListenLater::Sources::relTypeFor(service => $f->{rel_type}, count => $f->{tracks}), 'single');

# ---------------------------------------------------------------------------
section("'&a=' must not eat '&al=' (0.1.71)");
# Both senders escape with URI::Escape::uri_escape_utf8 (verified in LBF's and PFR's
# _attachFavUrl), so a space arrives as %20 — never as '+'.
($f, $u) = strip('qobuz://album:abc?al=Extra%20Mile&a=Will%20Sheff&tc=9');
is('clean album title from al=',         $f->{album},  'Extra Mile');
is('artist from a=',                     $f->{artist}, 'Will Sheff');
is('tc survives both',                   $f->{tracks}, 9);
is('favurl clean',                       $u, 'qobuz://album:abc');

($f) = strip('qobuz://album:abc?a=Beach%20House');
is('a= alone: no album leaks in',        $f->{album}, undef);

# A literal '+' stays a '+'. uri_unescape does URI unescaping, NOT form decoding, and that is
# correct here: the senders never emit '+' for a space, so translating '+' would corrupt the
# artists and titles that genuinely contain one.
($f) = strip('qobuz://album:abc?a=Bass%20%2B%20Drums');
is("'+' survives as itself",             $f->{artist}, 'Bass + Drums');

# ---------------------------------------------------------------------------
section('cover art and the Bandcamp page url');
($f, $u) = strip('qobuz://album:abc?cover=https%3A%2F%2Fstatic.qobuz.com%2Fimages%2Fcovers%2Fab%2Fcd%2Fabc_600.jpg&tc=8');
is('cover unescaped',                    $f->{cover},
    'https://static.qobuz.com/images/covers/ab/cd/abc_600.jpg');
is('tc read after the cover',            $f->{tracks}, 8);
is('favurl clean',                       $u, 'qobuz://album:abc');

# Bandcamp packs art AND page url in one escaped '?b=' as '<art>|<url>'.
($f, $u) = strip('bandcamp://album:1234567?b=https%3A%2F%2Ff4.bcbits.com%2Fimg%2Fa123_16.jpg%7Chttps%3A%2F%2Fartist.bandcamp.com%2Falbum%2Fthe-record');
is('b= art half',                        $f->{cover}, 'https://f4.bcbits.com/img/a123_16.jpg');
is('b= page-url half',                   $f->{bandcamp_url}, 'https://artist.bandcamp.com/album/the-record');
is('favurl clean',                       $u, 'bandcamp://album:1234567');
# Bandcamp sends no count (it has none until the page is fetched) — must fall through to the
# background resolve, not invent one.
is('no tc from Bandcamp',                $f->{tracks}, undef);

# ---------------------------------------------------------------------------
section('a real full LBF favurl, every param at once');
($f, $u) = strip('qobuz://album:dmuizydvpcxsy?cover=https%3A%2F%2Fstatic.qobuz.com%2Fimages%2Fcovers%2Fab%2Fcd%2Fx_600.jpg&a=Temples&y=2026&rt=album&tc=11');
is('cover',      $f->{cover}, 'https://static.qobuz.com/images/covers/ab/cd/x_600.jpg');
is('artist',     $f->{artist},   'Temples');
is('year',       $f->{year},     2026);
is('rel_type',   $f->{rel_type}, 'album');
is('tracks',     $f->{tracks},   11);
is('nothing left behind in the favurl', $u, 'qobuz://album:dmuizydvpcxsy');

# ---------------------------------------------------------------------------
section('NATIVE favurls are byte-for-byte untouched');
# The whole scheme rests on this: these params are ours, and a normal streaming Add must be
# unaffected. A native favurl has no query string, so nothing may fire.
for my $native (
    'qobuz://album:dmuizydvpcxsy',
    'tidal://album:412345678',
    'deezer://album:301234',
    'bandcamp://album:1234567',
    'qobuz://123456789.flac',
    'deezer://1234567.flc',
    'podcast://https://feed.example.com/ep/42.mp3',
) {
    my ($nf, $nu) = strip($native);
    is("unchanged: $native", $nu, $native);
    my @set = grep { defined $nf->{$_} } sort keys %$nf;
    is('...and no field set',            (@set ? join(',', @set) : 'none'), 'none');
}

# An undef favurl (a library add, Now Playing) must be a clean no-op, not a crash.
my %none = (favurl => undef);
my $nout = Plugins::ListenLater::Plugin::_stripPrivateParams(\%none);
is('undef favurl: no fields',            (grep { defined } values %$nout) ? 'some' : 'none', 'none');
is('undef favurl: still undef',          $none{favurl}, undef);

# ---------------------------------------------------------------------------
section('Spotify URI normalisation (Sources::normaliseFavurl)');

# Spotty sets favorites_url to a bare Spotify URI, with no '//' anywhere:
#   album spotify:album:<id> | track spotify:track:<id> | playlist spotify:playlist:<id>
# Every favurl reader in the plugin is anchored on '^(\w+)://', so until this sub runs a
# Spotify album reads as source 'library', a Spotify track is not seen as a track, and the
# album id sitting in the favurl is never captured. Asserted through the SHIPPED sub, and
# then through the four readers that consume its output — asserting the rewritten string
# alone would prove only that a regex ran, not that anything downstream now answers right.
sub norm { Plugins::ListenLater::Sources::normaliseFavurl($_[0]) }

is('album URI gains //',        norm('spotify:album:1DFixLWuPkv3KT3TnV35m3'), 'spotify://album:1DFixLWuPkv3KT3TnV35m3');
is('track URI gains //',        norm('spotify:track:4uLU6hMCjMI75M1A2tKUQC'), 'spotify://track:4uLU6hMCjMI75M1A2tKUQC');
is('playlist URI gains //',     norm('spotify:playlist:37i9dQZF1DXcBWIGoYBM5M'), 'spotify://playlist:37i9dQZF1DXcBWIGoYBM5M');
is('artist URI gains //',       norm('spotify:artist:0OdUWJ0sBjDrqHygGUXeCF'), 'spotify://artist:0OdUWJ0sBjDrqHygGUXeCF');
is('episode URI gains //',      norm('spotify:episode:512ojhOuo1ktJprKbVcKyQ'), 'spotify://episode:512ojhOuo1ktJprKbVcKyQ');
# The legacy playlist form. Only the FIRST segment is rewritten; the 'playlist:<id>' tail
# has to survive intact, because that tail is what playlistFromRow reads the id from.
is('legacy user playlist form', norm('spotify:user:bob:playlist:37i9dQZF1DX'), 'spotify://user:bob:playlist:37i9dQZF1DX');

# It must be inert on everything else. A false rewrite here would corrupt a working favurl.
for my $other (
    'qobuz://album:dmuizydvpcxsy', 'tidal://album:412345678', 'deezer://album:301234',
    'bandcamp://album:1234567', 'qobuz://123456789.flac',
    'spotify://album:already',                 # already normalised — must not double up
    'spotify:unknowntype:xyz',                 # a type we do not judge is left alone
    'notspotify:album:xyz',                    # anchored: only a whole Spotify URI matches
) {
    is("inert: $other", norm($other), $other);
}
is('undef is a no-op',          norm(undef), undef);
is('empty string is a no-op',   norm(''), '');

section('...and the readers that consume it now answer correctly');

# sourceFromUrl: the album case that used to come back 'library'.
is('album -> source spotify',   Plugins::ListenLater::Sources::sourceFromUrl(norm('spotify:album:abc')), 'spotify');
is('track -> source spotify',   Plugins::ListenLater::Sources::sourceFromUrl(norm('spotify:track:abc')), 'spotify');

# favurlIsTrack: containers no, audio yes — and NONE of these may reach the fail-open
# branch, which logs a warning. The no-warnings check at the end of this file is what
# actually enforces that, so these cases are deliberately run before it.
is('album is not a track',      Plugins::ListenLater::Sources::favurlIsTrack(norm('spotify:album:abc')), 0);
is('playlist is not a track',   Plugins::ListenLater::Sources::favurlIsTrack(norm('spotify:playlist:abc')), 0);
is('artist is not a track',     Plugins::ListenLater::Sources::favurlIsTrack(norm('spotify:artist:abc')), 0);
is('show is not a track',       Plugins::ListenLater::Sources::favurlIsTrack(norm('spotify:show:abc')), 0);
is('legacy playlist not track', Plugins::ListenLater::Sources::favurlIsTrack(norm('spotify:user:bob:playlist:abc')), 0);
is('track IS a track',          Plugins::ListenLater::Sources::favurlIsTrack(norm('spotify:track:abc')), 1);
is('episode IS a track',        Plugins::ListenLater::Sources::favurlIsTrack(norm('spotify:episode:abc')), 1);

# playlistFromRow: both spellings must yield the same id, since _streamingPlaylistNode
# rebuilds the short URI from it either way.
{
    my ($src, $pid) = Plugins::ListenLater::Sources::playlistFromRow(norm('spotify:playlist:37i9dQZF1DX'), undef);
    is('playlist row -> source',  $src, 'spotify');
    is('playlist row -> id',      $pid, '37i9dQZF1DX');
    my ($src2, $pid2) = Plugins::ListenLater::Sources::playlistFromRow(norm('spotify:user:bob:playlist:37i9dQZF1DX'), undef);
    is('legacy row -> source',    $src2, 'spotify');
    is('legacy row -> same id',   $pid2, '37i9dQZF1DX');
}

# The album-id capture in _addCtxCommand is a plain '(?:[:/])album:(…)' match on the
# favurl. It is generic, but it never ran on Spotify before, because the branch holding it
# is guarded by a '^(\w+)://' scheme test. Pin that it now extracts the id.
{
    my ($aid) = norm('spotify:album:1DFixLWuPkv3KT3TnV35m3') =~ m{(?:[:/])album:([A-Za-z0-9._-]+)};
    is('album id recovered from favurl', $aid, '1DFixLWuPkv3KT3TnV35m3');
}

# The strip runs BEFORE the normalise in _addCtxCommand, and a Spotify favurl carries no
# handshake params (the sibling plugin leaves Spotify favurls undecorated, because Spotty's
# own album:(.*) is greedy and would swallow one). Confirm the strip is a clean no-op on it.
{
    my ($sf, $su) = strip('spotify:album:1DFixLWuPkv3KT3TnV35m3');
    is('strip leaves Spotify URI alone', $su, 'spotify:album:1DFixLWuPkv3KT3TnV35m3');
    my @set = grep { defined $sf->{$_} } sort keys %$sf;
    is('...and sets no field',           (@set ? join(',', @set) : 'none'), 'none');
}

section('the browse command -> source alias (Sources::sourceFromSvc)');

# Spotty registers its menu under `tag => 'spotty'`, so Material's $SERVICE says 'spotty'
# for a service every other part of this plugin calls 'spotify'.
is("svc 'spotty' -> spotify",   Plugins::ListenLater::Sources::sourceFromSvc('spotty'), 'spotify');
is("svc 'Spotty' -> spotify",   Plugins::ListenLater::Sources::sourceFromSvc('Spotty'), 'spotify');
is("svc 'spotify' -> spotify",  Plugins::ListenLater::Sources::sourceFromSvc('spotify'), 'spotify');
is("svc 'qobuz' unaffected",    Plugins::ListenLater::Sources::sourceFromSvc('qobuz'), 'qobuz');
# The exact-match discipline knownSource is held to must survive the alias: a home-shelf id
# still answers '' so the cover sniff gets its turn, rather than being matched loosely.
is("home shelf id -> ''",       Plugins::ListenLater::Sources::sourceFromSvc('SpottyExtrasspotty'), '');
is("'QobuzExtrasqobuz' -> ''",  Plugins::ListenLater::Sources::sourceFromSvc('QobuzExtrasqobuz'), '');
is("'spottyfoo' -> ''",         Plugins::ListenLater::Sources::sourceFromSvc('spottyfoo'), '');
is("undef -> ''",               Plugins::ListenLater::Sources::sourceFromSvc(undef), '');

# ---------------------------------------------------------------------------
section('no warnings emitted');
is('warning count', scalar(@warnings), 0);
printf "  warning: %s", $_ for @warnings;

printf "\n%d passed, %d failed\n", $pass, $fail;
exit($fail ? 1 : 0);
