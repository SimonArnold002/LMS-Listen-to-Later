package Plugins::ListenLater::Podcast;

# Resolves a podcast EPISODE from the identity a Material browse row actually carries.
#
# THE PROBLEM (measured, not assumed — see CLAUDE.md "Podcast episodes"): a row in the
# built-in Podcasts app exposes NO presetParams, NO favorites_url and NO metadata — only a
# positional item_id ("3.0") that Material never passes on, and which is not durable anyway
# (today's 3.0 becomes 3.1 when the next episode drops). Its "… → More" is the Podcast
# plugin's own OPML info window, not a trackinfo menu, so the info-provider can't reach it
# either. So an add arrives with just: episode TITLE, the date/duration subtitle, $SERVICE
# and the episode ARTWORK URL.
#
# THE RESOLUTION: the Podcast plugin keeps the user's subscriptions — with their real RSS
# urls — in its own prefs (plugin.podcast:feeds). Fetch those feeds and find the episode.
# The artwork url is the primary key: it appears verbatim in the RSS as <itunes:image href>
# and is unique per episode (the same trick 0.1.44 used to recover Qobuz album ids from
# cover urls). Title is the fallback. The matched <enclosure url> is the durable play url;
# it's stored podcast://-prefixed so the Podcast plugin's own protocol handler plays it and
# keeps its resume-position tracking.
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

my $log   = Slim::Utils::Log::logger('plugin.listenlater');
my $cache = Slim::Utils::Cache->new();

# A feed's episode list changes when a new episode drops; a short working TTL keeps adds
# fast (the common case is several adds in one browsing session) without going stale for
# long. The fallback keeps resolution working through a transient fetch failure.
use constant FEED_TTL          => 3600;        # 1h
use constant FEED_FALLBACK_TTL => 7 * 86400;   # 7d
use constant HTTP_TIMEOUT      => 20;
use constant CACHE_VER         => 1;           # bump to invalidate parsed feeds

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
# Walks the subscribed feeds in order and calls back with the first match. Feeds are
# fetched at most once per FEED_TTL, so a second add in the same session is instant.
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

    my $step;
    $step = sub {
        my $feed = shift @queue;
        unless ($feed) {
            $log->warn("LL: podcast resolve — no feed contained '" . ($title // '?') . "'");
            return $cb->(undef);
        }
        _feedEpisodes($feed->{value}, sub {
            my ($eps, $show) = @_;
            for my $e (@$eps) {
                my $hit = (length $wantImage && ($e->{image} // '') eq $wantImage)          ? 'image'
                        : (length $wantTitle && _normTitle($e->{title}) eq $wantTitle)      ? 'title'
                        : '';
                next unless $hit;
                $log->warn("LL: podcast resolved by $hit -> " . ($e->{url} // '?'));
                return $cb->({ %$e, show => ($show || $feed->{name}) });
            }
            $step->();
        });
    };
    $step->();
    return;
}

# Fetch + parse one feed -> $cb->(\@episodes, $showName). Cached; a failed fetch falls back
# to the last good parse so one flaky feed doesn't break resolution.
sub _feedEpisodes {
    my ($url, $cb) = @_;
    return $cb->([], undef) unless defined $url && length $url;

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
        { timeout => HTTP_TIMEOUT },
    )->get($url);
    return;
}

# Parse an RSS podcast feed -> (\@episodes, $showName). Deliberately a tolerant regex scan
# rather than a full XML parse: podcast RSS is machine-generated, we need four fields per
# item, and this can't die on the malformed-but-common feeds an XML parser would reject.
sub _parseFeed {
    my ($xml) = @_;
    return ([], undef) unless defined $xml && length $xml;

    # Show name = the channel <title> (the first one, before any <item>).
    my ($head) = $xml =~ /^(.*?)<item[\s>]/s;
    $head = $xml unless defined $head;
    my ($show) = $head =~ m{<title[^>]*>(.*?)</title>}s;
    $show = _clean($show);

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
            title    => _clean($t),
            image    => (_clean($img) || $chanImg),
            duration => _seconds(_clean($dur)),
            year     => ((_clean($pub) // '') =~ /\b(\d{4})\b/) ? $1 : undef,
        };
    }
    return (\@eps, $show);
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
