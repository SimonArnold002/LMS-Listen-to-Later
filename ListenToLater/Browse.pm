package Plugins::ListenToLater::Browse;

# The browsable list. Top level: Listen to Later (N) / Played (N) / Settings.
# Each section lists saved albums; an album row drills into a small submenu
# (Play album / Remove / Move) so the manage actions work in Material and the
# classic skin alike. Sort order comes from the `sort` pref.

use strict;
use warnings;

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(cstring);

use Plugins::ListenToLater::DB;
use Plugins::ListenToLater::Sources;

use constant ICON => 'plugins/ListenToLater/html/images/ListenToLaterIcon_svg.png';

my $log   = logger('plugin.listentolater');
my $prefs = preferences('plugin.listentolater');

# ---------------------------------------------------------------------------
# Top level
# ---------------------------------------------------------------------------
sub topLevel {
    my ($client, $callback, $args) = @_;

    my $later  = Plugins::ListenToLater::DB::count('later');
    my $played = Plugins::ListenToLater::DB::count('played');

    my @items = (
        {
            name  => cstring($client, 'PLUGIN_LTL_LISTEN_LATER') . " ($later)",
            type  => 'link',
            url   => sub { _renderList($_[0], $_[1], 'later') },
            image => ICON,
        },
        {
            name  => cstring($client, 'PLUGIN_LTL_PLAYED') . " ($played)",
            type  => 'link',
            url   => sub { _renderList($_[0], $_[1], 'played') },
            image => ICON,
        },
        {
            name    => cstring($client, 'PLUGIN_LTL_SETTINGS'),
            type    => 'link',
            weblink => '/plugins/ListenToLater/settings.html',
            image   => ICON,
        },
    );

    $callback->({ items => \@items });
}

# ---------------------------------------------------------------------------
# A section list
# ---------------------------------------------------------------------------
sub _renderList {
    my ($client, $callback, $status) = @_;

    my $sort = $prefs->get('sort') || 'added';
    my $rows = Plugins::ListenToLater::DB::list($status, $sort);

    my @items = map { _albumRow($client, $_, $status) } @$rows;

    unless (@items) {
        push @items, {
            name => cstring($client, 'PLUGIN_LTL_EMPTY'),
            type => 'text',
        };
    }

    $callback->({ items => \@items });
}

sub _albumRow {
    my ($client, $rec, $status) = @_;

    my $name = '';
    $name .= $rec->{artist} . " \x{2013} " if $rec->{artist};
    $name .= $rec->{album_title} // cstring($client, 'PLUGIN_LTL_UNKNOWN_ALBUM');
    $name .= " ($rec->{year})" if $rec->{year};

    return {
        name  => $name,
        line2 => ucfirst($rec->{source} || ''),
        image => $rec->{artwork} || ICON,
        type  => 'link',
        url   => sub { _albumMenu($_[0], $_[1], $rec, $status) },
    };
}

# ---------------------------------------------------------------------------
# Per-album submenu: Play / Remove / Move
# ---------------------------------------------------------------------------
sub _albumMenu {
    my ($client, $callback, $rec, $status) = @_;

    Plugins::ListenToLater::Sources::buildPlayableItems($client, $rec, sub {
        my $playItems = shift || [];

        my @items;
        for my $p (@$playItems) {
            # Single resolved album → label it "Play album"; multiple search
            # candidates keep their own (album) names so they're distinguishable.
            if (@$playItems == 1 && ($p->{type} || '') ne 'text') {
                $p->{name} = cstring($client, 'PLUGIN_LTL_PLAY_ALBUM');
            }
            push @items, $p;
        }

        push @items, {
            name => cstring($client, 'PLUGIN_LTL_REMOVE'),
            type => 'link',
            url  => sub {
                my ($c, $cb) = @_;
                Plugins::ListenToLater::DB::remove($rec->{id});
                $cb->({ items => [{
                    name => cstring($c, 'PLUGIN_LTL_REMOVED'),
                    type => 'text', showBriefly => 1,
                }] });
            },
        };

        my $target  = $status eq 'later' ? 'played' : 'later';
        my $moveStr = $status eq 'later' ? 'PLUGIN_LTL_MOVE_PLAYED' : 'PLUGIN_LTL_MOVE_LATER';

        push @items, {
            name => cstring($client, $moveStr),
            type => 'link',
            url  => sub {
                my ($c, $cb) = @_;
                Plugins::ListenToLater::DB::setStatus($rec->{id}, $target);
                $cb->({ items => [{
                    name => cstring($c, 'PLUGIN_LTL_MOVED'),
                    type => 'text', showBriefly => 1,
                }] });
            },
        };

        $callback->({ items => \@items });
    });
}

1;
