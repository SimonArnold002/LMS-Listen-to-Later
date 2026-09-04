package Plugins::ListenLater::Podcast;

# Resolves a podcast EPISODE from the identity a Material browse row actually carries.
#
# THE PROBLEM (measured, not assumed — see CLAUDE.md "Podcast episodes"): a row in the
# built-in Podcasts app exposes NO presetParams, NO favorites_url and NO metadata — only a
# positional item_id ("3.0"), which is not durable (today's 3.0 becomes 3.1 when the next
# episode drops: XMLBrowser builds it as '<parent>.<index>', and Slim::Formats::XML copies no
# `id` and drops <guid> entirely). Its "… → More" is the Podcast plugin's own OPML info
# window, not a trackinfo menu, so the info-provider can't reach it either. So an add arrives
# with just: episode TITLE, the date/duration subtitle, $SERVICE and the episode ARTWORK URL.
#
# MATERIAL *DOES* PASS THE ITEM ID ON, and the claim here that it "never" does was wrong until
# 0.1.132: `$ITEMID` is in customactions.js's ACTION_KEYS and is substituted at line 156.
# $podcastCmd simply does not ask for it. Not used, and the reason is not durability —
# durability governs what you STORE, while resolution happens at add time against the feed on
# screen, where a positional index is exact. It is that the index does not ALIGN: _parseFeed
# drops items with no <enclosure> while the server keeps every <item>, so the two lists skew
# the moment a feed carries a sponsor notice (measured), and the id's leading segments are
# offset by however many search providers are registered ahead of the subscriptions. Taking
# that route means unfiltering _parseFeed first. Recorded so the next round starts here.
#
# THE RESOLUTION: the Podcast plugin keeps the user's subscriptions — with their real RSS
# urls — in its own prefs (plugin.podcast:feeds). Fetch those feeds and find the episode by
# scoring both signals together (see resolveEpisode). The matched <enclosure url> is the
# durable play url; it's stored podcast://-prefixed so the Podcast plugin's own protocol
# handler plays it and keeps its resume-position tracking.
#
# NEITHER SIGNAL IS AN IDENTITY ON ITS OWN, which is why this is a score and not an order.
# The artwork url was called "the primary key … unique per episode" here until 0.1.132 and
# it is NOT: Slim::Formats::XML::parseXMLIntoFeed gives every item the CHANNEL image and
# overrides it only where the item carries its own <itunes:image> — and _parseFeed mirrors
# that fallback deliberately, so it agrees with what the browse row displays. On a feed with
# no per-episode art every episode therefore has the SAME image. Measured across five real
# feeds 2026-09-04: "Tech Won't Save Us" 351 of 360 episodes share one image, "The Daily"
# ~1,120 of 2,968; Darko.Audio, Joe Rogan and Planet Money are one-image-per-episode. The
# 0.1.44 Qobuz trick this was modelled on is a different shape — it EXTRACTS an id from one
# url by regex, with no candidate list and nothing to be ambiguous between.
#
# LIMIT: only episodes of SUBSCRIBED feeds can resolve. An episode found via "Search feeds"
# on a show you haven't subscribed to has nothing to match against, and is rejected rather
# than stored as a row that could never play.

use strict;

use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use URI::Escape ();
use Encode ();
use Time::HiRes ();

my $log   = Slim::Utils::Log::logger('plugin.listenlater');
my $cache = Slim::Utils::Cache->new();

# A feed's episode list changes when a new episode drops; a short working TTL keeps adds
# fast (the common case is several adds in one browsing session) without going stale for
# long. The fallback keeps resolution working through a transient fetch failure.
use constant FEED_TTL          => 3600;        # 1h
use constant FEED_FALLBACK_TTL => 7 * 86400;   # 7d
use constant HTTP_TIMEOUT      => 20;
use constant CACHE_VER         => 40;           # bump to invalidate parsed feeds

# THE WHOLE WALK's budget, and the reason it exists: scoring means an imperfect match keeps
# fetching the REMAINING feeds (only a 3 stops it), so an episode already found and held in
# $best is hostage to every feed after it. _savePodcastEpisode's outer timer used to be the
# only clock, and firing it rejects the add outright — the match is thrown away rather than
# answered with. One slow feed AFTER the match was enough, because a single feed's
# HTTP_TIMEOUT equalled that whole budget; so was ~10 feeds' cumulative latency on a cold
# cache. Pre-0.1.132 the walk returned on the first hit, so a dead feed after the match could
# not reach the add at all — this is what pays that back. The budget is OURS, not the
# caller's: we answer with the best match found so far, which is strictly better than the
# rejection the outer timer produces. Each feed's own fetch is capped at whatever is left of
# it, so one hung feed cannot spend the lot either.
use constant RESOLVE_BUDGET    => 15;

# The user's subscribed podcasts, read from the Podcast plugin's OWN prefs — the only
# place the durable feed urls exist. Each entry is { name => <show>, value => <rss url> }.
sub feeds {
    my $prefs = eval { preferences('plugin.podcast') } or return [];
    my $f = eval { $prefs->get('feeds') };
    return (ref $f eq 'ARRAY') ? $f : [];
}

# Is the Podcast plugin present and holding at least one subscription? Used to decide
# whether the "Add podcast" action is worth writing at all.
sub hasFeeds { return scalar @{ feeds() } ? 1 : 0 }

# resolveEpisode($title, $image, $cb) -> $cb->($episode | undef)
#   $episode = { url, title, show, image, duration, year }
#
# SCORES every candidate across the subscribed feeds and calls back with the best, rather
# than returning the first episode matching either signal. Feeds are fetched at most once per
# FEED_TTL, so a second add in the same session is instant.
#
# THE TWO SIGNALS, and what each can actually prove (0.1.132 — the old order got both wrong):
#   * a TITLE identifies an episode WITHIN a feed, and can collide ACROSS feeds. "Trailer",
#     "Introduction" and "Episode 1" are titles dozens of shows share.
#   * an IMAGE identifies the FEED always, and the EPISODE only when it occurs ONCE in it
#     (see the header: a feed with no per-episode art gives every episode the channel image).
# So:
#   3  title AND image        — decisive: right feed, right episode. Stops the walk.
#   2  image, unique in feed  — decisive within that feed; survives a decorated title.
#   1  title only             — right episode IF this is the right feed. Can be beaten.
#   0  image, shared in feed  — names the SHOW, not an episode. NOT a candidate.
# Ties keep the earliest subscription, which is what makes "two feeds, same title, no image"
# resolve to the first feed rather than at random (pinned in t_podcast_resolve.pl §5).
#
# WHY THE 0-SCORE CASE MATTERS MOST: it is what refuses a SHOW row. A show row carries the
# channel image and the show's name, so it matches no episode title and its image is shared —
# no candidate, rejected. Under the old order it scored an image hit on episode 1 and stored
# it, which is the "the Podcasts app already refuses a series" claim in Sources.pm silently
# failing on every feed without per-episode art.
#
# The walk still SHORT-CIRCUITS on a 3, so the common case costs exactly what it did before:
# one feed fetch. Only an imperfect match pays for the remaining feeds, and they are cached.
# That payment is bounded by RESOLVE_BUDGET (see the constant): when it runs out the walk
# stops and answers with the best match it has, rather than letting the caller's timer fire
# and discard it. Under budget the behaviour is unchanged, so nothing about the SCORE moves.
sub resolveEpisode {
    my ($title, $image, $cb) = @_;

    my $wantImage = _realImageUrl($image);
    my $wantTitle = _normTitle($title);
    unless (length $wantTitle || length $wantImage) {
        $log->warn('LL: podcast resolve — no title and no image to match on');
        return $cb->(undef);
    }

    my @queue = @{ feeds() };
    unless (@queue) {
        $log->warn('LL: podcast resolve — no subscribed feeds (plugin.podcast:feeds empty)');
        return $cb->(undef);
    }
    $log->warn("LL: podcast resolve '" . ($title // '?') . "' across " . scalar(@queue) . ' feed(s)');

    my $started = Time::HiRes::time();
    my ($best, $bestScore, $bestWhy) = (undef, 0, '');
    my $finish = sub {
        unless ($best) {
            $log->warn("LL: podcast resolve — no feed contained '" . ($title // '?') . "'");
            return $cb->(undef);
        }
        $log->warn("LL: podcast resolved by $bestWhy -> " . ($best->{url} // '?'));
        return $cb->($best);
    };

    my $step;
    $step = sub {
        # Checked BEFORE the next fetch, not after it, so what is left of the budget is what
        # the next feed is allowed to spend. $best is answered with, never discarded.
        my $left = RESOLVE_BUDGET - (Time::HiRes::time() - $started);
        if ($left <= 0) {
            $log->warn('LL: podcast resolve — budget spent with ' . scalar(@queue)
                . ' feed(s) unread; answering with the best match so far') if @queue;
            # Every subscribed feed, not just @queue: a feed the walk DID reach may have had
            # its fetch capped short and cached nothing, so it is cold too. _feedEpisodes
            # answers instantly for the ones already cached, so this costs them nothing.
            _warmFeeds(map { $_->{value} } @{ feeds() });
            return $finish->();
        }

        my $feed = shift @queue;
        return $finish->() unless $feed;

        _feedEpisodes($feed->{value}, sub {
            my ($eps, $show) = @_;

            # How many episodes in THIS feed carry each image. Counted per feed rather than
            # once overall, because "is this image an episode's or the show's" is a question
            # about the feed it came from — the same url is unique in one feed and shared in
            # another, and a single-episode feed's channel image IS that episode's.
            my %imgCount;
            $imgCount{ $_->{image} // '' }++ for @$eps;

            for my $e (@$eps) {
                my $img    = $e->{image} // '';
                my $imgHit = (length $wantImage && $img eq $wantImage) ? 1 : 0;
                my $ttlHit = (length $wantTitle && _normTitle($e->{title}) eq $wantTitle) ? 1 : 0;

                # See the header for the table. `>` and not `>=`, so a tie keeps the earlier
                # subscription instead of drifting to the last feed that matched.
                my $score = $ttlHit ? ($imgHit ? 3 : 1)
                          : ($imgHit && $imgCount{$img} == 1) ? 2 : 0;
                next unless $score > $bestScore;

                ($best, $bestScore) = ({ %$e, show => ($show || $feed->{name}) }, $score);
                $bestWhy = $ttlHit ? ($imgHit ? 'title+image' : 'title') : 'unique image';
            }

            # Nothing can beat a title and an image agreeing, so stop fetching feeds. This is
            # what keeps the ordinary add at one fetch, exactly as before.
            return $finish->() if $bestScore == 3;
            $step->();
        }, $left);
    };
    $step->();
    return;
}

# Warm the parse cache for feeds the walk did not get to read, in the background.
#
# WHY THIS IS PART OF THE BUDGET AND NOT AN OPTIMISATION. A fetch that times out writes
# NEITHER cache (see _feedEpisodes: only a parse with items sets $key and $fbKey), and every
# fetch is now capped below HTTP_TIMEOUT — so a feed slower than the budget could never be
# fetched by the walk at all, and would stay cold for ever. Pre-0.1.135 that case still
# healed itself by accident: the outer timer rejected the add, but the 20s fetch underneath
# it went on to complete and cache, so the NEXT add resolved. The cap would have taken that
# accident away and left nothing in its place. This puts it back deliberately.
#
# SERIAL, and fire-and-forget. Serial because the point is a warm cache for the next add, not
# speed, and a burst of parallel fetches across a long subscription list is the kind of thing
# that gets a plugin blamed for the network. Fire-and-forget because the add has ALREADY
# answered — nothing is waiting on this, there is no setStatusProcessing to release and no
# result to return; each feed simply caches itself on the way past, with the full timeout.
# %WARMING keeps a second add from starting a second sweep over the same feed.
my %WARMING;
sub _warmFeeds {
    my (@urls) = @_;
    my $next;
    $next = sub {
        my $url = shift @urls;
        return unless defined $url && length $url;
        return $next->() if $WARMING{$url};
        $WARMING{$url} = 1;
        _feedEpisodes($url, sub { delete $WARMING{$url}; $next->() });
    };
    $next->();
    return;
}

# Fetch + parse one feed -> $cb->(\@episodes, $showName). Cached; a failed fetch falls back
# to the last good parse so one flaky feed doesn't break resolution.
#
# $timeout caps THIS fetch at what is left of the caller's budget (resolveEpisode passes it).
# Without the cap one hung feed spends HTTP_TIMEOUT — the whole walk's budget — on its own.
# A failure here is not a failure of the walk: the error branch falls back and calls back
# normally, so a feed that runs out of time simply contributes nothing.
sub _feedEpisodes {
    my ($url, $cb, $timeout) = @_;
    return $cb->([], undef) unless defined $url && length $url;

    $timeout = HTTP_TIMEOUT if !defined $timeout || $timeout > HTTP_TIMEOUT;
    $timeout = 1            if $timeout < 1;   # a sub-second socket timeout fetches nothing

    my $key   = 'll:podfeed:' . CACHE_VER . ':' . $url;
    my $fbKey = "$key:fb";

    if (my $c = $cache->get($key)) {
        return $cb->($c->{items} || [], $c->{show});
    }

    Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $http = shift;
            my ($items, $show) = _parseFeed($http->content);
            if (@$items) {
                my $rec = { items => $items, show => $show };
                $cache->set($key,   $rec, FEED_TTL);
                $cache->set($fbKey, $rec, FEED_FALLBACK_TTL);
                $log->info("podcast feed parsed: " . scalar(@$items) . " episodes ($url)");
            }
            else {
                $log->warn("LL: podcast feed parsed 0 episodes from "
                    . length($http->content || '') . " bytes ($url)");
                my $fb = $cache->get($fbKey);
                return $cb->($fb->{items} || [], $fb->{show}) if $fb;
            }
            $cb->($items, $show);
        },
        sub {
            my ($http, $error) = @_;
            $log->warn("LL: podcast feed fetch failed ($url): $error");
            my $fb = $cache->get($fbKey);
            $cb->(($fb ? $fb->{items} : []) || [], $fb ? $fb->{show} : undef);
        },
        { timeout => $timeout },
    )->get($url);
    return;
}

# The feed body arrives as RAW BYTES. Slim::Networking::SimpleHTTP::Base::content is
# `${ $self->contentRef }` with no charset step anywhere above it, so every field pulled out
# below is octets. Three things went wrong downstream of that, all measured:
#
#  1. THE VISIBLE ONE, and it needs no entity at all. DB's handle sets `sqlite_unicode`, so
#     it takes CHARACTERS; handing it the raw "Bj\xc3\xb6rk" stores codepoints U+00C3,U+00B6
#     and the list renders "BjÃ¶rk". Every accented episode title and show name was stored
#     double-encoded.
#  2. _clean's numeric-entity pass (`chr($1)`) mixes codepoints INTO that byte string.
#     "Bj&#246;rk" puts byte 0xF6 in an unflagged string, which is not valid UTF-8, so
#     DB::foldLatin's decode fails, the accent fold is SKIPPED, and the key is 'bj rk' where
#     every other producer keys 'bjork'. Played's findSavedTrack then never matches it and
#     the episode is never marked played.
#  3. A WIDE entity next to raw UTF-8 is worse: chr(8217) upgrades the whole string, so the
#     UTF-8 bytes already in it are reinterpreted as latin-1 — "La\xc3\xads Martins&#8217;"
#     stores as "LaÃ­s Martins’", wrong on screen AND in the key.
#
# 2 and 3 write a wrong dedupe_key, which is UNIQUE and permanent. One decode, before any
# entity pass, fixes all three: _clean's chr() and DB::foldLatin then work in one
# representation.
#
# TEXT ONLY — the urls stay octets, and that is load-bearing, not laziness. Each is compared
# against a value that reaches it as octets:
#   • `url` round-trips through ref_json and is compared `eq` against the PLAYING track's url
#     in DB::findTrackByUrl. Stored as characters it stops matching and the episode is never
#     marked played — the very bug 2 causes by the other route.
#   • `image` is compared `eq` against _realImageUrl($IMAGE), which uri_unescape's Material's
#     escaped url and so yields octets too.
# Decoding either was measured to break its match for every non-ASCII url. `duration` and
# `pubDate` are ASCII by format and need nothing.
sub _charset {
    my ($xml) = @_;
    return $1 if $xml =~ /^\s*<\?xml[^>]*\bencoding=["']([\w:.-]+)["']/i;
    return 'utf-8';
}

# Decode one extracted TEXT field to characters. UNCONDITIONALLY, including a pure-ASCII one:
# the entity pass that runs after this can introduce a non-ASCII codepoint that was never in
# the bytes ("Bj&#246;rk" is ASCII until chr(246) runs), and appending a codepoint to an
# unflagged string is exactly bug 2 above. Flagging here means chr() lands in a character
# string whatever the field looked like.
#
# Falls back through utf-8 then cp1252 so a mislabelled feed still yields text rather than
# dying: FB_CROAK makes a wrong declared charset fail loudly enough to try the next, and
# cp1252 accepts every byte, so this always returns something.
sub _decodeText {
    my ($s, $charset) = @_;
    return $s unless defined $s && length $s;
    return $s if utf8::is_utf8($s);
    for my $enc ($charset, 'utf-8') {
        my $d = eval { Encode::decode($enc, $s, Encode::FB_CROAK()) };
        return $d if defined $d;
    }
    return Encode::decode('cp1252', $s);
}

# Parse an RSS podcast feed -> (\@episodes, $showName). Deliberately a tolerant regex scan
# rather than a full XML parse: podcast RSS is machine-generated, we need four fields per
# item, and this can't die on the malformed-but-common feeds an XML parser would reject.
sub _parseFeed {
    my ($xml) = @_;
    return ([], undef) unless defined $xml && length $xml;

    my $charset = _charset($xml);

    # Show name = the channel <title> (the first one, before any <item>).
    my ($head) = $xml =~ /^(.*?)<item[\s>]/s;
    $head = $xml unless defined $head;
    my ($show) = $head =~ m{<title[^>]*>(.*?)</title>}s;
    $show = _cleanText($show, $charset);

    # Channel-level artwork, the fallback for an episode with no <itunes:image>.
    my ($chanImg) = $head =~ m{<itunes:image[^>]*\bhref=["']([^"']+)["']}i;
    ($chanImg) = $head =~ m{<image[^>]*>.*?<url[^>]*>(.*?)</url>}si unless $chanImg;
    $chanImg = _clean($chanImg);

    my @eps;
    while ($xml =~ m{<item[\s>](.*?)</item>}gs) {
        my $it = $1;

        my ($enc) = $it =~ m{<enclosure[^>]*\burl=["']([^"']+)["']}i;
        $enc = _clean($enc);
        next unless length $enc;   # no playable enclosure -> not an episode we can save

        my ($t)   = $it =~ m{<title[^>]*>(.*?)</title>}s;
        my ($img) = $it =~ m{<itunes:image[^>]*\bhref=["']([^"']+)["']}i;
        my ($dur) = $it =~ m{<itunes:duration[^>]*>(.*?)</itunes:duration>}s;
        my ($pub) = $it =~ m{<pubDate[^>]*>(.*?)</pubDate>}s;

        push @eps, {
            # Store the podcast://-wrapped url: that's what the Podcast plugin's protocol
            # handler plays, and what keeps its resume-position tracking working.
            url      => 'podcast://' . $enc,
            title    => _cleanText($t, $charset),
            image    => (_clean($img) || $chanImg),
            duration => _seconds(_clean($dur)),
            year     => ((_clean($pub) // '') =~ /\b(\d{4})\b/) ? $1 : undef,
        };
    }
    return (\@eps, $show);
}

# _clean for a HUMAN-READABLE field: decode to characters first, then run the shared cleanup.
# Order matters — the entity pass inside _clean must land in a character string.
sub _cleanText {
    my ($s, $charset) = @_;
    return _clean(_decodeText($s, $charset));
}

# Strip CDATA, decode the handful of entities that actually appear in feed titles and
# urls (&amp; in a query string is common), and trim.
sub _clean {
    my ($s) = @_;
    return '' unless defined $s;
    $s =~ s/<!\[CDATA\[(.*?)\]\]>/$1/gs;
    $s =~ s/&lt;/</g;   $s =~ s/&gt;/>/g;
    $s =~ s/&quot;/"/g; $s =~ s/&#0?39;|&apos;/'/g;
    $s =~ s/&#(\d+);/chr($1)/ge;
    $s =~ s/&amp;/&/g;   # last, so "&amp;lt;" doesn't become "<"
    $s =~ s/^\s+|\s+$//g;
    return $s;
}

# "01:58:57" / "58:05" / "3396" -> seconds.
sub _seconds {
    my ($d) = @_;
    return undef unless defined $d && length $d;
    return $d + 0 if $d =~ /^\d+$/;
    my @p = split /:/, $d;
    return undef unless @p && @p <= 3 && !grep { !/^\d+$/ } @p;
    my $s = 0; $s = $s * 60 + $_ for @p;
    return $s;
}

# A Material row's $IMAGE is the LMS image proxy wrapping the real url:
#   /imageproxy/<uri-escaped real url>/image.png
# Unwrap it back to the url the RSS carries, so the two can be compared directly.
sub _realImageUrl {
    my ($img) = @_;
    return '' unless defined $img && length $img;
    $img =~ s{^/?imageproxy/}{};
    $img =~ s{/image(?:\.\w+)?$}{};
    my $u = URI::Escape::uri_unescape($img);
    return ($u =~ m{^https?://}i) ? $u : '';
}

# Titles are compared loosely enough to survive entity/punctuation/spacing differences
# between what Material renders and what the feed carries, but no looser — an episode
# title is the only thing separating two episodes of the same show.
sub _normTitle {
    my ($t) = @_;
    $t = _clean($t);
    $t = lc $t;
    $t =~ s/[^a-z0-9]+/ /g;
    $t =~ s/^\s+|\s+$//g;
    return $t;
}

1;
