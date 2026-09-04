#!/usr/bin/env perl
# DOES A PODCAST FEED'S TEXT REACH THE DB IN THE SAME REPRESENTATION AS EVERY OTHER SOURCE?
#
# An RSS body is RAW BYTES all the way in: Slim::Networking::SimpleHTTP::Base::content is
# `${ $self->contentRef }` and there is no charset step anywhere above _parseFeed. Nothing
# else in this plugin is like that — Material's params are decoded by Request::fixEncoding
# before a handler sees them, service JSON comes back decoded from JSON::XS, and the plugin's
# own handle sets `sqlite_unicode`. The feed was the one producer still handing octets to a
# consumer that wanted characters, and it broke in three separate ways:
#
#  1. Storage. `sqlite_unicode` takes CHARACTERS, so raw "Bj\xc3\xb6rk" stored codepoints
#     U+00C3,U+00B6 and the list rendered "BjÃ¶rk". No entity needed — this hit EVERY
#     accented episode title and show name, and is the half a user actually sees.
#  2. The dedupe key. _clean's `chr($1)` entity pass put byte 0xF6 into an unflagged string
#     for "Bj&#246;rk", which is not valid UTF-8, so DB::foldLatin's decode failed, the fold
#     was SKIPPED, and the key came out 'bj rk' against 'bjork' from every other producer.
#     dedupe_key is UNIQUE and permanent, and Played::findSavedTrack then never matches the
#     row — the episode can never be marked played.
#  3. Mixed spellings. A WIDE entity beside raw UTF-8 upgrades the whole string, so bytes
#     already in it are reread as latin-1: "La\xc3\xads Martins&#8217;" stored as
#     "LaÃ­s Martins’", wrong on screen AND in the key.
#
# THE URLS ARE DELIBERATELY STILL OCTETS, and section 3 is the reason this suite exists as
# much as sections 1-2. Decoding the whole document is the obvious fix and it is WRONG: both
# url fields are compared with `eq` against a value that reaches them as octets —
# DB::findTrackByUrl against the playing track's url, and resolveEpisode's image branch
# against _realImageUrl($IMAGE), which uri_unescape's Material's escaped url. Decode those
# and an accented episode silently stops being marked played, which is bug 2 by another
# route. So the split is the fix, and section 3 pins it.
#
# ANTI-TEST: revert a rule in ListenLater/Podcast.pm and re-run.
#   - drop the _decodeText call from _cleanText          -> 10 red
#   - make _decodeText skip a pure-ASCII field           ->  2 red  (the &#246; cases)
#   - route the urls through _cleanText too              ->  5 red  (section 3)
use strict;
use warnings;
use FindBin;
use JSON::XS ();
require "$FindBin::Bin/t_stubs.pl";

ll_require('DB', 'Podcast');

my ($pass, $fail) = (0, 0);
sub ok {
    my ($desc, $cond) = @_;
    my $b = $cond ? 1 : 0;
    $b ? $pass++ : $fail++;
    printf "%s %s\n", ($b ? 'ok  ' : 'FAIL'), $desc;
}
sub is {
    my ($desc, $got, $want) = @_;
    my $ok = (!defined $got && !defined $want)
          || (defined $got && defined $want && "$got" eq "$want");
    $ok ? $pass++ : $fail++;
    printf "%s %-56s got=%-26s want=%s\n", ($ok ? 'ok  ' : 'FAIL'), $desc,
        (defined $got ? "'" . _show($got) . "'" : '(undef)'),
        (defined $want ? "'" . _show($want) . "'" : '(undef)');
}
sub section { printf "\n== %s\n", $_[0] }

# Print a string as its CODEPOINTS when it holds anything non-ASCII. The whole subject here
# is representation, so a terminal-rendered title would hide exactly the difference under
# test (and "BjÃ¶rk" vs "Björk" is the failure, not a display quirk).
sub _show {
    my ($s) = @_;
    return $s unless $s =~ /[^\x20-\x7e]/;
    return join '', map { ord($_) > 126 || ord($_) < 32 ? sprintf('<U+%04X>', ord) : $_ } split //, $s;
}

my $norm = \&Plugins::ListenLater::DB::_norm;

# Build a one-item feed. $decl is the XML declaration (or ''), so a feed that declares no
# encoding — common, and the case that must default to UTF-8 — is testable.
sub feed {
    my (%a) = @_;
    my $decl = defined $a{decl} ? $a{decl} : q{<?xml version='1.0' encoding='UTF-8'?>};
    my $url  = $a{url} || 'https://example.com/ep.mp3';
    return $decl
        . '<rss><channel><title>' . ($a{show} // 'My Show') . '</title>'
        . '<itunes:image href="' . ($a{chanimg} // 'https://example.com/chan.jpg') . '"/>'
        . '<item><title>' . $a{title} . '</title>'
        . '<enclosure url="' . $url . '"/>'
        . '<itunes:duration>12:00</itunes:duration>'
        . '<pubDate>Tue, 02 Jan 2024 00:00:00 GMT</pubDate>'
        . '</item></channel></rss>';
}
sub parse1 {
    my ($eps, $show) = Plugins::ListenLater::Podcast::_parseFeed(feed(@_));
    return ($eps->[0], $show);
}
sub hex_ { join '', map { sprintf '%02x', ord } split //, ($_[0] // '') }

# ---------------------------------------------------------------------------
section('1. TEXT COMES OUT AS CHARACTERS, WHATEVER THE FEED SPELLED IT WITH');
# The four spellings a real feed uses for the same title. They MUST agree: the plugin stores
# one row per episode and the key has to be the same whichever feed served it.
{
    is('raw UTF-8 keys as expected',
       $norm->((parse1(title => "Bj\xc3\xb6rk on Sigur R\xc3\xb3s"))[0]{title}), 'bjork on sigur ros');
    is('numeric entities key the SAME',
       $norm->((parse1(title => 'Bj&#246;rk on Sigur R&#243;s'))[0]{title}), 'bjork on sigur ros');
    is('a feed that DECLARES iso-8859-1 is decoded as such',
       $norm->((parse1(decl => q{<?xml version='1.0' encoding='iso-8859-1'?>},
                       title => "Bj\xf6rk on Sigur R\xf3s"))[0]{title}), 'bjork on sigur ros');
    is('no declaration defaults to UTF-8',
       $norm->((parse1(decl => '', title => "Bj\xc3\xb6rk on Sigur R\xc3\xb3s"))[0]{title}),
       'bjork on sigur ros');
    is('a mislabelled feed still yields text rather than dying',
       $norm->((parse1(decl => '', title => "Bj\xf6rk on Sigur R\xf3s"))[0]{title}),
       'bjork on sigur ros');

    my $t = (parse1(title => "Bj\xc3\xb6rk"))[0]{title};
    ok('the stored title is CHARACTERS, not octets', utf8::is_utf8($t));
    is('...and holds the real codepoint, not the two bytes', join(',', map { ord } split //, $t),
       '66,106,246,114,107');

    # THE VISIBLE BUG, and it needs no entity: octets into a sqlite_unicode handle store
    # U+00C3,U+00B6 and render "BjÃ¶rk". Pinned on the codepoints because that is what the
    # DB column receives.
    ok('no double-encoding survives (U+00C3 absent)', $t !~ /\x{c3}/);

    # The SHOW takes the same path — it lands in album_title and in the key's album segment.
    is('the show name is decoded too', $norm->((parse1(title => 'x', show => 'My Sh&#246;w'))[1]), 'my show');
}

# ---------------------------------------------------------------------------
section('2. A WIDE ENTITY MUST NOT REINTERPRET THE BYTES AROUND IT');
# chr(8217) upgrades the string. Any raw UTF-8 already in it is then reread as latin-1, which
# is why this needs its own section rather than being another row in section 1: the title is
# well-formed UTF-8 and STILL came out wrong.
{
    my ($ep) = parse1(title => "La\xc3\xads Martins&#8217; story");
    is('a wide entity beside raw UTF-8 keys correctly', $norm->($ep->{title}), 'lais martins story');
    is('...and agrees with the same title spelled entirely in UTF-8',
       $norm->($ep->{title}),
       $norm->((parse1(title => "La\xc3\xads Martins\xe2\x80\x99 story"))[0]{title}));
    ok('the accent is not mangled to U+00C3', $ep->{title} !~ /\x{c3}/);
    is('the curly quote survives as one codepoint',
       scalar(() = $ep->{title} =~ /\x{2019}/g), 1);

    # The common real shape: an ASCII entity (&#39;) next to a raw UTF-8 accent. This one
    # always worked, and stays working — chr(39) is ASCII so it never upgrades anything.
    is("an ASCII entity next to an accent is unchanged",
       $norm->((parse1(title => "Won&#39;t Save Us w/ La\xc3\xads"))[0]{title}), 'wont save us w lais');
}

# ---------------------------------------------------------------------------
section('3. THE URLS STAY OCTETS — THE DECODE IS TEXT-ONLY, ON PURPOSE');
# Both url fields are compared `eq` against a value that arrives as octets. Decoding them
# would break that match SILENTLY for every non-ASCII url, so this pins the split rather
# than the fix that produced it.
{
    my ($ep) = parse1(title => 'Plain', url => "https://example.com/Bj\xc3\xb6rk.mp3");
    ok('the play url is NOT flagged as characters', !utf8::is_utf8($ep->{url}));
    is('...and keeps the feed\'s exact bytes', hex_($ep->{url}),
       hex_("podcast://https://example.com/Bj\xc3\xb6rk.mp3"));

    # findTrackByUrl compares the stored ref.url against the PLAYING url with `eq`. The
    # stored side round-trips through ref_json; both must land on the same codepoints.
    my $J = JSON::XS->new->utf8->canonical;
    my $back = $J->decode($J->encode({ url => $ep->{url} }))->{url};
    is('ref_json round-trips the url to the playing url exactly',
       $back, "podcast://https://example.com/Bj\xc3\xb6rk.mp3");

    my ($img) = parse1(title => 'Plain', chanimg => "https://example.com/Bj\xc3\xb6rk.jpg");
    ok('the image url is NOT flagged either', !utf8::is_utf8($img->{image}));
    # resolveEpisode's image branch compares against this, and uri_unescape yields octets.
    is('...and matches what _realImageUrl gives for the same escaped url',
       $img->{image},
       Plugins::ListenLater::Podcast::_realImageUrl(
           '/imageproxy/https%3A%2F%2Fexample.com%2FBj%C3%B6rk.jpg/image.png'));
}

# ---------------------------------------------------------------------------
section('4. NOTHING ELSE MOVED');
# The non-text fields are ASCII by format. Pinned so a later "decode everything" tidy-up
# has to argue with a red test rather than quietly changing a stored number.
{
    my ($ep) = parse1(title => "Bj\xc3\xb6rk");
    is('duration still parses', $ep->{duration}, 720);
    is('year still parses',     $ep->{year},     2024);
    is('an &amp; in a url is still unescaped, not decoded',
       (parse1(title => 'x', url => 'https://e.com/a?x=1&amp;y=2'))[0]{url},
       'podcast://https://e.com/a?x=1&y=2');

    # _normTitle is the resolve gate and deletes every non-ASCII character, so it answered the
    # same before and after this change. Pinned because that is WHY the fix could not have
    # broken episode resolution, and it is not obvious from reading the sub.
    is('_normTitle is blind to the representation',
       Plugins::ListenLater::Podcast::_normTitle("Bj\xc3\xb6rk"),
       Plugins::ListenLater::Podcast::_normTitle("Bj\x{f6}rk"));
}

printf "\n%d passed, %d failed\n", $pass, $fail;
exit($fail ? 1 : 0);
