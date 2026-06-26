package Plugins::ListenLater::HomeExtras;

# Material Skin home-page scrollable row for the Listen Later list. One
# HomeExtraBase subclass: own tag -> own CLI dispatch -> own feed (Browse::homeShelf).
# The feed returns a FLAT card list that does not vary by request quantity — the
# carousel and its "show all" click-in are the SAME feed, so a quantity- or
# structure-dependent result would shift item_ids and break deep playback (the
# sibling plugin's 0.6.11 rule).

use strict;
use base qw(Plugins::MaterialSkin::HomeExtraBase);

use Plugins::ListenLater::Browse;

# Single source of truth for the app icon path lives in Browse (Browse::ICON).
use constant ICON => Plugins::ListenLater::Browse::ICON;

sub initPlugin {
    my ($class) = @_;

    $class->SUPER::initPlugin(
        feed  => \&feed,
        tag   => 'LLHome',
        extra => { title => 'PLUGIN_LL_LISTEN_LATER', icon => ICON, needsPlayer => 0 },
    );
}

sub feed {
    my ($client, $cb, $args) = @_;
    Plugins::ListenLater::Browse::homeShelf($client, $cb, $args);
}

1;
