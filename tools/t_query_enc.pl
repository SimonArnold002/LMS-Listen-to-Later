#!/usr/bin/env perl
# Does _searchService hand each service plugin its search query in the encoding that
# service's own URL layer expects?
#
# There is no single right spelling, and that is the whole point of this suite. The
# service plugins disagree: Qobuz escapes with uri_escape_utf8, Tidal transliterates
# with Text::Unidecode and Spotty escapes in _prepareCall — all three want CHARACTERS —
# while Deezer's complex_to_query wants OCTETS. Handing the character camp octets
# double-encodes, so "Sigur Rós" goes out as "Sigur RÃ³s"/"Sigur RA3s" and the search
# returns JUNK for any non-ASCII artist — MEASURED live 2026-09-03 as 1 real hit of 88
# on Qobuz and 8 of 74 on TIDAL, not zero. The failure is SILENT either way: _albumMatches
# rejects the junk and replay reports "Could not find this album to play", which is
# indistinguishable from the album genuinely not being on the service. Say
# wrong/incomplete results, never "no results" — describing it as empty is what stopped it
# being recognised for two months.
#
# BANDCAMP IS IN NEITHER CAMP and is tested for exactly that, because "not covered" and
# "covered by an invariant" look identical from outside. Its branch sends the combined
# _norm("$artist $album"), which is ASCII-only by construction, so the two encodings are
# byte-identical there and no conversion applies. The assertions below pin the INVARIANT
# rather than a camp, so a change that starts sending a raw artist or title down that
# branch goes red and has to pick a camp.
#
# The sibling ListenBrainz plugin carries the same split as a per-adapter `query_enc`
# (LBF 0.9.82, after the Sigur Rós failure found in Discography 2026-07-10). LL had one
# spelling for all four branches until this suite was written.
#
# THE FIXTURE MUST BE UPGRADED, and that is not a detail. A "\x{f3}" literal is stored
# latin-1 with utf8::is_utf8 FALSE, so the encode at the top of _searchService never
# fires and every branch looks correct. DBD::SQLite (sqlite_unicode => 1, DB.pm) and
# JSON::XS both hand back UPGRADED strings, which is the shape that reaches the sub in
# real use — see DB.pm's foldLatin note. Without the utf8::upgrade below this suite
# passes against the bug it exists to catch.
use strict;
use warnings;
use FindBin;
require "$FindBin::Bin/t_stubs.pl";

my %GOT;   # service tag => the query string that service's plugin was handed

# --- fake service plugins ---------------------------------------------------
# They record the query and call back with nothing. Deliberately dumb: the only thing
# under test is what _searchService PASSES, so a stub that returned candidates would
# just add ways for an assertion to pass for the wrong reason.
{
    package Plugins::Qobuz::Plugin;
    sub getAPIHandler { bless {}, 'FakeAPI::Qobuz' }
    sub _albumItem    { {} }
    $INC{'Plugins/Qobuz/Plugin.pm'} = __FILE__;
    package FakeAPI::Qobuz;
    sub search { my ($s, $cb, $q) = @_; $GOT{qobuz} = $q; $cb->({}) }
}
{
    package Plugins::TIDAL::Plugin;
    sub getAPIHandler { bless {}, 'FakeAPI::TIDAL' }
    sub _renderAlbum  { {} }
    $INC{'Plugins/TIDAL/Plugin.pm'} = __FILE__;
    package FakeAPI::TIDAL;
    sub search { my ($s, $cb, $args) = @_; $GOT{tidal} = $args->{search}; $cb->([]) }
}
{
    package Plugins::Deezer::Plugin;
    sub getAPIHandler { bless {}, 'FakeAPI::Deezer' }
    sub _renderAlbum  { {} }
    $INC{'Plugins/Deezer/Plugin.pm'} = __FILE__;
    package FakeAPI::Deezer;
    sub search { my ($s, $cb, $args) = @_; $GOT{deezer} = $args->{search}; $cb->([]) }
}
# Spotty differs from the three above in every mechanical detail, and the stub keeps each
# difference so the branch under test is actually reached: getAPIHandler is a CLASS method,
# the renderer lives in OPML rather than Plugin (and the branch tests for BOTH), and the
# search key is `query`, not `search`.
{
    package Plugins::Spotty::Plugin;
    sub getAPIHandler { bless {}, 'FakeAPI::Spotty' }
    $INC{'Plugins/Spotty/Plugin.pm'} = __FILE__;
    package Plugins::Spotty::OPML;
    sub _albumItem { {} }
    $INC{'Plugins/Spotty/OPML.pm'} = __FILE__;
    package FakeAPI::Spotty;
    sub search { my ($s, $cb, $args) = @_; $GOT{spotify} = $args->{query}; $cb->([]) }
}
# Bandcamp is the odd one out in shape as well as in encoding: no API handler at all, a
# plain module function reached through `require Plugins::Bandcamp::Search` (so the %INC
# entry is what makes the branch reachable), and the query is the COMBINED artist+album,
# because Bandcamp's own recall needs the title. Its callback reads $res->{items}.
{
    package Plugins::Bandcamp::Search;
    sub search { my ($client, $cb, $args) = @_; $GOT{bandcamp} = $args->{search}; $cb->({}) }
    $INC{'Plugins/Bandcamp/Search.pm'} = __FILE__;
}

ll_require('DB', 'Sources');

my ($pass, $fail) = (0, 0);
sub is {
    my ($desc, $got, $want) = @_;
    my $ok = (!defined $got && !defined $want)
          || (defined $got && defined $want && "$got" eq "$want");
    $ok ? $pass++ : $fail++;
    printf "%s %-58s got=%-24s want=%s\n", ($ok ? 'ok  ' : 'FAIL'), $desc,
        (defined $got ? "'$got'" : '(undef)'), (defined $want ? "'$want'" : '(undef)');
}
sub section { printf "\n== %s\n", $_[0] }

# Run one search and hand back what the service received.
sub ask {
    my ($svc, $artist) = @_;
    %GOT = ();
    Plugins::ListenLater::Sources::_searchService(
        undef, $svc,
        { source => $svc, artist => $artist, album_title => 'Takk...', year => '2005' },
        sub {},
    );
    return $GOT{$svc};
}

my $ACCENT = "Sigur R\x{f3}s";
utf8::upgrade($ACCENT);      # as sqlite_unicode / JSON::XS hand it back — see the header

# ---------------------------------------------------------------------------
section('the fixture is the shape that reaches _searchService');
# If this ever fails the whole suite is vacuous, so it is asserted rather than assumed.
is('the stored artist is a CHARACTER string', (utf8::is_utf8($ACCENT) ? 1 : 0), 1);

# ---------------------------------------------------------------------------
section('each branch gets the encoding its own URL layer wants');

is('qobuz  is handed CHARACTERS (uri_escape_utf8)',
   (utf8::is_utf8(ask('qobuz',  $ACCENT)) ? 'chars' : 'octets'), 'chars');
is('tidal  is handed CHARACTERS (Text::Unidecode)',
   (utf8::is_utf8(ask('tidal',  $ACCENT)) ? 'chars' : 'octets'), 'chars');
is('spotify is handed CHARACTERS (uri_escape_utf8 in _prepareCall)',
   (utf8::is_utf8(ask('spotify', $ACCENT)) ? 'chars' : 'octets'), 'chars');
is('deezer is handed OCTETS (complex_to_query)',
   (utf8::is_utf8(ask('deezer', $ACCENT)) ? 'chars' : 'octets'), 'octets');

# ---------------------------------------------------------------------------
section('the URL each service then builds');
# The encoding flag above is the mechanism; this is the consequence, and it is what a
# reader of this file actually cares about. Qobuz's escape is reproduced exactly (same
# module, same call); Tidal's transliteration is modelled, because Text::Unidecode is not
# a dependency of this repo and installing one for a test would be worse than modelling
# the two octets that matter.
require URI::Escape;

my $qWant = URI::Escape::uri_escape_utf8(lc $ACCENT);
is('qobuz  escapes to the single-encoded form',
   URI::Escape::uri_escape_utf8(ask('qobuz', $ACCENT)), $qWant);

# unidecode reads a byte string one octet at a time as Latin-1: the UTF-8 pair C3 B3
# ("ó") becomes "Ã" + "³", which it maps to "A" and "3".
my %UNIDECODE = ("\xc3" => 'A', "\xb3" => '3', "\x{f3}" => 'o');
sub unidecode_model { join '', map { $UNIDECODE{$_} // $_ } split //, $_[0] }
is('tidal  transliterates to the real name',
   unidecode_model(ask('tidal', $ACCENT)), 'Sigur Ros');

# ---------------------------------------------------------------------------
section('an ASCII artist is unaffected on every branch');
# The positive control. Without it the suite could be satisfied by a change that mangles
# every query equally, and ASCII is the overwhelmingly common case — a regression here
# would break replay for everyone rather than for accented artists only.
for my $svc (qw(qobuz tidal deezer spotify)) {
    is("$svc leaves a plain name alone", ask($svc, 'Radiohead'),
       ($svc eq 'qobuz' ? 'radiohead' : 'Radiohead'));   # the qobuz branch lowercases
}

# ---------------------------------------------------------------------------
section('both conversions fail safe on input that is already the wrong shape');
# utf8::decode leaves a non-UTF-8 byte string untouched and utf8::encode is a no-op on
# octets, so a raw-CLI add (which arrives as octets — see DB.pm's foldLatin note) must
# not be corrupted on its way to a service.
my $OCTETS = "Sigur R\x{f3}s"; utf8::encode($OCTETS);
is('octets in: deezer still gets those exact octets', ask('deezer', $OCTETS), $OCTETS);
is('octets in: qobuz recovers the characters',
   (utf8::is_utf8(ask('qobuz', $OCTETS)) ? 'chars' : 'octets'), 'chars');
# The one that pins the fix: this branch passed the RAW artist for a while, on the grounds
# that every path reaching it already holds characters. Nothing enforces that, and a raw-CLI
# add is the counter-example the other three branches are already hardened against.
is('octets in: spotify recovers the characters too',
   (utf8::is_utf8(ask('spotify', $OCTETS)) ? 'chars' : 'octets'), 'chars');

my $LATIN1 = "Sigur R\xf3s";   # not valid UTF-8: decode must decline and change nothing
is('latin-1 in: qobuz passes it through unmangled', ask('qobuz', $LATIN1), lc $LATIN1);


# ---------------------------------------------------------------------------
section('bandcamp is exempt from both camps, and the invariant is what makes it exempt');
# The gap this section closes is not a bug — it is a SILENCE. Bandcamp was listed under
# OCTETS in the encoding comment while its branch applied no conversion at all, and the
# suite had no fixture, so "exempt because the query is ASCII by construction" and "nobody
# checked" were indistinguishable. Assert the reason, not the camp.
for my $in ( [ 'characters', $ACCENT ], [ 'octets', $OCTETS ], [ 'latin-1', $LATIN1 ] ) {
    my ($what, $v) = @$in;
    my $q = ask('bandcamp', $v);
    is("bandcamp: $what in gives an ASCII-only query",
       (defined $q && $q =~ /^[a-z0-9 ]*$/ ? 'ascii' : "NOT ascii ($q)"), 'ascii');
}
# ...which is what makes the two encodings the SAME STRING here — the whole reason no
# conversion is applied. If this ever fails, that branch has acquired a camp.
is('bandcamp: characters and octets produce a byte-identical query',
   (ask('bandcamp', $ACCENT) eq ask('bandcamp', $OCTETS) ? 'identical' : 'DIFFER'),
   'identical');
# It is also the only branch sent the artist AND the album (Bandcamp's recall needs the
# title), so a refactor that "unified" it onto $artistChars/$artistBytes would silently
# drop the album half. Pinned so that unification has to be deliberate.
is('bandcamp: the query carries the album title too, not just the artist',
   (ask('bandcamp', $ACCENT) =~ /takk/ ? 'album included' : 'ARTIST ONLY'), 'album included');

printf "\n%d passed, %d failed\n", $pass, $fail;
exit($fail ? 1 : 0);
