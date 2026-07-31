package Plugins::ListenLater::Browse;

# Single-page content view. On entry the user sees, in one list:
#   • Plugin Settings (top)
#   • a Material header "Listen Later (N)" + its albums
#   • a Material header "Wish List (N)" + its albums
#   • a Material header "Played (N)" + its albums
# Each album row is directly playable (type => 'playlist'); Remove/Move live in
# the row's "…" context menu via itemActions => info → the contextmenu query
# (see Plugin::_contextMenuQuery). Sort order comes from the `sort` pref.

use strict;
use warnings;

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(cstring);

use Plugins::ListenLater::DB;
use Plugins::ListenLater::Sources;

use constant ICON => 'plugins/ListenLater/html/images/ListenLaterIcon_svg.png';

# Per-section icons. Wish List uses Material's own "shopping_cart" font icon via the
# "_MTL_icon_<name>" filename convention (same trolley as the context-menu action);
# Played uses Google's "music_history" SVG via the "_svg.png" recolour convention
# (that glyph isn't in Material's bundled icon font, so it can't be a font icon).
use constant ICON_WISHLIST  => 'plugins/ListenLater/html/images/WishListIcon_MTL_icon_shopping_cart.png';
use constant ICON_PLAYED => 'plugins/ListenLater/html/images/PlayedIcon_svg.png';
# Settings entry uses Material's own "settings" cog font icon via the same
# "_MTL_icon_<name>" convention (matches the sibling ListenBrainz plugin's cog).
use constant ICON_SETTINGS => 'plugins/ListenLater/html/images/SettingsIcon_MTL_icon_settings.png';

my $log   = logger('plugin.listenlater');
my $prefs = preferences('plugin.listenlater');

# Map a list status to its section icon (Listen Later uses the plugin icon).
sub _iconFor {
    my ($status) = @_;
    return ICON_WISHLIST  if $status eq 'wishlist';
    return ICON_PLAYED if $status eq 'played';
    return ICON;
}

# ---------------------------------------------------------------------------
# Top level — the whole list on one page
# ---------------------------------------------------------------------------
sub topLevel {
    my ($client, $callback, $args) = @_;

    my $wantHeaders = _wantHeaders(_featuresOf($args));

    my @items;

    push @items, {
        name    => cstring($client, 'PLUGIN_LL_SETTINGS'),
        type    => 'link',
        weblink => '/plugins/ListenLater/settings.html',
        image   => ICON_SETTINGS,
    };

    push @items, _section($client, 'later',  'PLUGIN_LL_LISTEN_LATER', $wantHeaders);
    push @items, _section($client, 'wishlist',  'PLUGIN_LL_WISHLIST',        $wantHeaders);
    push @items, _section($client, 'played', 'PLUGIN_LL_PLAYED',       $wantHeaders);

    $callback->({ items => \@items });
}

sub _section {
    my ($client, $status, $titleStr, $wantHeaders) = @_;

    my $rows  = Plugins::ListenLater::DB::list($status, $prefs->get('sort') || 'added');
    my $count = scalar @$rows;

    my @items = ( _header($client, $status, $titleStr, $count, $wantHeaders) );

    # NB: deliberately NO "empty" text row here. Material disables the grid/list
    # view toggle for the whole page if any item is type => 'text' (browse-resp.js:
    # `types.has("text")`), whereas type => 'header' is fine. An empty section just
    # shows its "(0)" header. (The header count conveys emptiness.)
    push @items, map { _row($client, $_) } @$rows;

    return @items;
}

# A section header. Emitted only when the client advertises header support
# (features contains 'h', i.e. features:hi — what Material sends); other clients
# get plain text. On Material >= 6.4.3 the type is 'header-basic' (clears the
# item's actions so it renders as a plain full-width divider rather than an
# actionable grid card); older Material gets the long-standing 'header'. See
# _headerType. We keep the re-list url so 'header' still drills on older skins;
# 'header-basic' strips the action, so the url is harmlessly ignored there.
sub _header {
    my ($client, $status, $titleStr, $count, $wantHeaders) = @_;

    my $name = cstring($client, $titleStr) . " ($count)";
    # Give the header an image so the page's grid view stays available (an
    # image-less item sets haveWithoutIcons and disables the grid/list toggle).
    my $h = { name => $name, type => $wantHeaders ? _headerType() : 'text', image => _iconFor($status) };

    if ($wantHeaders) {
        $h->{url}         = sub { _renderSection($_[0], $_[1], $status) };
        $h->{passthrough} = [ {} ];
    }

    return $h;
}

sub _renderSection {
    my ($client, $callback, $status) = @_;
    my $rows = Plugins::ListenLater::DB::list($status, $prefs->get('sort') || 'added');
    my @items = @$rows
        ? map { _row($client, $_) } @$rows
        : ({ name => cstring($client, 'PLUGIN_LL_EMPTY'), type => 'text' });
    $callback->({ items => \@items });
}

# Leading glyphs, chosen so the symbol matches what the row actually is. All are plain
# text glyphs (NOT colour emoji) so they render identically on every client — these are
# drawn by the viewer's browser, not the server, so anything that resolves to an emoji font
# would look different per device (and be a missing-glyph box where there's no emoji font):
#   ♫ (two beamed notes) = a release holding MORE THAN ONE track
#   ♪ (one note)         = ONE track: a one-track release OR an individual saved Track
#   ❝ (heavy turned comma) = a PODCAST episode — speech rather than music
# (Release vs individual Track is then told apart by the subtitle word, not the glyph.)
# NB there is no plain-text MICROPHONE to use for podcasts: the only ones (U+1F3A4,
# U+1F399) live in the emoji planes, and though U+1F399 defaults to text presentation
# almost no font ships a monochrome glyph for it, so it renders in colour from the emoji
# font — or not at all. The quote mark is the closest speech symbol that behaves.
use constant GLYPH_MULTI   => "\x{266b}";
use constant GLYPH_SINGLE  => "\x{266a}";
use constant GLYPH_PODCAST => "\x{275d}";
use constant SEP           => " \x{00b7} ";   # " · " subtitle separator

# The glyph for a row: ❝ for a podcast episode, ♪ for one track, ♫ for more than one.
#
# The glyph answers "how many tracks", so it is driven by the MEASURED count whenever we
# have one — not by the release type. The type is MusicBrainz's or the service's word, and
# it is frequently not literal: adieu's 'Wanna me' is labelled an EP and holds exactly ONE
# track, so it drew ♫ while the truthful figure sat unused in track_count. The label is
# theirs and stays as they wrote it (see _typeLabel); this symbol is OURS, and it claims
# something specific, so it should tell the truth.
#
# Falls back to the type only while the count is still unknown — a row added but not yet
# played or opened. Library rows are the same: they carry no stored count (Played counts
# those live, and doing that here would be a schema query per row on every list render), but
# their type was classified from the real library count at add time, so it is already sound.
sub _glyphFor {
    my ($rec) = @_;
    return GLYPH_PODCAST if ($rec->{source} || '') eq 'podcast';
    return GLYPH_SINGLE  if ($rec->{kind}   || '') eq 'track';

    my $n = $rec->{track_count};
    if (defined $n && $n =~ /^\d+$/ && $n > 0) {
        return $n == 1 ? GLYPH_SINGLE : GLYPH_MULTI;
    }

    return GLYPH_SINGLE  if ($rec->{rel_type} || '') eq 'single';
    return GLYPH_MULTI;
}

# Dispatch a stored row to the right renderer.
sub _row {
    my ($client, $rec) = @_;
    return (($rec->{kind} || '') eq 'track')
        ? _trackRow($client, $rec)
        : _albumRow($client, $rec);
}

# The type word shown as the first segment of a row's subtitle. A podcast episode says
# "Podcast"; any other track says "Track"; a release is its classified type (Album / EP /
# Single), defaulting to Album until it's been resolved and classified (see _albumTracks /
# relTypeFor).
sub _typeLabel {
    my ($client, $rec) = @_;
    return cstring($client, 'PLUGIN_LL_TYPE_PODCAST') if ($rec->{source} || '') eq 'podcast';
    return cstring($client, 'PLUGIN_LL_TYPE_TRACK') if ($rec->{kind} || '') eq 'track';
    my $rt = $rec->{rel_type} || 'album';
    my %str = (album => 'PLUGIN_LL_TYPE_ALBUM', ep => 'PLUGIN_LL_TYPE_EP', single => 'PLUGIN_LL_TYPE_SINGLE');
    return cstring($client, $str{$rt} || 'PLUGIN_LL_TYPE_ALBUM');
}

# A directly-playable album row. type => 'playlist' + a url coderef that resolves
# the album's tracks gives Material the play button and Play/Play Next/Add in the
# "…". itemActions→info adds the "…" → More context entry → our Remove/Move menu
# (refreshes the list in place; see Plugin::_contextMenuQuery). The subtitle carries
# the ♫ glyph + the type word ("Album"/"EP"/"Single" · source) and marks it a release;
# the NAME line stays the plain "Artist – Album (Year)" it has always been.
sub _albumRow {
    my ($client, $rec) = @_;

    my $name = '';
    $name .= $rec->{artist} . " \x{2013} " if $rec->{artist};
    $name .= $rec->{album_title} // cstring($client, 'PLUGIN_LL_UNKNOWN_ALBUM');

    # …and the year, unless the title is already carrying it ("The New World (2026) (2026)").
    # A sibling feed labels its rows "Album (YYYY)" and Material hands us that whole label as
    # $ALBUMNAME, so the year ends up inside the stored title. Only skipped when the trailing
    # parenthesised year is the SAME year we hold — a title that genuinely ends in a
    # different year ("Live (1971)" released 2026) still gets its own appended.
    my $year = $rec->{year};
    $name .= " ($year)" if $year && $name !~ /\(\Q$year\E\)\s*$/;

    return {
        name        => $name,
        line2       => _glyphFor($rec) . ' ' . _typeLabel($client, $rec)
                       . SEP . ucfirst($rec->{source} || ''),
        image       => $rec->{artwork} || _iconFor($rec->{status}),
        type        => 'playlist',
        url         => \&_albumTracks,
        passthrough => [ { id => $rec->{id} } ],
        itemActions => {
            info => {
                command     => [ 'listenlater', 'contextmenu' ],
                fixedParams => { id => $rec->{id} },
            },
        },
    };
}

# A directly-playable single-track row. Unlike a release it plays on click (type =>
# 'audio' with the stored play url) rather than drilling into a tracklist — a saved
# track is one song. The "♪ Track · <album> · <source>" subtitle distinguishes it.
# Same itemActions→info "…" → More (Remove/Move) as a release row.
sub _trackRow {
    my ($client, $rec) = @_;

    my $ref = (ref $rec->{ref} eq 'HASH') ? $rec->{ref} : {};

    my $name = '';
    $name .= $rec->{artist} . " \x{2013} " if $rec->{artist};
    $name .= $rec->{track_title} // $rec->{album_title} // cstring($client, 'PLUGIN_LL_UNKNOWN_ALBUM');

    my $sub = _glyphFor($rec) . ' ' . _typeLabel($client, $rec);
    $sub .= SEP . $rec->{album_title} if defined $rec->{album_title} && length $rec->{album_title};
    # The source segment is dropped for a podcast: the type word already reads "Podcast",
    # so appending it again would give "Podcast · <show> · Podcast".
    $sub .= SEP . ucfirst($rec->{source} || '')
        if $rec->{source} && $rec->{source} ne 'podcast';

    return {
        name        => $name,
        line2       => $sub,
        image       => $rec->{artwork} || _iconFor($rec->{status}),
        type        => 'audio',
        url         => $ref->{url},
        passthrough => [ { id => $rec->{id} } ],
        itemActions => {
            info => {
                command     => [ 'listenlater', 'contextmenu' ],
                fixedParams => { id => $rec->{id} },
            },
        },
    };
}

# Material home-page shelf: the "Listen Later" albums as a flat, quantity-stable
# card row. The Material carousel and its "show all" click-in are the SAME feed
# (Material exposes no way to give the click-in a different command), so the result
# must not vary by request quantity or structure — otherwise item_ids shift and
# deep playback resolves the wrong album. So: always the same flat list of rows.
sub homeShelf {
    my ($client, $callback, $args) = @_;
    my $rows = Plugins::ListenLater::DB::list('later', $prefs->get('sort') || 'added');
    $callback->({ items => [ map { _row($client, $_) } @$rows ] });
}

# Resolve the tracks for an album row (drill-in and play both call this).
sub _albumTracks {
    my ($client, $callback, $args, $pt) = @_;

    my $rec = Plugins::ListenLater::DB::get($pt->{id});
    unless ($rec) {
        return $callback->({ items => [{ name => cstring($client, 'PLUGIN_LL_EMPTY'), type => 'text' }] });
    }

    Plugins::ListenLater::Sources::resolveTracks($client, $rec, sub {
        my $tracks = shift || [];
        # Some services prepend non-playable helper items (e.g. Bandcamp's
        # "Download album from …" text + the page weblink). Keep them out of the
        # drill view / play queue. Fall back to the raw list if filtering empties
        # it (e.g. the single "no match" text row) so the view is never blank.
        my @playable = grep {
            ref $_ eq 'HASH' && !$_->{weblink} && (($_->{type} // '') ne 'text')
        } @$tracks;
        @playable = @$tracks unless @playable;

        # How many REAL tracks the resolve produced. Deliberately NOT `scalar @playable`:
        # that list is what the DRILL VIEW shows, which is a different question. Qobuz sends
        # 5-6 info rows with every album ('Artist: …', 'Credits', 'Copyright', …) that belong
        # in the view but are not tracks, and the display filter above keeps them — so
        # counting the view stored 6 for a 1-track release and 17 for an 11-track album, and
        # Played then wanted 60% of THAT (see Sources::isPlayableTrack). Ask the one predicate
        # LMS itself uses, and ask it of the RAW list so nothing the fallback restores — the
        # single "no match" text row of a failed resolve — can be mistaken for a track.
        my $resolved = Plugins::ListenLater::Sources::countPlayableTracks($tracks);

        # Here — and only here — the release's real tracklist is in hand for a row that is
        # already stored, so this is where what the DB knows about it gets put right. Three
        # things, all free at this point:
        #
        #  • the TRACK COUNT, always refreshed. It's what Played thresholds against, and a
        #    row added before 0.1.88 (or whose add-time resolve failed) has none — until it
        #    does, a release shorter than the streaming_min_tracks floor can never be marked
        #    Played, however many times it's heard. Library releases don't need it (Played
        #    counts those live from the library).
        #  • the release TYPE, when it was never classified (updateRelType is a no-op once
        #    set, so this only fills a NULL).
        #  • a stored 'single' that resolves to MORE than one track — never a single in LL's
        #    sense whatever its source called it — corrected in place (the one forced
        #    update). This is what repairs rows saved before the add-time check existed.
        if (($rec->{kind} || '') ne 'track' && $resolved) {
            my $count  = $resolved;
            my $stored = $rec->{rel_type} || '';
            my $wrong  = Plugins::ListenLater::Sources::singleIsWrong($stored, $count);

            Plugins::ListenLater::DB::updateTrackCount($rec->{id}, $count)
                if ($rec->{source} || '') ne 'library';

            if (!$stored || $wrong) {
                my $rt = Plugins::ListenLater::Sources::relTypeFor(count => $count);
                if ($rt) {
                    Plugins::ListenLater::DB::updateRelType($rec->{id}, $rt, $wrong);
                    $log->warn("LL: rec $rec->{id} was stored as a single but resolves to "
                        . "$count tracks — reclassified as $rt") if $wrong;
                }
            }
        }

        $callback->({ items => \@playable });
    });
}

# ---------------------------------------------------------------------------
sub _featuresOf {
    my ($args) = @_;
    return (ref $args->{params} eq 'HASH') ? ($args->{params}{features} // '') : '';
}

sub _wantHeaders {
    my ($features) = @_;
    return (defined $features && $features =~ /h/) ? 1 : 0;
}

# Which header item-type to emit for a header-capable (Material) client.
# Material's 'header-basic' (a non-actionable, full-width divider) only exists
# from Material 6.4.3 onwards; older Material understands only 'header'. To avoid
# changing behaviour for users on older skins, use 'header-basic' iff the running
# Material is >= 6.4.3 (or a non-release dev/test build), else fall back to the
# long-standing 'header'. Cached — the Material version can't change at runtime.
my $_headerTypeCache;
sub _headerType {
    return $_headerTypeCache if defined $_headerTypeCache;
    my $ver = eval { Plugins::MaterialSkin::Plugin->getPluginVersion() };
    my $useBasic;
    if (!defined $ver) {
        $useBasic = 0;                                  # can't tell -> stay safe
    } elsif ($ver =~ /^(\d+)\.(\d+)\.(\d+)/) {
        $useBasic = ( $1 <=> 6 || $2 <=> 4 || $3 <=> 3 ) >= 0 ? 1 : 0;
    } else {
        $useBasic = 1;                                  # dev/test build -> new
    }
    return $_headerTypeCache = $useBasic ? 'header-basic' : 'header';
}

1;
