#!/usr/bin/env perl
# WHICH EPISODE DOES A TAPPED PODCASTS-APP ROW ACTUALLY RESOLVE TO?
#
# A built-in Podcasts-app row carries no favurl and no durable id (Podcast.pm's header), so
# the episode is recovered by matching the two things Material DOES send — $TITLE and $IMAGE
# — against the user's subscribed feeds. That match is the whole identity of the stored row:
# get it wrong and DB::add stores a perfectly valid row pointing at a DIFFERENT episode, with
# a confirmation toast and nothing in the log. A silent wrong-audio row, which this repo has
# already met once from the streaming side (see DB::episodeKey).
#
# THE TWO BUGS THIS PINS, both measured against real feeds before being fixed:
#
#  1. ARTWORK IS NOT AN EPISODE IDENTITY. Podcast.pm's header called it "the primary key …
#     unique per episode". Slim::Formats::XML (parseXMLIntoFeed, the built-in parser) gives
#     every item the CHANNEL image and overrides it only where the item carries its own
#     <itunes:image> — and _parseFeed mirrors that fallback exactly. So on a feed with no
#     per-episode art every episode's image is the same string. The old order tried image
#     FIRST and returned the first episode matching either signal, so it answered episode 1
#     for every tap. Measured 2026-09-04: of five real feeds, "Tech Won't Save Us" has 351 of
#     360 episodes sharing one image and "The Daily" has ~1,120 of 2,968 sharing.
#     A SHOW row is the same bug at its worst: its image IS the channel image
#     (Podcast/Plugin.pm reads 'podcast-rss-<url>', which precacheFeedData sets to the feed
#     image), so tapping a show stored its first episode instead of being refused — which is
#     what Sources.pm's "the Podcasts app already refuses a series" rests on.
#
#  2. AN EARLIER FEED'S TITLE COLLISION BEAT A LATER FEED'S CORRECT IMAGE MATCH. Feeds were
#     walked in subscription order and ANY signal returned immediately, so per-episode
#     artwork did not protect you: "Trailer", "Introduction" and "Episode 1" are titles many
#     shows share, and the first feed holding one won.
#
# THE RULE THE FIX ENCODES, and it is the reason this is a SCORE rather than a reordering:
# neither signal is an identity on its own, so no fixed order of two `elsif`s can be right.
#   * a TITLE identifies an episode WITHIN a feed, and can collide ACROSS feeds
#   * an IMAGE identifies the FEED always, and the EPISODE only when it is unique in it
# So a candidate carrying both beats one carrying either, and an image that is shared inside
# its own feed is not a candidate at all — it names the show, and we cannot say which episode.
#
# WHAT IS DELIBERATELY STILL AMBIGUOUS: two feeds holding the same episode title when no
# image is supplied at all. Nothing distinguishes them, so feed order still decides; §5 pins
# that as a known limit rather than leaving it to be discovered as a bug. Material always
# sends $IMAGE for these rows, so it is not reachable from the UI.
#
# ANTI-TEST — measured, not asserted. Revert a rule in ListenLater/Podcast.pm and re-run.
#   - the pre-0.1.132 sub (image first, first hit wins)        -> 10 red
#   - drop the per-feed uniqueness test on the image           ->  3 red: the SHOW row, an
#     unknown title and a shared image with no title all store episode 1 again — i.e. this
#     one test is the whole series refusal
#   - return on the first feed holding any candidate, not on a -> 3 red: every cross-feed
#     score of 3                                                  case, which is the half a
#     reordering alone cannot fix
#   - drop the budget check in the walk (§7)                    ->  2 red: an imperfect match
#     is walked past and lost, which is what the outer timer then rejects the add over
#   - drop the per-feed timeout cap                             ->  2 red: one feed may spend
#     the whole walk's budget on its own, so the cap is not decoration
#   - drop the background warm the cap makes necessary           ->  2 red: a feed slower than
#     the budget can then never be fetched at all, because a timed-out fetch caches nothing
# Each was run against a copy of the tree, not reasoned about; the pre-fix numbers come from
# `git show HEAD:ListenLater/Podcast.pm`.
use strict;
use warnings;
use FindBin;
require "$FindBin::Bin/t_stubs.pl";

# A REAL cache, because resolveEpisode reaches the feeds through _feedEpisodes and the stub
# cache is a no-op — priming it is what keeps this suite offline and deterministic. Installed
# before ll_require so nothing captures the no-op version.
my %CACHE;
my @CLOCK;      # §7's fake clock; empty = the real Time::HiRes::time
{
    no warnings 'redefine';
    *Slim::Utils::Cache::get = sub { $CACHE{ $_[1] } };
    *Slim::Utils::Cache::set = sub { $CACHE{ $_[1] } = $_[2] };
}

ll_require('Podcast');
my $P = 'Plugins::ListenLater::Podcast';

my ($pass, $fail) = (0, 0);
sub is {
    my ($desc, $got, $want) = @_;
    my $ok = (!defined $got && !defined $want)
          || (defined $got && defined $want && "$got" eq "$want");
    $ok ? $pass++ : $fail++;
    printf "%s %-52s got=%-30s want=%s\n", ($ok ? 'ok  ' : 'FAIL'), $desc,
        (defined $got ? "'$got'" : '(undef)'), (defined $want ? "'$want'" : '(undef)');
}
sub section { printf "\n== %s\n", $_[0] }

# ---------------------------------------------------------------------------
# Fixtures. `art => 1` gives each episode its own <itunes:image>; without it they
# inherit the channel image, which is what parseXMLIntoFeed does and what the
# common real feed looks like.
# ---------------------------------------------------------------------------
sub rss {
    my (%o) = @_;
    my $items = join '', map {
        my ($n, $title) = @$_;
        my $img = $o{art} ? qq{<itunes:image href="https://cdn.ex/$o{slug}-ep$n.jpg"/>} : '';
        qq{<item><title>$title</title><pubDate>Mon, 06 Jan 2025 06:00:00 GMT</pubDate>}
      . qq{<itunes:duration>00:45:00</itunes:duration>$img}
      . qq{<enclosure url="https://cdn.ex/$o{slug}-ep$n.mp3" type="audio/mpeg"/></item>}
    } @{ $o{items} };
    return qq{<?xml version="1.0" encoding="utf-8"?><rss><channel><title>$o{show}</title>}
         . qq{<itunes:image href="https://cdn.ex/$o{slug}-show.jpg"/>$items</channel></rss>};
}

# Subscribe to the given feeds and prime LL's own parse cache, so no HTTP is needed.
sub subscribe {
    my (@feeds) = @_;                       # each: [ name, rss ]
    %CACHE = ();
    Slim::Utils::Prefs::set_test_pref_ns('plugin.podcast', 'feeds',
        [ map { { name => $_->[0], value => 'https://feeds.ex/' . $_->[0] } } @feeds ]);
    for my $f (@feeds) {
        my ($eps, $show) = $P->can('_parseFeed')->($f->[1]);
        $CACHE{ 'll:podfeed:' . $P->can('CACHE_VER')->() . ':https://feeds.ex/' . $f->[0] }
            = { items => $eps, show => $show };
    }
}

# What Material sends as $IMAGE: the real url, escaped, behind the LMS image proxy.
sub proxied { '/imageproxy/' . URI::Escape::uri_escape($_[0]) . '/image.jpg' }

# resolveEpisode is async by signature but synchronous off a primed cache.
sub resolve {
    my ($title, $image) = @_;
    my $got;
    $P->can('resolveEpisode')->($title, $image, sub { $got = $_[0] });
    return $got ? $got->{url} : '(rejected)';
}
sub url { 'podcast://https://cdn.ex/' . $_[0] . '.mp3' }

my @THREE = ([1, '1. Ancient Rome'], [47, '47. The Fall of Constantinople'], [48, 'Trailer']);

# ---------------------------------------------------------------------------
section('1. a feed with NO per-episode artwork — every image is the channel image');
# ---------------------------------------------------------------------------
subscribe([ rih => rss(show => 'The Rest Is History', slug => 'rih', items => \@THREE) ]);

# The bug: image matched first, all three images identical, so episode 1 answered every tap.
is('tap ep47 — the title decides, not the shared image',
   resolve('47. The Fall of Constantinople', proxied('https://cdn.ex/rih-show.jpg')),
   url('rih-ep47'));
is('tap ep1 — still resolves to itself',
   resolve('1. Ancient Rome', proxied('https://cdn.ex/rih-show.jpg')),
   url('rih-ep1'));
# The show row carries the channel image and the SHOW's name, so it matches no episode title
# and its image names the feed rather than an episode. Sources.pm's series refusal is this.
is('tap the SHOW row — refused, not stored as episode 1',
   resolve('The Rest Is History', proxied('https://cdn.ex/rih-show.jpg')),
   '(rejected)');
is('a title in no feed is refused',
   resolve('Some Other Show Entirely', proxied('https://cdn.ex/rih-show.jpg')),
   '(rejected)');
# The title path has to stand alone: a row can reach the last-resort resolve with no image.
is('no image supplied — the title still resolves',
   resolve('47. The Fall of Constantinople', ''),
   url('rih-ep47'));

# ---------------------------------------------------------------------------
section('2. a feed WITH per-episode artwork — the positive control');
# ---------------------------------------------------------------------------
subscribe([ rih => rss(show => 'The Rest Is History', slug => 'rih', items => \@THREE, art => 1) ]);

is('tap ep47 by its own image and title',
   resolve('47. The Fall of Constantinople', proxied('https://cdn.ex/rih-ep47.jpg')),
   url('rih-ep47'));
# A unique image is a real identity: it belongs to exactly one episode in this feed, so it
# resolves even when the title Material sent has been decorated and no longer matches.
is('a UNIQUE image resolves even when the title does not match',
   resolve('2025-01-06 - 47. The Fall of Constantinople',
           proxied('https://cdn.ex/rih-ep47.jpg')),
   url('rih-ep47'));
is('the show row is refused here too',
   resolve('The Rest Is History', proxied('https://cdn.ex/rih-show.jpg')),
   '(rejected)');

# ---------------------------------------------------------------------------
section('3. TWO feeds — an earlier title collision must not beat a later exact match');
# ---------------------------------------------------------------------------
# feed1 has a "Trailer" and no per-episode art; feed2 has its own "Trailer" WITH art.
# Walking in order and returning on any signal answered feed1 every time.
subscribe(
    [ rih   => rss(show => 'The Rest Is History', slug => 'rih', items => \@THREE) ],
    [ other => rss(show => 'Other Show', slug => 'oth', items => [[1, 'Trailer']], art => 1) ],
    [ third => rss(show => 'Third Show', slug => 'thr', items => [[1, 'Intro'], [2, 'Trailer']]) ],
);

is('tap feed2 "Trailer" carrying its OWN episode image',
   resolve('Trailer', proxied('https://cdn.ex/oth-ep1.jpg')),
   url('oth-ep1'));
is('tap feed1 "Trailer" carrying feed1\'s channel image',
   resolve('Trailer', proxied('https://cdn.ex/rih-show.jpg')),
   url('rih-ep48'));
# The decisive case for scoring over ordering: feed3's image is SHARED inside feed3, so it
# proves nothing on its own — but paired with the title it names the right feed, and must
# beat the bare title matches sitting in the two feeds subscribed before it.
is('tap feed3 "Trailer" — a shared image still names the right FEED',
   resolve('Trailer', proxied('https://cdn.ex/thr-show.jpg')),
   url('thr-ep2'));
is('a title unique to feed1 is unaffected by feed order',
   resolve('1. Ancient Rome', proxied('https://cdn.ex/rih-show.jpg')),
   url('rih-ep1'));

# ---------------------------------------------------------------------------
section('4. an image shared INSIDE a feed names the show, never an episode');
# ---------------------------------------------------------------------------
subscribe(
    [ rih   => rss(show => 'The Rest Is History', slug => 'rih', items => \@THREE) ],
    [ other => rss(show => 'Other Show', slug => 'oth', items => [[9, '9. Later Show']]) ],
);
# feed2 holds ONE episode, so its channel image occurs once and IS unique there.
is('a single-episode feed\'s channel image is a real identity',
   resolve('9. Later Show', proxied('https://cdn.ex/oth-show.jpg')),
   url('oth-ep9'));
# feed1's channel image is shared by three episodes, so on its own it decides nothing.
is('a shared image with no title match is refused',
   resolve('Not An Episode In Any Feed', proxied('https://cdn.ex/rih-show.jpg')),
   '(rejected)');

# ---------------------------------------------------------------------------
section('5. known limits, pinned so they are not rediscovered as bugs');
# ---------------------------------------------------------------------------
subscribe(
    [ a => rss(show => 'Show A', slug => 'aaa', items => [[1, 'Trailer']]) ],
    [ b => rss(show => 'Show B', slug => 'bbb', items => [[1, 'Trailer']]) ],
);
# Nothing distinguishes them without an image, so subscription order decides. Material always
# sends $IMAGE for a Podcasts-app row, so this is not reachable from the UI — it is pinned
# because a future caller passing no image would silently get the first feed's episode.
is('same title in two feeds, NO image — first subscription wins (documented)',
   resolve('Trailer', ''), url('aaa-ep1'));
# ...and supplying the image resolves it, which is why the limit is acceptable.
is('...and the image resolves it',
   resolve('Trailer', proxied('https://cdn.ex/bbb-show.jpg')), url('bbb-ep1'));

# No subscriptions at all: the sub must answer, not die (Plugin.pm holds the request open).
Slim::Utils::Prefs::set_test_pref_ns('plugin.podcast', 'feeds', []);
is('no subscribed feeds — refused cleanly', resolve('Trailer', ''), '(rejected)');
is('no title and no image — refused before any fetch', resolve('', ''), '(rejected)');

# ---------------------------------------------------------------------------
section('6. the resolved record still carries what _savePodcastEpisode stores');
# ---------------------------------------------------------------------------
subscribe([ rih => rss(show => 'The Rest Is History', slug => 'rih', items => \@THREE) ]);
my $rec;
$P->can('resolveEpisode')->('47. The Fall of Constantinople',
    proxied('https://cdn.ex/rih-show.jpg'), sub { $rec = $_[0] });
is('title',    $rec && $rec->{title},    '47. The Fall of Constantinople');
is('show',     $rec && $rec->{show},     'The Rest Is History');
is('duration', $rec && $rec->{duration}, 2700);
is('year',     $rec && $rec->{year},     2025);
is('url is the podcast://-wrapped enclosure', $rec && $rec->{url}, url('rih-ep47'));

# ---------------------------------------------------------------------------
section('7. the budget answers with the best match instead of losing it');
# ---------------------------------------------------------------------------
# Scoring means an IMPERFECT match (a title-only 1, a unique-image 2) keeps fetching every
# remaining feed — only a 3 stops the walk. So an episode already found and held in $best sat
# behind however many feeds came after it, with _savePodcastEpisode's outer timer as the only
# clock; that timer REJECTS the add, so the match was discarded rather than answered with.
# One slow feed after the match was enough (a single feed's HTTP_TIMEOUT equalled that whole
# budget), and so was several feeds' cumulative latency on a cold cache. RESOLVE_BUDGET is
# the walk's own clock: when it runs out we stop and answer with what we have.
#
# The clock is FAKED rather than waited on — Podcast.pm calls Time::HiRes::time() fully
# qualified, so the queue below feeds it a start and one reading per $step. It holds its last
# value once the queue is down to one, so the number of readings doesn't have to be guessed.
{
    no warnings 'redefine';
    my $real = \&Time::HiRes::time;
    *Time::HiRes::time = sub {
        return $real->() unless @CLOCK;
        return @CLOCK > 1 ? shift(@CLOCK) : $CLOCK[0];
    };
}

# Feed A (earlier subscription) holds the title with NO per-episode art — a score of 1, the
# case that keeps walking. Feed B holds the same title WITH its own art, so supplying B's
# episode image makes B a 3: the walk would reach it and rightly prefer it, and does when the
# budget allows. Both are primed, so a walk that keeps going costs nothing and the pre-fix
# tree answers B's url here rather than dying on a live fetch — the anti-test reads as a red
# line, which is the point. The trade this pins is deliberate: once the budget is spent, the
# match in hand beats a better one we no longer have time to find, because the alternative is
# not the better match, it is the outer timer rejecting the add and storing nothing.
subscribe([ aaa => rss(show => 'Show A', slug => 'aaa', items => \@THREE) ],
          [ bbb => rss(show => 'Show B', slug => 'bbb', items => \@THREE, art => 1) ]);

@CLOCK = (0, 0, 100);   # start, feed A under budget, then the budget is spent
is('a title-only match survives the budget running out mid-walk',
   resolve('47. The Fall of Constantinople', proxied('https://cdn.ex/bbb-ep47.jpg')),
   url('aaa-ep47'));

@CLOCK = ();            # the same tap with the budget intact walks on to the better match
is('...and with time left the walk still prefers the score of 3',
   resolve('47. The Fall of Constantinople', proxied('https://cdn.ex/bbb-ep47.jpg')),
   url('bbb-ep47'));

@CLOCK = (0, 100);      # spent before the first feed is even read
is('...and with nothing found yet it still refuses cleanly',
   resolve('47. The Fall of Constantinople', ''), '(rejected)');

@CLOCK = ();

# The per-feed cap: one hung feed must not be allowed to spend the whole walk's budget, so
# _feedEpisodes takes what is left and never more than HTTP_TIMEOUT. Read back off the
# request the async client is handed.
#
# NOTE for anyone adding a §8: this replaces the async client for the REST OF THE FILE, and
# a fetch here never calls back (LLTestHTTP::get is a no-op). Nothing after it may rely on a
# real fetch completing.
my ($asked, @fetched);
{
    no warnings 'redefine';
    *Slim::Networking::SimpleAsyncHTTP::new = sub {
        my ($class, $ok, $err, $args) = @_;
        $asked = $args->{timeout};
        return bless { cb => $ok }, 'LLTestHTTP';
    };
}
sub LLTestHTTP::get { push @fetched, $_[1] }
$P->can('_feedEpisodes')->('https://feeds.ex/uncached', sub { }, 4);
is('a feed fetch is capped at what is left of the budget', $asked, 4);
$P->can('_feedEpisodes')->('https://feeds.ex/uncached2', sub { }, 60);
is('...but never longer than HTTP_TIMEOUT', $asked, $P->can('HTTP_TIMEOUT')->());
$P->can('_feedEpisodes')->('https://feeds.ex/uncached3', sub { }, 0.2);
is('...and a sub-second remainder is floored, not passed through', $asked, 1);

# ...and the cap's own knock-on, which is why _warmFeeds exists. A fetch that times out
# writes NEITHER cache (only a parse with items sets them), so a feed slower than the budget
# could never be fetched by the capped walk at all and would stay cold for ever. Before the
# cap that case healed by accident — the outer timer rejected the add, but the uncapped fetch
# underneath still completed and cached, so the next add worked. So: when the budget stops
# the walk, every subscribed feed that is not already cached is warmed in the background,
# with the full timeout and nothing waiting on it.
subscribe([ aaa => rss(show => 'Show A', slug => 'aaa', items => \@THREE) ]);
Slim::Utils::Prefs::set_test_pref_ns('plugin.podcast', 'feeds',
    [ { name => 'aaa', value => 'https://feeds.ex/aaa' },      # primed by subscribe()
      { name => 'ccc', value => 'https://feeds.ex/ccc' } ]);   # cold

@CLOCK = (0, 0, 100);   # feed A read under budget, then spent with ccc unread
@fetched = ();
resolve('47. The Fall of Constantinople', '');
is('the budget stopping the walk warms the unread feed in the background',
   join(',', @fetched), 'https://feeds.ex/ccc');
is('...with the FULL timeout, not the spent budget', $asked, $P->can('HTTP_TIMEOUT')->());

# The already-cached feed is not re-fetched: _feedEpisodes answers it off the cache, so a
# warm sweep costs nothing for the feeds the walk did read.
is('...and an already-cached feed is not re-fetched',
   scalar(grep { m/aaa/ } @fetched), 0);

@CLOCK = ();

printf "\n%d passed, %d failed\n", $pass, $fail;
exit($fail ? 1 : 0);
