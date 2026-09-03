#!/usr/bin/env perl
# Does _searchService hand each service plugin its search query in the encoding that
# service's own URL layer expects?
#
# There is no single right spelling, and that is the whole point of this suite. The
# service plugins disagree: Qobuz escapes with uri_escape_utf8, Tidal transliterates
# with Text::Unidecode and Spotty escapes in _prepareCall — all three want CHARACTERS —
# while Deezer's complex_to_query and Bandcamp want OCTETS. Handing the character camp
# octets double-encodes, so "Sigur Rós" goes out as "Sigur RÃ³s"/"Sigur RA3s" and the
# search returns NOTHING for any non-ASCII artist. The failure is SILENT: replay simply
# reports "Could not find this album to play", which is indistinguishable from the album
# genuinely not being on the service.
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
for my $svc (qw(qobuz tidal deezer)) {
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

my $LATIN1 = "Sigur R\xf3s";   # not valid UTF-8: decode must decline and change nothing
is('latin-1 in: qobuz passes it through unmangled', ask('qobuz', $LATIN1), lc $LATIN1);

printf "\n%d passed, %d failed\n", $pass, $fail;
exit($fail ? 1 : 0);
