#!/usr/bin/env perl
# Regression tests for how the Material context-menu entries are DELIVERED (0.1.95).
#
# Material 6.4.6 added a registration API — `registerCustomAction($section, $action)` — so a
# plugin hands Material its entries instead of editing the shared prefs/material-skin/actions.json.
# Material merges the two client-side (customactions.js `getSectionActions` walks the file list
# and then the plugin list), which makes exactly one failure mode catastrophic and silent on our
# side: if we register AND leave our old entries in the file, EVERY "Add" appears TWICE. That is
# what most of this suite is about.
#
# THE DELIVERY TIER (0.1.110) decides which of those two lists an entry goes to, and the suite
# is organised around it. Material grew the API in two steps:
#   * tier 0 — no registerCustomAction at all (< 6.4.6): the file carries everything.
#   * tier 1 — 6.4.6/6.4.7: the "Add" entries register, but four things CANNOT move and the
#     suite pins them in the file — the EMPTY suppressors (the API takes an action and pushes
#     it, so "exists and is empty" is inexpressible), the podcasts-* per-app override (Material
#     tests `appCat in customActions`, the FILE object alone), and 'track'/'queue-track' (the
#     only two it resolves in the BROWSER, snapshotted once on a bus event only the
#     customactions.json fetch fires — 0.1.97).
#   * tier 2 — >= 6.4.8, where upstream PR #1257 closed all three gaps: everything registers and
#     the file is PRUNED, then UNLINKED once it is empty.
#
# Tier 2 needs the capability AND the version, and that is the point of the tier table below:
# on 6.4.6/6.4.7 the one-argument empty-section call pushes a NULL into the section, which
# breaks every custom action in it — other plugins' included. A bare ->can() test is not safe.
#
# Note the suite has no getPluginVersion stub by default, so everything outside the tier-2
# section runs at tier 1. That is deliberate — it is the tier most installs are on — but it is
# also why the tier-2 section exists at all: without it, 746 checks passed against code they
# never executed.
#
# Nothing here is asserted from a copy of the action definitions: the categories and the entry
# shapes are read back out of _materialActionSet, and the two delivery paths are compared against
# EACH OTHER, so a change to a command is not silently blessed by a restated expectation.
use strict;
use warnings;
use FindBin;
use File::Temp ();
use File::Basename;
use File::Path ();
use JSON::XS ();
require "$FindBin::Bin/t_stubs.pl";

ll_require('DB', 'Sources', 'Browse', 'Played', 'Settings', 'Plugin');

my ($pass, $fail) = (0, 0);
sub is {
    my ($desc, $got, $want) = @_;
    my $ok = (!defined $got && !defined $want)
          || (defined $got && defined $want && "$got" eq "$want");
    $ok ? $pass++ : $fail++;
    printf "%s %-62s got=%-24s want=%s\n", ($ok ? 'ok  ' : 'FAIL'), $desc,
        (defined $got ? "'$got'" : '(undef)'), (defined $want ? "'$want'" : '(undef)');
}
sub section { printf "\n== %s\n", $_[0] }

# --- the fake Material -------------------------------------------------------------------
# The API is a plain sub, and _materialActionTier's capability half is a ->can() test, so
# presence is controlled by installing / deleting the symbol rather than by a flag — which is
# precisely what the plugin checks. Its VERSION half is driven by set_material_version() below.
# @REG records every call: [ $section, $action ] for an entry, [ $section ] for an empty
# section (0.1.110) — that argument count IS the difference, so the suite reads it directly.
our @REG;
sub install_api {
    no strict 'refs';
    no warnings 'redefine';
    *{'Plugins::MaterialSkin::Plugin::registerCustomAction'} = sub { push @REG, [ @_ ] };
}
sub remove_api {
    no strict 'refs';
    delete $Plugins::MaterialSkin::Plugin::{registerCustomAction};
}

my $JSON = JSON::XS->new->utf8->canonical;
my $tmp  = File::Temp::tempdir(CLEANUP => 1);
$Slim::Utils::Prefs::DIR = $tmp;

sub actions_file { return "$tmp/material-skin/actions.json" }
sub read_file {
    my $f = actions_file();
    return {} unless -e $f;
    open my $fh, '<:raw', $f or die $!;
    local $/; my $raw = <$fh>; close $fh;
    return $JSON->decode($raw);
}
# Write a populated podcasts-* pair straight into actions.json, exactly as a pre-0.1.136
# build left it. Used to prove the CLEAR/PRUNE machinery still removes what this build can
# no longer produce — the clearing half is deliberately kept while the writing half is gone.
sub seed_husk {
    my (@cats) = @_;
    my $f = actions_file();
    File::Path::make_path((File::Basename::fileparse($f))[1]);
    my $data = -e $f ? read_file() : {};
    $data->{$_} = [ { title => 'Add to Listen Later',
                      lmscommand => [ 'listenlater', 'addctx', 'kind:podcast' ] } ] for @cats;
    open my $fh, '>:raw', $f or die $!;
    print $fh $JSON->encode($data); close $fh;
}
sub reset_all {
    @REG = ();
    $Plugins::ListenLater::Plugin::REGISTERED   = 0;
    $Plugins::ListenLater::Plugin::REGISTERED_N = 0;
    %Plugins::ListenLater::Plugin::UNREGISTERED = ();
    %Plugins::ListenLater::Plugin::REGISTERED_EMPTY = ();
    %Plugins::ListenLater::Plugin::REGISTERED_POS   = ();
    File::Path::remove_tree("$tmp/material-skin");
}

# The DELIVERY TIER is a version test as well as a capability one (0.1.110), because the
# one-argument "declare an empty section" call means something different — and destructive —
# on 6.4.6/6.4.7. Material reports its version through a class METHOD, so the stub takes the
# class name as its first argument, exactly as the real one does. Absent by default, which is
# what pins tier 1 as the safe answer when the version can't be read.
sub set_material_version {
    my ($v) = @_;
    no strict 'refs';
    no warnings 'redefine';
    if (defined $v) {
        *{'Plugins::MaterialSkin::Plugin::getPluginVersion'} = sub { $v };
    }
    else {
        delete $Plugins::MaterialSkin::Plugin::{getPluginVersion};
    }
}
# A one-argument registerCustomAction records [ $cat ] — a two-argument one [ $cat, $action ].
# That is the whole difference between declaring an empty section and pushing an entry, so the
# suite reads it straight off @REG rather than through a flag of its own.
sub registered_empties { my @e = sort map { $_->[0] } grep { @$_ == 1 } @REG; return @e }
sub registered_actions { my @a = grep { @$_ == 2 } @REG; return @a }
# scalar() on a sub returning `sort ...` is undefined, so count through an array, always.
sub n_empties { my @e = registered_empties(); return scalar @e }
sub n_actions { my @a = registered_actions(); return scalar @a }
# A Material whose registerCustomAction DIES — the case the file write has to catch. $REFUSE
# is a coderef deciding per section, so a total failure and a partial one are the same stub.
our $REFUSE;
sub install_failing_api {
    my ($refuse) = @_;
    $REFUSE = $refuse;
    no strict 'refs';
    no warnings 'redefine';
    *{'Plugins::MaterialSkin::Plugin::registerCustomAction'} = sub {
        die "registerCustomAction: nope\n" if $REFUSE->($_[0]);
        push @REG, [ @_ ];
    };
}
# Every entry in the file that is OURS, by the plugin's own test — the one that matters, since
# it is what a re-run strips and what a doubled menu is made of.
sub ours_in_file {
    my ($data) = @_;
    my $n = 0;
    for my $cat (keys %$data) {
        next unless ref $data->{$cat} eq 'ARRAY';
        $n += grep { Plugins::ListenLater::Plugin::_isOurAction($_) } @{ $data->{$cat} };
    }
    return $n;
}
sub registered_count { my %c; $c{ $_->[0] }++ for @REG; return \%c }

my ($POSITIVE, $FILEONLY) = Plugins::ListenLater::Plugin::_materialActionSet();
my $TOTAL = 0; $TOTAL += scalar @{ $POSITIVE->{$_} } for keys %$POSITIVE;
# The file half that is written on BOTH paths, with no podcast feeds subscribed: the two
# client-resolved categories. "our entries in the file" is $TOTAL + this on the legacy path
# and exactly this on the API path — an API-path count of 0 would mean Now Playing lost Add.
my $FILEHALF = 0; $FILEHALF += scalar @{ $FILEONLY->{$_} } for keys %$FILEONLY;

# ---------------------------------------------------------------------------
section('the action set itself');

is('positive categories are the six SERVER-resolved menu surfaces',
    join(',', sort keys %$POSITIVE),
    'album,album-track,online-album,online-track,playlist,playlist-track');
is('no online-artist (0.1.32 — we save albums/tracks, not artists)',
    (exists $POSITIVE->{'online-artist'} ? 'present' : 'absent'), 'absent');
# 0.1.97: registering these two loses them to Material's once-only client-side snapshot.
is('the client-resolved surfaces are file-only, with no podcast feeds subscribed',
    join(',', sort keys %$FILEONLY), 'queue-track,track');
is('...and neither is also registered (that would double them)',
    join(',', grep { exists $POSITIVE->{$_} } sort keys %$FILEONLY), '');
is('every positive category carries Add + Wish List',
    join(',', map { scalar @{ $POSITIVE->{$_} } } sort keys %$POSITIVE),
    '2,2,2,2,2,2');
is('...and so does each file-only surface', $FILEHALF, 4);

# ---------------------------------------------------------------------------
section('Material 6.4.6+ — entries go to the API, not the file');

reset_all();
remove_api();
Plugins::ListenLater::Plugin::_writeMaterialActions();   # a 0.1.94 install, as upgraded from
my $legacy = read_file();
is('legacy install has our entries in the file', ours_in_file($legacy), $TOTAL + $FILEHALF);

install_api();
$Plugins::ListenLater::Plugin::REGISTERED = 0;
%Plugins::ListenLater::Plugin::REGISTERED_POS = ();
my $n = Plugins::ListenLater::Plugin::_registerMaterialActions();
Plugins::ListenLater::Plugin::_writeMaterialActions();
my $data = read_file();

is('every positive entry registered with Material', $n, $TOTAL);
is('...in the same six sections',
    join(',', sort keys %{ registered_count() }), join(',', sort keys %$POSITIVE));
is('no REGISTERED entry of ours left in the file (or every Add shows twice)',
    ours_in_file($data) - $FILEHALF, 0);
is('...while the client-resolved half stays in the file, where Material can see it',
    join(',', map { scalar @{ $data->{$_} // [] } } qw(queue-track track)), '2,2');
is('the emptied positive categories are removed, not left as husks',
    join(',', grep { exists $data->{$_} } sort keys %$POSITIVE), '');
is('own-view suppressors still written (empty)',
    join(',', map { scalar @{ $data->{$_} // [] } } qw(listenlater-album LLHome-album)), '0,0');
is('...and are still PRESENT — an absent category stops suppressing',
    (exists $data->{'listenlater-album'} && exists $data->{'LLHome-album'}) ? 'yes' : 'no', 'yes');
is('radio suppressors still written (TuneIn seed list)',
    (exists $data->{'music-album'} && exists $data->{'news-track'}) ? 'yes' : 'no', 'yes');

# The registered actions must BE the shipped ones, not a second spelling of them.
my ($alb) = grep { $_->[0] eq 'album' } @REG;
is('registered album action is the addctx command',
    join(' ', @{ $alb->[1]{lmscommand} }[0,1]), 'listenlater addctx');
is('...carrying the Add title',   $alb->[1]{title}, 'Add to Listen Later');
is('...and its icon',             $alb->[1]{icon},  'playlist_add');
is('what is registered equals what the legacy path wrote',
    $JSON->encode([ map { $_->[1] } grep { $_->[0] eq 'online-album' } @REG ]),
    $JSON->encode($legacy->{'online-album'}));

# ---------------------------------------------------------------------------
section('registering happens exactly ONCE (there is no unregister, and no de-dupe)');

my $before = scalar @REG;
is('a second postinit-equivalent call registers nothing',
    Plugins::ListenLater::Plugin::_registerMaterialActions(), 0);
is('...so the recorded set is unchanged', scalar @REG, $before);

# A Settings save re-runs the file write to refresh the diagnostics snapshot; the deferred
# radio pass re-runs it 60s after startup. Neither may add a second copy of anything.
Plugins::ListenLater::Plugin::_writeMaterialActions();
Plugins::ListenLater::Plugin::_writeMaterialActions();
is('...and repeated file writes register nothing either', scalar @REG, $before);
is('...and leave only the client-resolved half in the file',
    ours_in_file(read_file()), $FILEHALF);

# ---------------------------------------------------------------------------
section('older Material — the file path is unchanged');

reset_all();
remove_api();
Plugins::ListenLater::Plugin::_writeMaterialActions();
my $old = read_file();
is('nothing registered (no API to register with)', scalar @REG, 0);
is('all our entries are in the file', ours_in_file($old), $TOTAL + $FILEHALF);
is('...byte-identical to what 0.1.94 wrote', $JSON->encode($old), $JSON->encode($legacy));

# ---------------------------------------------------------------------------
section('the pref turned off');

reset_all();
install_api();
Plugins::ListenLater::Plugin::_writeMaterialActions();     # something to clean up
Plugins::ListenLater::Plugin::_clearMaterialActions();
my $cleared = read_file();
is('nothing was registered', scalar @REG, 0);
is('no entry of ours survives in the file', ours_in_file($cleared), 0);
is('and neither do our suppressor categories',
    join(',', grep { exists $cleared->{$_} } qw(listenlater-album LLHome-album music-album)), '');

# ---------------------------------------------------------------------------
section("someone else's entries are never touched");

reset_all();
install_api();
File::Path::make_path("$tmp/material-skin");
open my $fh, '>:raw', actions_file() or die $!;
print $fh $JSON->encode({
    'album'       => [ { title => 'Someone else', lmscommand => [ 'otherplugin', 'go' ] } ],
    'qobuz-album' => [ { title => 'Their scoping', lmscommand => [ 'otherplugin', 'go' ] } ],
});
close $fh;
Plugins::ListenLater::Plugin::_registerMaterialActions();
Plugins::ListenLater::Plugin::_writeMaterialActions();
my $shared = read_file();
is('a third party entry in a category we vacated survives',
    scalar @{ $shared->{'album'} // [] }, 1);
is('...and is theirs', $shared->{'album'}[0]{title}, 'Someone else');
is('a populated foreign per-command category survives',
    scalar @{ $shared->{'qobuz-album'} // [] }, 1);

# ---------------------------------------------------------------------------
section('a registration Material REFUSES falls back to the file, not to nothing');
# The API path is chosen by capability, but delivery is decided by what actually happened:
# registerCustomAction can die, and the file write is the only other way an entry reaches a
# menu. Gating the write on the capability test alone strips our entries from the file AND
# registers nothing — the one arrangement that leaves the user with no "Add" anywhere.

reset_all();
install_failing_api(sub { 1 });                       # every section refused
is('nothing registered', Plugins::ListenLater::Plugin::_registerMaterialActions(), 0);
Plugins::ListenLater::Plugin::_writeMaterialActions();
my $refused = read_file();
is('...so every entry is written to the file instead',
    ours_in_file($refused), $TOTAL + $FILEHALF);
is('...in the same six sections',
    join(',', grep { @{ $refused->{$_} // [] } } sort keys %$POSITIVE),
    join(',', sort keys %$POSITIVE));
is('...and it is the shipped set, not a second spelling',
    $JSON->encode($refused->{'online-album'}), $JSON->encode($POSITIVE->{'online-album'}));
is('...with the suppressors still in place',
    (exists $refused->{'listenlater-album'} && exists $refused->{'LLHome-album'}) ? 'yes' : 'no', 'yes');

# A PARTIAL failure is the one that can double: the entries Material DID take must not also
# be written, or every "Add" in those sections shows twice.
reset_all();
install_failing_api(sub { $_[0] eq 'online-album' });
my $partial_n = Plugins::ListenLater::Plugin::_registerMaterialActions();
Plugins::ListenLater::Plugin::_writeMaterialActions();
my $part = read_file();
is('the sections Material accepted are registered', $partial_n, $TOTAL - 2);
is('...and only the refused one joins the file half', ours_in_file($part), 2 + $FILEHALF);
# Categories holding entries of OURS in the file, and categories Material took — the whole
# point is that those two lists never overlap.
my @inFile = grep { grep { Plugins::ListenLater::Plugin::_isOurAction($_) }
                    @{ ref $part->{$_} eq 'ARRAY' ? $part->{$_} : [] } } sort keys %$part;
my %tookIt = map { $_->[0] => 1 } @REG;
is('...that one, alongside the always-file-only pair',
    join(',', @inFile), 'online-album,queue-track,track');
is('...so no section is delivered twice',
    join(',', grep { $tookIt{$_} } @inFile), '');

# The pref turned ON from Settings, mid-run: that re-runs the FILE write, but registering
# outside postinit is not safe (no de-dupe, no unregister). Nothing has registered, so the
# file must carry everything — otherwise the toggle does nothing until the next restart.
reset_all();
install_api();
Plugins::ListenLater::Plugin::_writeMaterialActions();
is('a write with no registration behind it writes the full set',
    ours_in_file(read_file()), $TOTAL + $FILEHALF);
is('...and registers nothing on the way', scalar @REG, 0);

# ---------------------------------------------------------------------------
section('the Settings save actually re-runs the write (0.1.97)');
# The toggle is only useful if saving it does something on THIS run. Before 0.1.97 the
# rewrite was gated on debug_log as well, so on the default config — debug logging off,
# which is every user who has not been asked to turn it on — saving the Material toggle
# did nothing at all until the next restart, in both directions.

{
    no strict 'refs';
    no warnings 'redefine';
    *{'Slim::Utils::PluginManager::isEnabled'} = sub { 1 };   # MaterialSkin present
}
sub save_settings {
    my (%pref) = @_;
    Slim::Utils::Log::clear();
    Plugins::ListenLater::Settings->handler(undef, {
        saveSettings => 1, map { ("pref_$_" => $pref{$_}) } keys %pref,
    });
}

reset_all();
install_api();
Plugins::ListenLater::Plugin::_registerMaterialActions();   # postinit, with the pref on
Plugins::ListenLater::Plugin::_writeMaterialActions();

# Turned OFF, debug logging off — the file half has to go NOW, not at the next restart.
save_settings(material_action => 0, debug_log => 0);
is('turning it OFF with debug_log off clears the file half',
    ours_in_file(read_file()), 0);
is('...and warns that the REGISTERED half waits for a restart',
    (grep { /go at the next .*restart/ } Slim::Utils::Log::lines()) ? 'warned' : 'silent',
    'warned');
# The registered "Add" entries CANNOT be withdrawn, so the empty suppressors are the only
# thing keeping them off our own list, the home shelf and radio browse rows. Deleting them
# here — as the pref-was-off-at-startup path rightly does — would ADD "Add" to every Listen
# Later/Played row until the restart, and using it on a Played row bounces it back.
is('...while the own-view suppressors STAY, because the registered pair is still live',
    join(',', map { (exists read_file()->{$_} ? 'y' : 'n') } qw(listenlater-album LLHome-album)),
    'y,y');
is('...and are still EMPTY (a populated one would offer the entry, not suppress it)',
    join(',', map { scalar @{ read_file()->{$_} // [] } } qw(listenlater-album LLHome-album)),
    '0,0');
is('...and so do the radio empties, for the same reason',
    (exists read_file()->{'music-album'} && exists read_file()->{'news-track'}) ? 'yes' : 'no',
    'yes');

# The same OFF save, but with the file GONE — the one path the `-e $file` early return was
# widened for (a first-ever write that failed, or someone deleting actions.json to "reset"
# it). Everything the clear preserves elsewhere it has to RE-CREATE here, because there is
# nothing on disk to preserve: with the online-* pair still registered and unwithdrawable,
# a missing radio empty puts "Add" back on every TuneIn/BBC Sounds row until the restart.
unlink actions_file();
save_settings(material_action => 0, debug_log => 0);
is('a missing file is rebuilt rather than left absent', (-e actions_file()) ? 'yes' : 'no', 'yes');
is('...with the own-view suppressors re-created',
    join(',', map { (exists read_file()->{$_} ? 'y' : 'n') } qw(listenlater-album LLHome-album)),
    'y,y');
is('...and the radio empties re-created too',
    join(',', map { (exists read_file()->{$_} ? 'y' : 'n') } qw(music-album news-track)),
    'y,y');
is('...all still EMPTY, or they would OFFER the entry instead of suppressing it',
    join(',', map { scalar @{ read_file()->{$_} // [] } }
        qw(listenlater-album LLHome-album music-album news-track)), '0,0,0,0');
is('...and no "Add" entry of ours is written back',  ours_in_file(read_file()), 0);

# Restore the state the next section expects (the file half back, nothing re-registered).
save_settings(material_action => 1, debug_log => 0);

# Turned back ON in the same run. Registration already happened at postinit and there is no
# unregister, so those entries are still live with Material — the write must restore the file
# half ONLY, or every "Add" it re-writes shows twice.
save_settings(material_action => 1, debug_log => 0);
is('turning it ON again restores the client-resolved half',
    ours_in_file(read_file()), $FILEHALF);
is('...and Now Playing / the queue have their Add back',
    join(',', map { scalar @{ read_file()->{$_} // [] } } qw(queue-track track)), '2,2');

# The other direction: the pref was off at STARTUP, so postinit never registered — and the
# save has to deliver the entries itself, or turning the toggle on does nothing until a
# restart.
#
# **This assertion CHANGED in 0.1.111, and the old one is worth recording because it argued
# for a defect.** It used to demand the save write all 16 entries to the FILE and register
# NOTHING ("without registering behind postinit's back"), on the belief that registering
# outside postinit was unsafe. It is not: `$REGISTERED` is a per-run latch and it is FALSE in
# exactly this case, because the pref being off at startup is what stopped postinit
# registering. There is nothing to double. On tier 2 that belief was fatal — with no file
# write left, the save did nothing whatsoever and the toggle needed a server restart, which is
# how it was reported. So the save now registers on EVERY tier, and here the positives go to
# Material with only the client-resolved half left in the file — the normal tier-1 split,
# reached a different way. (Registering is also the better half to land late: the CLI query is
# not browser-cached, where customactions.json is — 0.1.57.)
reset_all();
install_api();
save_settings(material_action => 1, debug_log => 0);
is('turning it ON when nothing registered DELIVERS the whole set',
    n_actions() + ours_in_file(read_file()), $TOTAL + $FILEHALF);
is('...the positives by registering, since that is what tier 1 does with them',
    n_actions(), $TOTAL);
is('...leaving exactly the client-resolved half in the file, never both',
    ours_in_file(read_file()), $FILEHALF);
is('...and says nothing about a restart — nothing is waiting on one',
    (grep { /restart/ } Slim::Utils::Log::lines()) ? 'warned' : 'silent', 'silent');

# ---------------------------------------------------------------------------
section("a third party's EMPTY suppressor survives the pref going OFF (0.1.101)");
# An empty per-command category is not litter, it is a deliberate Add-suppressor — which is
# the whole reason WE write them. The clear pass deleted every empty "*-album/-track/-artist"
# by regex, so it silently disarmed another plugin's suppressors too; harmless while the pass
# only ran at install, but 0.1.97 made it run on every Settings save. It now deletes only the
# categories _radioSuppressorCats() names, i.e. the ones we actually wrote.

reset_all();
install_api();
Plugins::ListenLater::Plugin::_writeMaterialActions();   # our own set, nothing registered
{
    # Injected AFTER the write, so this tests the clear pass and nothing else.
    my $data = read_file();
    $data->{'otherplugin-album'} = [];
    $data->{'otherplugin-track'} = [];
    open my $out, '>:raw', actions_file() or die $!;
    print $out $JSON->encode($data);
    close $out;
}
Plugins::ListenLater::Plugin::_clearMaterialActions();
my $afterClear = read_file();
is('their empty suppressors are still there',
    join(',', map { (exists $afterClear->{$_} ? 'y' : 'n') } qw(otherplugin-album otherplugin-track)),
    'y,y');
is('...while OUR radio empties are gone (nothing registered, so nothing to suppress)',
    join(',', map { (exists $afterClear->{$_} ? 'y' : 'n') } qw(music-album news-track)),
    'n,n');
is('...and so are our own-view suppressors', ours_in_file($afterClear), 0);

# ---------------------------------------------------------------------------
section("...and survives the WRITE pass too, which is the one that runs constantly");
# 0.1.101 hardened the clear pass and deliberately left its twin in _writeMaterialActions
# alone, on the reasoning that the write pass "has to delete empty per-command cruft it cannot
# name". It doesn't have to name it: the cruft is whatever the strip pass just emptied, because
# the 0.1.46–0.1.50 scoping experiments put OUR entries in those categories — that is what makes
# them ours. An empty that arrived empty was never ours and is somebody's deliberate suppressor.
# The exposure is the LARGER of the two: this pass runs at every startup, on every Settings save
# and on the deferred write, so their Add came back every time the user saved our settings.

reset_all();
install_api();
Plugins::ListenLater::Plugin::_writeMaterialActions();
my $ourBaseline = ours_in_file(read_file());
{
    # Injected AFTER a first write, so what is under test is the NEXT write pass — which is
    # how it happens in life: their suppressor is on disk, then we run again.
    my $data = read_file();
    $data->{'otherplugin-album'} = [];
    $data->{'otherplugin-track'} = [];
    # ...and next to it, the shape that MUST still be swept: a category holding nothing but our
    # own entry. Strictly a positive control — remove the provenance test and this one still
    # passes, but without it the fix could be "delete nothing" and the suite would not notice.
    $data->{'qobuz-album'} = [ { title => 'Add to Listen Later',
                                 lmscommand => [ 'listenlater', 'addctx' ] } ];
    open my $out, '>:raw', actions_file() or die $!;
    print $out $JSON->encode($data);
    close $out;
}
Plugins::ListenLater::Plugin::_writeMaterialActions();
my $afterWrite = read_file();
is('their empty suppressors survive the write pass',
    join(',', map { (exists $afterWrite->{$_} ? 'y' : 'n') } qw(otherplugin-album otherplugin-track)),
    'y,y');
is('...while our own 0.1.51-era leftover is still swept (the reason the pass exists)',
    (exists $afterWrite->{'qobuz-album'} ? 'kept' : 'deleted'), 'deleted');
is('...and our own entry set comes out exactly as a clean write leaves it',
    ours_in_file($afterWrite), $ourBaseline);

# ---------------------------------------------------------------------------
section('0.1.136 — a Podcasts-app row shows NO Add at all (same rule as radio)');
# The built-in podcast path is gone, so there is nothing LL can store from a Podcasts-app
# episode row. Left alone, the row would inherit the GENERIC online-* pair and render an
# "Add to Listen Later" that silently rejects — a dead button. An EMPTY per-app category
# suppresses that fallback (the 0.1.52 rule), which is exactly how every unsupported radio
# command is already handled: we don't show an Add we can't honour.
# Pinned at EVERY tier explicitly, and not left to whatever version an earlier section
# happened to set: the three tiers deliver by different halves, so one passing says nothing
# about the others. Tier 0 (no register API) and tier 1 (6.4.6/6.4.7 — registers positives
# but mis-handles the empty call) both go through the FILE; tier 2 is asserted separately
# below because _writeMaterialActions returns early there.
for my $t ( [ 'tier 0', undef, 0 ], [ 'tier 1', '6.4.7', 1 ] ) {
    my ($name, $ver, $wantApi) = @$t;
    reset_all();
    $wantApi ? install_api() : remove_api();
    set_material_version($ver) if defined $ver;
    Plugins::ListenLater::Plugin::_writeMaterialActions();
    my $pod = read_file();
    is("$name: podcasts-album is written, and EMPTY",
       (exists $pod->{'podcasts-album'} ? scalar @{ $pod->{'podcasts-album'} } : 'MISSING'), 0);
    is("$name: ...and podcasts-track too",
       (exists $pod->{'podcasts-track'} ? scalar @{ $pod->{'podcasts-track'} } : 'MISSING'), 0);
    is("$name: ...while the generic online-album pair stays populated for everything else",
       scalar @{ $pod->{'online-album'} // [] }, 2);
}
# Tier 0 above removed the register API and tier 1 pinned a version; restore BOTH, or the
# sections that follow silently run at the wrong tier. The suite has no getPluginVersion
# stub by default (see the note at the top), so undef is the correct restore.
install_api();
set_material_version(undef);

# TIER 2 delivers suppressors by REGISTRATION, not through the file — _writeMaterialActions
# returns early there — so the tier 0/1 assertions above prove nothing about it. The same
# suppression has to arrive by the other half, or a 6.4.8+ user gets the dead Add button
# that the file half prevents for everyone else.
reset_all();
install_api();
set_material_version('6.4.9');
Plugins::ListenLater::Plugin::_registerMaterialActions();
my %emptied = map { $_ => 1 } registered_empties();
is('tier 2: podcasts-album is registered as an EMPTY section',
   ($emptied{'podcasts-album'} ? 'suppressed' : 'MISSING'), 'suppressed');
is('...and podcasts-track too',
   ($emptied{'podcasts-track'} ? 'suppressed' : 'MISSING'), 'suppressed');
is('...and it is a SUPPRESSOR, never a real Add entry',
   (scalar grep { $_->[0] =~ /^podcasts-/ } registered_actions()), 0);

# Leave the tier and the registration state exactly as this section found them.
reset_all();
install_api();
set_material_version(undef);

section('the FILE-ONLY podcasts-* override leaves no husk when the pref goes OFF');
# podcasts-album/-track are ours and file-only, so the strip pass empties them — but they are
# per-app "<command>-<type>" categories, and an EMPTY one of those SUPPRESSES the online-*
# fallback (the 0.1.52 rule). The delete-empties pass names the categories it may remove, and
# the list it was checked against (%ourCats + _radioSuppressorCats, whose podcast entry is
# TuneIn's singular 'podcast') did not include them — so turning the pref off left
# {"podcasts-album":[],"podcasts-track":[]} behind, hiding Add on every Podcasts-app row for
# good. Nothing cleans it later: the pref-ON write pass that would is the one the pref being
# off stops from running.

# 0.1.136: THIS BUILD NEVER WRITES THE PAIR — the built-in Podcasts-app path was removed.
# That makes the husk question SHARPER, not moot: what an EARLIER build wrote is still on
# disk, and an empty per-app category SUPPRESSES the online-* fallback, so a leftover would
# hide "Add" on every Podcasts-app row for good with no code left to rewrite it. So the
# husk is seeded here directly — as a previous release left it — rather than produced by a
# write pass that no longer exists. This is the single most likely way the removal bites.
reset_all();
install_api();
seed_husk('podcasts-album', 'podcasts-track');
is('an OLD build\'s populated override is on disk to begin with',
    scalar @{ read_file()->{'podcasts-album'} // [] }, 1);
is('...and this build does NOT write it',
    (do { Plugins::ListenLater::Plugin::_writeMaterialActions();
          scalar @{ read_file()->{'podcasts-album'} // [] } }), 0);
Plugins::ListenLater::Plugin::_clearMaterialActions();
is('the clear pass deletes it outright, husk and all',
    join(',', map { (exists read_file()->{$_} ? 'y' : 'n') } qw(podcasts-album podcasts-track)),
    'n,n');

# The same clear, but with every feed unsubscribed first — _materialActionSet stopped emitting
# podcasts-* the moment the built-in path had no subscribed feed, so a list read from IT would
# no longer name them and the husks would survive. Since 0.1.136 removed that path %fileOnly
# never names the pair in ANY state, which only sharpens the point. This is why the clear pass
# hardcodes the pair.
reset_all();
install_api();
seed_husk('podcasts-album', 'podcasts-track');
Slim::Utils::Prefs::set_test_pref_ns('plugin.podcast', 'feeds', []);
Plugins::ListenLater::Plugin::_clearMaterialActions();
is('...even for a user who has unsubscribed from everything',
    join(',', map { (exists read_file()->{$_} ? 'y' : 'n') } qw(podcasts-album podcasts-track)),
    'n,n');

# With registrations still live it is the OPPOSITE: the online-* pair cannot be withdrawn, so
# the emptied override is the only thing keeping "Add" off Podcasts rows until the restart —
# exactly the argument that keeps the radio empties. Kept when present, RE-CREATED when the
# file is gone.
reset_all();
install_api();
Slim::Utils::Prefs::set_test_pref_ns('plugin.podcast', 'feeds',
    [ { name => 'Darko.Audio', value => 'https://darko.audio/feed' } ]);
Plugins::ListenLater::Plugin::_registerMaterialActions();
Plugins::ListenLater::Plugin::_writeMaterialActions();
Plugins::ListenLater::Plugin::_clearMaterialActions();
is('while entries are live the override STAYS',
    join(',', map { (exists read_file()->{$_} ? 'y' : 'n') } qw(podcasts-album podcasts-track)),
    'y,y');
is('...and is EMPTY, so it suppresses rather than offers',
    join(',', map { scalar @{ read_file()->{$_} // [] } } qw(podcasts-album podcasts-track)),
    '0,0');
unlink actions_file();
Plugins::ListenLater::Plugin::_clearMaterialActions();
is('...and is re-created when the file has gone',
    join(',', map { (exists read_file()->{$_} ? 'y' : 'n') } qw(podcasts-album podcasts-track)),
    'y,y');
Slim::Utils::Prefs::set_test_pref_ns('plugin.podcast', 'feeds', []);

# ---------------------------------------------------------------------------
section('the diagnostic shadow scan reports FOREIGN categories only (0.1.101)');
# _dumpMaterialState flags a POPULATED "<svc>-album/-track" because such a category shadows
# online-* and hides Add on that one service. Three of our own populated categories —
# album-track, playlist-track, queue-track — are not "<service>-<type>" shaped at all, so the
# old prefix-based exemption listed them as foreign and pointed remote triage at the plugin's
# own entries. Exemption is now by FULL category name, taken from _materialActionSet.
sub shadow_line {
    my ($line) = grep { /shadow/i }
        split /\n/, ($Slim::Utils::Prefs::VALUES{material_debug_snapshot} // '');
    return $line // '(no shadow line in the snapshot)';
}
Slim::Utils::Prefs::set_test_pref('debug_log', 1);

reset_all();
install_api();
Plugins::ListenLater::Plugin::_registerMaterialActions();
Plugins::ListenLater::Plugin::_writeMaterialActions();
is('API path: a clean install reports NOTHING as shadowing',
    (shadow_line() =~ /^no non-empty per-service shadow/) ? 'clean' : shadow_line(), 'clean');

reset_all();
remove_api();
Plugins::ListenLater::Plugin::_writeMaterialActions();   # legacy: every category in the file
is('legacy path: our own album-track/playlist-track/queue-track are not "foreign"',
    (shadow_line() =~ /^no non-empty per-service shadow/) ? 'clean' : shadow_line(), 'clean');

# The positive control — the scan still has to catch the thing it exists for.
{
    my $data = read_file();
    $data->{'tidal-album'} = [ { title => 'Theirs', lmscommand => [ 'otherplugin', 'go' ] } ];
    open my $out, '>:raw', actions_file() or die $!;
    print $out $JSON->encode($data);
    close $out;
}
Plugins::ListenLater::Plugin::_writeMaterialActions();
is('...but a populated FOREIGN per-service category is still reported',
    (shadow_line() =~ /SHADOW online-\*.*\btidal-album\(1\)/) ? 'reported' : shadow_line(),
    'reported');
Slim::Utils::Prefs::set_test_pref('debug_log', 0);

# ---------------------------------------------------------------------------
section('a FAILED write must not record the ownership ledger (0.1.105)');
# _ownedCats hands back its generous one-time SEED only while material_owned_cats is unset:
#
#     my $l = $prefs->get('material_owned_cats');
#     return { map { $_ => 1 } @$l } if ref $l eq 'ARRAY';   # <- set: the seed is gone
#
# so setting the ledger at all retires the seed permanently. _writeMaterialActionsFile has four
# die paths (open/print/close/rename) and BOTH callers wrap it in `eval { ...; 1 }`, so a full
# disk or an unwritable prefs dir is swallowed and the plugin carries on. Recording the ledger
# BEFORE that write therefore had a permanent failure mode: the ledger claims categories the
# file never received, the seed is retired, and a pre-ledger husk — an empty '<svc>-album' left
# by 0.1.47-0.1.50 — is then in NEITHER %emptied (it arrives empty) NOR %owned. The
# delete-empties pass skips it forever and "Add" stays hidden on that service, unrecoverable
# without hand-editing the shared file. That is the 0.1.51 regression, so the ordering is
# load-bearing and pinned here: record only after the write returns.
reset_all();
remove_api();
delete $Slim::Utils::Prefs::VALUES{material_owned_cats};   # pre-ledger install: seed applies

# The husk 0.1.47-0.1.50 left behind. Deezer is in %SUPPORTED_CMD, so it is not a radio
# suppressor and not in %keep — the seed is the only thing that can ever sweep it.
File::Path::make_path("$tmp/material-skin");
{
    open my $out, '>:raw', actions_file() or die $!;
    print $out $JSON->encode({ 'deezer-album' => [] });
    close $out;
}

my $died = 0;
{
    no warnings 'redefine';
    local *Plugins::ListenLater::Plugin::_writeMaterialActionsFile = sub { die "disk full\n" };
    $died = 1 unless eval { Plugins::ListenLater::Plugin::_writeMaterialActions(); 1 };
}
is('the write really did fail', $died, 1);
is('...so the ledger was NOT recorded (the seed survives)',
    (ref $Slim::Utils::Prefs::VALUES{material_owned_cats} eq 'ARRAY') ? 'recorded' : 'unset',
    'unset');
is('...and the husk is still in the file, untouched',
    (ref read_file()->{'deezer-album'} eq 'ARRAY') ? 'present' : 'gone', 'present');

# The next write succeeds, and because the seed is intact it sweeps the husk it was there for.
Plugins::ListenLater::Plugin::_writeMaterialActions();
is('the next successful write sweeps the pre-ledger husk',
    (exists read_file()->{'deezer-album'}) ? 'survived' : 'swept', 'swept');
is('...and NOW the ledger is recorded',
    (ref $Slim::Utils::Prefs::VALUES{material_owned_cats} eq 'ARRAY') ? 'recorded' : 'unset',
    'recorded');

# The same ordering on the CLEAR path (_clearMaterialActions): its ledger write is held behind
# the file write too, so a failed clear leaves the seed in place for the next attempt.
reset_all();
delete $Slim::Utils::Prefs::VALUES{material_owned_cats};
$Plugins::ListenLater::Plugin::REGISTERED_N = 1;          # $live: the re-assert branch runs
{
    no warnings 'redefine';
    local *Plugins::ListenLater::Plugin::_writeMaterialActionsFile = sub { die "disk full\n" };
    eval { Plugins::ListenLater::Plugin::_clearMaterialActions(); 1 };
}
is('clear path: a failed write leaves the seed intact too',
    (ref $Slim::Utils::Prefs::VALUES{material_owned_cats} eq 'ARRAY') ? 'recorded' : 'unset',
    'unset');

# ---------------------------------------------------------------------------
section('UNINSTALL: shutdownPlugin clears the file on the way out (0.1.108)');
# The residue this suite's whole subject matter creates had no owner once the plugin was
# removed: LMS deletes our directory and nothing of ours ever runs again, so the "Add"
# entries stayed in every Material menu for ever and the only remedy was editing JSON by
# hand. Slim::Utils::PluginManager sets plugin.state to needs-uninstall/needs-disable when
# the user clicks Apply and removes us at the NEXT start, so shutdownPlugin is the last
# moment we can still tidy.
my $STATE_NS = 'plugin.state';
# The plugin's SHORT name, because that is the key Slim::Utils::PluginManager actually uses
# — NOT the module name. This fixture used to say 'Plugins::ListenLater::Plugin', matching
# the wrong key shutdownPlugin read, so all six assertions below passed against a branch
# that could never run on a real server: the stub carried the bug (0.1.126). Verified live
# over jsonrpc.js 2026-09-04 — plugin.state:ListenLater => "enabled", while the module-name
# key answers null. ANTI-TEST: put the module name back and these six go red.
my $ME       = 'ListenLater';
sub set_state { Slim::Utils::Prefs::set_test_pref_ns($STATE_NS, $ME, $_[0]) }
# Everything the departing clean must remove, in one list: our own view suppressors, a radio
# one, and the file-only podcasts override.
my @MUST_GO = qw(listenlater-album LLHome-album music-album podcasts-album);
sub survivors { my ($d) = @_; return join(',', grep { exists $d->{$_} } @MUST_GO) }

reset_all();
install_api();
set_state('enabled');
Plugins::ListenLater::Plugin::_registerMaterialActions();
Plugins::ListenLater::Plugin::_writeMaterialActions();
Plugins::ListenLater::Plugin->shutdownPlugin();
is('a NORMAL shutdown changes nothing', ours_in_file(read_file()), $FILEHALF);
is('...and leaves the suppressors in place', (survivors(read_file()) ? 'kept' : 'gone'), 'kept');

# The anti-test for the $departing flag, and the reason it had to exist. With registrations
# live, a plain clear KEEPS the empties on purpose — they are all that stops the still-live
# registered online-* pair showing "Add" inside our own list until the restart. On an
# uninstall that reasoning inverts: there is no next run to protect, so keeping them strands
# them for ever, suppressing another plugin's online-* on podcasts and every radio command.
reset_all();
install_api();
set_state('enabled');
Plugins::ListenLater::Plugin::_registerMaterialActions();
Plugins::ListenLater::Plugin::_writeMaterialActions();
Plugins::ListenLater::Plugin::_clearMaterialActions();          # no $departing
is('registrations live: a plain clear keeps the suppressors',
    survivors(read_file()), join(',', @MUST_GO));

reset_all();
install_api();
set_state('needs-uninstall');
Plugins::ListenLater::Plugin::_registerMaterialActions();
Plugins::ListenLater::Plugin::_writeMaterialActions();
is('something of ours is in the file to begin with',
    (ours_in_file(read_file()) > 0 ? 'yes' : 'no'), 'yes');
Plugins::ListenLater::Plugin->shutdownPlugin();
my $gone = read_file();
is('needs-uninstall: no entry of ours survives', ours_in_file($gone), 0);
is('...nor any suppressor category we own',      survivors($gone), '');
is('...and the ownership ledger is forgotten',
    scalar @{ $Slim::Utils::Prefs::VALUES{material_owned_cats} // [] }, 0);

# A third party sharing the file must come through an uninstall untouched — this pass runs
# with no user present to notice, so it is the least recoverable place to get it wrong.
reset_all();
install_api();
set_state('needs-uninstall');
File::Path::make_path("$tmp/material-skin");
open my $ufh, '>:raw', actions_file() or die $!;
print $ufh $JSON->encode({
    'album'       => [ { title => 'Someone else',   lmscommand => [ 'otherplugin', 'go' ] } ],
    'qobuz-album' => [ { title => 'Their scoping',  lmscommand => [ 'otherplugin', 'go' ] } ],
    'tunein-album' => [],   # somebody else's deliberate empty suppressor
});
close $ufh;
Plugins::ListenLater::Plugin::_registerMaterialActions();
Plugins::ListenLater::Plugin::_writeMaterialActions();
Plugins::ListenLater::Plugin->shutdownPlugin();
my $left = read_file();
is('a third party entry survives the uninstall', scalar @{ $left->{'album'} // [] }, 1);
is('...and is theirs',                           $left->{'album'}[0]{title}, 'Someone else');
is('their populated per-command category survives',
    scalar @{ $left->{'qobuz-album'} // [] }, 1);
is('and nothing of ours is left beside it',      ours_in_file($left), 0);

# Disabling is the same promise: the user asked for the entries to go, and postinit's
# pref-off branch cannot help because we will not be loaded to run it.
reset_all();
install_api();
set_state('needs-disable');
Plugins::ListenLater::Plugin::_registerMaterialActions();
Plugins::ListenLater::Plugin::_writeMaterialActions();
Plugins::ListenLater::Plugin->shutdownPlugin();
is('needs-disable clears too', ours_in_file(read_file()), 0);

# The legacy path has no registrations at all, so the file is the ONLY place the entries
# live — an uninstall that missed this would strand the complete set, not just the file half.
reset_all();
remove_api();
set_state('needs-uninstall');
Plugins::ListenLater::Plugin::_writeMaterialActions();
is('older Material: the full set is in the file',
    (ours_in_file(read_file()) >= $TOTAL ? 'yes' : 'no'), 'yes');
Plugins::ListenLater::Plugin->shutdownPlugin();
is('...and the uninstall takes all of it', ours_in_file(read_file()), 0);
install_api();

# ---------------------------------------------------------------------------
section('UNTICKING the box actually sticks across a restart (0.1.108)');
# THE REPORTED BUG, and the reason it survived three versions of wrong diagnosis: an unticked
# checkbox posts NOTHING, so save_settings() above — which passes an explicit 0 — was never
# the real form. The real one omits the key entirely.
#
# Chain: Slim::Web::Settings::handler sets every pref in prefs() unconditionally from
# $params->{pref_*}, so an absent key writes undef over the 0 the plugin just set; then
# Prefs::Base::init re-seeds any pref that "exists as an undef value" back to its default at
# the next module load. Net effect: the box came back TICKED on every restart, and because
# material_action was stuck on, postinitPlugin never took the branch that clears actions.json.
sub untick { # what the browser actually posts: the key is simply not there
    Slim::Utils::Log::clear();
    Plugins::ListenLater::Settings->handler(undef, { saveSettings => 1, pref_sort => 'added' });
}
# A restart: Plugin.pm's $prefs->init runs again at module load with the same defaults.
sub restart_init {
    Slim::Utils::Prefs::preferences('plugin.listenlater')
        ->init({ material_action => 1, debug_log => 0, watch_outside => 1, sort => 'added' });
}

reset_all();
install_api();
Slim::Utils::Prefs::preferences('plugin.listenlater')->set('material_action', 1);
untick();
is('the pref is 0 right after the save',
    (Slim::Utils::Prefs::preferences('plugin.listenlater')->get('material_action') ? 1 : 0), 0);
is('...and is a real 0, NOT undef (undef is what init re-seeds)',
    (defined Slim::Utils::Prefs::preferences('plugin.listenlater')->get('material_action')
        ? 'defined' : 'undef'), 'defined');
restart_init();
is('...and it is STILL off after a restart',
    (Slim::Utils::Prefs::preferences('plugin.listenlater')->get('material_action') ? 1 : 0), 0);
restart_init();
is('...and after another one',
    (Slim::Utils::Prefs::preferences('plugin.listenlater')->get('material_action') ? 1 : 0), 0);

# The same for the other checkboxes on that page — one bug, THREE fields. watch_outside was
# missed by the 0.1.108 fix: same prefs() list, same default of 1, same absent-key post.
Slim::Utils::Prefs::preferences('plugin.listenlater')->set('debug_log', 1);
untick();
restart_init();
is('debug_log unticks and stays unticked too',
    (Slim::Utils::Prefs::preferences('plugin.listenlater')->get('debug_log') ? 1 : 0), 0);

Slim::Utils::Prefs::preferences('plugin.listenlater')->set('watch_outside', 1);
untick();
is('watch_outside is a real 0 right after the save, not undef',
    (defined Slim::Utils::Prefs::preferences('plugin.listenlater')->get('watch_outside')
        ? 'defined' : 'undef'), 'defined');
restart_init();
is('watch_outside unticks and stays unticked across a restart',
    (Slim::Utils::Prefs::preferences('plugin.listenlater')->get('watch_outside') ? 1 : 0), 0);
Slim::Utils::Log::clear();
Plugins::ListenLater::Settings->handler(undef, {
    saveSettings => 1, pref_sort => 'added', pref_watch_outside => 1,
});
restart_init();
is('...and ticking watch_outside still turns it back ON',
    Slim::Utils::Prefs::preferences('plugin.listenlater')->get('watch_outside'), 1);

# Ticking must still work, or the fix has just broken the box the other way.
Slim::Utils::Log::clear();
Plugins::ListenLater::Settings->handler(undef, {
    saveSettings => 1, pref_sort => 'added', pref_material_action => 1,
});
restart_init();
is('ticking it still turns it ON, and that survives a restart',
    Slim::Utils::Prefs::preferences('plugin.listenlater')->get('material_action'), 1);

# And the consequence the user actually saw: with the pref stuck ON, postinit took the write
# branch every time and the entries could never be cleared. Off and staying off, the clear
# branch is reachable.
Slim::Utils::Prefs::preferences('plugin.listenlater')->set('material_action', 1);
reset_all();
install_api();
Plugins::ListenLater::Plugin::_registerMaterialActions();
Plugins::ListenLater::Plugin::_writeMaterialActions();
untick();
restart_init();
is('so a restart after unticking reaches the CLEAR branch',
    (Slim::Utils::Prefs::preferences('plugin.listenlater')->get('material_action') ? 'write' : 'clear'),
    'clear');
Slim::Utils::Prefs::preferences('plugin.listenlater')->set('material_action', 1);

# ---------------------------------------------------------------------------
section('tier 1 — the deferred pass gained a register call, and it must be INERT here');

# 0.1.110 made _writeMaterialActionsDeferred register as well as write, because on tier 2 the
# radio suppressors it discovers late have to be REGISTERED. On 6.4.6/6.4.7 that call must do
# nothing at all: the positives are latched, and the empty-section loop is gated on tier 2 —
# where it would push a NULL into the section and break every custom action in it. This is the
# one code path 0.1.110 changes for an install that is NOT yet on 6.4.8, so it is pinned here.
reset_all();
install_api();
set_material_version('6.4.7');
Plugins::ListenLater::Plugin::_registerMaterialActions();
Plugins::ListenLater::Plugin::_writeMaterialActions();
my $t1before = read_file();
my $t1reg    = n_actions();

$Slim::Control::Request::RESULTS{radios} = [ { cmd => 'bbcsounds' } ];
Plugins::ListenLater::Plugin::_writeMaterialActionsDeferred();
delete $Slim::Control::Request::RESULTS{radios};
my $t1after = read_file();

is('the deferred pass registers no further entries on 6.4.7', n_actions(), $t1reg);
is('...and NO empty section (that would push a null and break the menu)', n_empties(), 0);
is('...it still writes the late-discovered radio suppressor to the FILE, as before',
    (exists $t1after->{'bbcsounds-album'} ? 'written' : 'missed'), 'written');
is('...and changes nothing else about the file',
    $JSON->encode({ map { $_ => $t1after->{$_} }
                    grep { !/^bbcsounds-/ } keys %$t1after }),
    $JSON->encode($t1before));
is('...leaving our entries in the file exactly once', ours_in_file($t1after), $FILEHALF);
set_material_version(undef);

# ===========================================================================
# TIER 2 — Material >= 6.4.8 (upstream PR #1257). 0.1.110.
#
# #1257 closed all three gaps that forced the file half, so everything registers and the file
# is PRUNED rather than written. Two properties carry the whole release and are what most of
# this section is about:
#   * the prune must be SURGICAL. actions.json is shared, LL has always MERGED into it rather
#     than overwriting it, so a hand-written one has coexisted with ours the whole time and
#     cannot be assumed absent.
#   * the file is UNLINKED when the prune empties it — but only then.
# ===========================================================================
section('the delivery tier — capability AND version, because 6.4.6/6.4.7 mis-handle the empty call');

reset_all();
remove_api();
set_material_version('6.4.9');
is('no registerCustomAction is tier 0, whatever the version says',
    Plugins::ListenLater::Plugin::_actionTier(), 0);

install_api();
set_material_version(undef);
is('API present but the version unreadable falls back to tier 1 (the safe API tier)',
    Plugins::ListenLater::Plugin::_actionTier(), 1);
# The SUFFIXED rows are the ones a reviewer trips over, and 6.4.7-beta1 is the case that
# matters: materialAtLeast's regex is UNANCHORED at the end, so the leading triple still
# parses and a real 6.4.7 stays on tier 1 no matter what trails it. Only a string that does
# not START N.N.N reaches the dev-build branch below. Without this row, "every 6.4.6/6.4.7
# is safe" rests on the bare-version rows alone — and the one-arg registerCustomAction($section)
# that tier 2 unlocks is FATAL on those builds: it pushes undef and takes out every plugin's
# custom actions in that section, not just ours. Raised as a finding and withdrawn on these
# rows (Review Ledger A2, ninth round).
for my $c (['6.4.5', 1], ['6.4.6', 1], ['6.4.7', 1], ['6.4.8', 2], ['6.4.9', 2],
           ['6.5.0', 2], ['7.0.0', 2], ['6.4.10', 2],
           ['6.4.7-beta1', 1], ['6.4.6.1', 1], ['6.4.8-rc2', 2]) {
    set_material_version($c->[0]);
    is("Material $c->[0] is tier $c->[1]", Plugins::ListenLater::Plugin::_actionTier(), $c->[1]);
}
set_material_version('DEVELOPMENT');
is('a dev/test build is treated as newest, like Browse::_headerType',
    Plugins::ListenLater::Plugin::_actionTier(), 2);

# ---------------------------------------------------------------------------
section('tier 2 — the action set folds, and the suppressors become registrable');

set_material_version('6.4.9');
my ($t2pos, $t2file, $t2empty) = Plugins::ListenLater::Plugin::_materialActionSet(2);
is('the client-resolved surfaces move OUT of the file half (PR #1257 re-emits)',
    join(',', sort keys %$t2file), '');
is('...and into the registered set, alongside the six that were always there',
    join(',', sort keys %$t2pos),
    'album,album-track,online-album,online-track,playlist,playlist-track,queue-track,track');
is('the own-surface suppressors are now declarable as EMPTY sections',
    join(',', @$t2empty),
    'listenlater-album,listenlater-track,listenlater-artist,'
    . 'LLHome-album,LLHome-track,LLHome-artist');
is('nothing is in both halves (that would double every Add)',
    join(',', grep { exists $t2pos->{$_} } sort keys %$t2file), '');
# The entries themselves must not have been respelled on the way across.
is('a folded entry is the SAME action the file half carried at tier 1',
    $JSON->encode($t2pos->{'track'}), $JSON->encode($FILEONLY->{'track'}));

my $T2TOTAL = 0; $T2TOTAL += scalar @{ $t2pos->{$_} } for keys %$t2pos;
is('...so the registered total is the old registered set plus the old file set',
    $T2TOTAL, $TOTAL + $FILEHALF);

# ---------------------------------------------------------------------------
section('tier 2 — upgrading an install whose entries are in the file');

reset_all();
remove_api();
set_material_version(undef);
Plugins::ListenLater::Plugin::_writeMaterialActions();     # a 0.1.109 install, as upgraded from
my $pre = read_file();
is('the pre-upgrade file has all our entries', ours_in_file($pre), $TOTAL + $FILEHALF);
is('...and its suppressor categories', (exists $pre->{'listenlater-album'} ? 'yes' : 'no'), 'yes');

install_api();
set_material_version('6.4.9');
my $n2 = Plugins::ListenLater::Plugin::_registerMaterialActions();
Plugins::ListenLater::Plugin::_writeMaterialActions();

is('every entry registered, the folded ones included',
    n_actions(), $T2TOTAL);
is('...and the empty suppressors registered as sections',
    (grep { $_ eq 'listenlater-album' } registered_empties()) ? 'yes' : 'no', 'yes');
is('...radio suppressors too — they are per-app overrides like the rest',
    (grep { $_ eq 'music-album' } registered_empties()) ? 'yes' : 'no', 'yes');
is('an empty section is registered with ONE argument (two would push a null entry)',
    (grep { @$_ != 1 } grep { $_->[0] eq 'listenlater-album' } @REG) ? 'two args' : 'one arg',
    'one arg');
is('the return counts entries and sections together', $n2,
    $T2TOTAL + n_empties());
is('THE FILE IS GONE — nothing of ours is left on the user\'s machine',
    (-e actions_file() ? 'still there' : 'removed'), 'removed');
is('...and the ownership ledger is cleared with it',
    scalar @{ Slim::Utils::Prefs::preferences('plugin.listenlater')->get('material_owned_cats') || [] },
    0);

# The steady state: this runs at every startup for ever, so it must be free and must not
# resurrect the file.
Plugins::ListenLater::Plugin::_writeMaterialActions();
Plugins::ListenLater::Plugin::_writeMaterialActions();
is('re-running the prune on an absent file does not recreate it',
    (-e actions_file() ? 'recreated' : 'still absent'), 'still absent');
is('...and registers nothing more', n_actions(), $T2TOTAL);

# ---------------------------------------------------------------------------
section("tier 2 — a hand-written actions.json survives the prune intact");

reset_all();
install_api();
set_material_version('6.4.9');
File::Path::make_path("$tmp/material-skin");
# A third party's populated category, their own deliberate EMPTY suppressor, and — the case
# the title fallback used to break — an entry of theirs TITLED like ours, with no lmscommand.
my $foreign = {
    'album'            => [ { title => 'Their Thing', command => ['their', 'cmd'] } ],
    'otherplugin-album'=> [],
    'online-album'     => [ { title => 'Add to Listen Later', script => 'theirs.js' } ],
};
open my $ffh, '>:raw', actions_file() or die $!;
print $ffh $JSON->encode($foreign); close $ffh;

Plugins::ListenLater::Plugin::_registerMaterialActions();
Plugins::ListenLater::Plugin::_writeMaterialActions();
my $after = read_file();
is('the file is KEPT — someone else has entries in it',
    (-e actions_file() ? 'kept' : 'deleted'), 'kept');
is("their populated category survives verbatim",
    $JSON->encode($after->{'album'}), $JSON->encode($foreign->{'album'}));
is('their deliberate empty suppressor survives — an empty category is not litter',
    (exists $after->{'otherplugin-album'} ? 'kept' : 'deleted'), 'kept');
is('an entry TITLED like ours but not ours is left alone (no title guessing, 0.1.110)',
    $JSON->encode($after->{'online-album'}), $JSON->encode($foreign->{'online-album'}));
is('...and _isOurAction agrees, on its own',
    Plugins::ListenLater::Plugin::_isOurAction($foreign->{'online-album'}[0]), 0);
is('nothing of OURS is in the file', ours_in_file($after), 0);

# ---------------------------------------------------------------------------
section('tier 2 — a RETIRED NAME is swept, and the log names the one class that may not be ours');
# favorites-album/-track sit on the retired-name list because 0.1.85 shipped them. An empty one
# is indistinguishable from another plugin's deliberate suppressor — there is nothing in an
# empty array to say who wrote it — and it is swept anyway, on the reasoning in the Review
# Ledger: leaving a husk of OURS in place hides "Add" on that command for good (the 0.1.51
# class), and no released build has run this sweep yet (`main` is 0.1.93). The accepted cost is
# that an identically-named empty of THEIRS goes with it. What is pinned here is that the cost
# is now VISIBLE, which until 0.1.141 it was not: the prune reported how many sections it KEPT
# and never which it removed. Behaviour is unchanged by this section — the deletions were
# already happening, silently.
#
# ANTI-TESTS, measured: drop favorites-* from %legacyName in Plugin.pm and 4 go red (the sweep
# stops, and both log assertions go with it); silence the retired-name warn alone and 2 go red,
# which is what separates "we still delete it" from "we now say that we did".
reset_all();
install_api();
set_material_version('6.4.9');
File::Path::make_path("$tmp/material-skin");
{
    my $mixed = {
        # A retired spelling of ours. Also exactly what a third party would write to hide
        # their own Add on Favourites rows.
        'favorites-album'   => [],
        # A name no Listen Later build has ever asserted: the control, and the thing that
        # stops this passing against a prune that simply deletes every empty category.
        'otherplugin-album' => [],
        # Ours, POPULATED — so the strip pass empties it and it is deleted with provenance,
        # not by name. The other control: it must be reported as removed, and must NOT be
        # named as a retired-name claim.
        'online-album'      => [ { title => 'Add to Listen Later',
                                   lmscommand => [ 'listenlater', 'addctx', 'kind:album' ] } ],
        # Someone else's populated category, so the file survives to be read back.
        'album'             => [ { title => 'Their Thing', command => [ 'their', 'cmd' ] } ],
    };
    open my $mfh, '>:raw', actions_file() or die $!;
    print $mfh $JSON->encode($mixed); close $mfh;

    Slim::Utils::Log::clear();
    Plugins::ListenLater::Plugin::_registerMaterialActions();
    Plugins::ListenLater::Plugin::_writeMaterialActions();
    my $left = read_file();
    my @log  = Slim::Utils::Log::lines();
    my ($removedLine) = grep { /removed \d+ empty categor/ } @log;
    my ($retiredLine) = grep { /RETIRED NAME alone/ } @log;

    is('a retired name of ours is swept even though it arrived empty',
       (exists $left->{'favorites-album'} ? 'kept' : 'removed'), 'removed');
    is('...while a name no build of ours ever wrote is left alone',
       (exists $left->{'otherplugin-album'} ? 'kept' : 'removed'), 'kept');
    is('the removal is NAMED in the log, not just counted',
       ((($removedLine // '') =~ /favorites-album/) ? 'named' : 'unnamed'), 'named');
    is('...and the retired-name claim is called out separately',
       ((($retiredLine // '') =~ /favorites-album/) ? 'flagged' : 'not flagged'), 'flagged');
    is('...telling the user another plugin\'s suppression may have gone with it',
       ((($retiredLine // '') =~ /another plugin/) ? 'explained' : 'bare'), 'explained');
    # The two halves of the distinction, which is the whole point of the second line.
    is('a category WE emptied is reported as removed',
       ((($removedLine // '') =~ /online-album/) ? 'named' : 'unnamed'), 'named');
    is('...but is NOT claimed as a retired name — we have provenance for that one',
       ((($retiredLine // '') =~ /online-album/) ? 'wrongly flagged' : 'not flagged'),
       'not flagged');
    is('...and the control name is in neither line',
       ((join('', $removedLine // '', $retiredLine // '') =~ /otherplugin/) ? 'named' : 'absent'),
       'absent');
    is('their populated category is still untouched',
       $JSON->encode($left->{'album'}), $JSON->encode([ { title => 'Their Thing',
                                                          command => [ 'their', 'cmd' ] } ]));
}

# ---------------------------------------------------------------------------
section('tier 2 — a refused registration still reaches the user, via the file');

reset_all();
install_failing_api(sub { $_[0] eq 'online-album' });
set_material_version('6.4.9');
Plugins::ListenLater::Plugin::_registerMaterialActions();
Plugins::ListenLater::Plugin::_writeMaterialActions();
my $part = read_file();
is('the refused section is written to the file instead of being lost',
    scalar @{ $part->{'online-album'} // [] }, 2);
is('...and the file is kept alive for it',
    (-e actions_file() ? 'kept' : 'deleted'), 'kept');
is('nothing Material DID take is also in the file (that would double it)',
    ours_in_file($part) - 2, 0);

# The same, for an empty section — the failure that silently un-suppresses our own rows.
reset_all();
install_failing_api(sub { $_[0] eq 'listenlater-album' });
set_material_version('6.4.9');
Plugins::ListenLater::Plugin::_registerMaterialActions();
Plugins::ListenLater::Plugin::_writeMaterialActions();
my $sup = read_file();
is('a suppressor Material refused STAYS in the file, or "Add" reappears on our own rows',
    (exists $sup->{'listenlater-album'} ? 'kept' : 'gone'), 'kept');
is('...and stays EMPTY, which is what does the suppressing',
    scalar @{ $sup->{'listenlater-album'} // [] }, 0);
is('the ones that DID register are not also left in the file',
    (exists $sup->{'listenlater-track'} ? 'both' : 'registered only'), 'registered only');

# EVERY registration refused. One dead $register coderef takes the positives AND the empty
# sections with it, and that combination is the hole the $REGISTERED_N gate used to leave: the
# prune wrote our online-* pair back to the file (correctly — they exist nowhere else) while
# writing NO suppressor, because it asked "did anything REGISTER" rather than "is anything of
# ours live". "Add to Listen Later" then rendered on our own list, Played and Wish List rows —
# and on a Played row, using it bounces the album back to Listen Later.
reset_all();
install_failing_api(sub { 1 });
set_material_version('6.4.9');
Plugins::ListenLater::Plugin::_registerMaterialActions();
Plugins::ListenLater::Plugin::_writeMaterialActions();
my $all_refused = read_file();
my ($a_radio)   = sort( Plugins::ListenLater::Plugin::_radioSuppressorCats() );
is('nothing registered at all', n_actions() + n_empties(), 0);
is('so every positive falls back to the file',
    scalar @{ $all_refused->{'online-album'} // [] }, 2);
is('...and our own list suppressor is written BESIDE them',
    (exists $all_refused->{'listenlater-album'} ? 'kept' : 'MISSING — Add is back on our rows'),
    'kept');
is('...as is the home shelf one',
    (exists $all_refused->{'LLHome-album'} ? 'kept' : 'MISSING — Add is back on the shelf'),
    'kept');
is("...as are the radio browse ones ($a_radio)",
    (exists $all_refused->{$a_radio} ? 'kept' : 'MISSING — Add is back on radio rows'), 'kept');
is('...and they are EMPTY, which is what does the suppressing',
    scalar @{ $all_refused->{'listenlater-album'} // [] }, 0);

# TURNING THE PREF OFF withdraws the half that CAN be withdrawn. The registrations are stuck
# until the restart (Material has no unregister), but a file entry is not — and tier 0/1's
# clear path deletes exactly these, immediately. The prune used to put them back, because the
# only thing it was told was $departing: the pref going off looked identical to a normal
# startup write, so the file the user had just asked to be rid of got the refused entries
# again. One concept, two answers, in two subs.
reset_all();
install_failing_api(sub { $_[0] eq 'online-album' });
set_material_version('6.4.9');
Plugins::ListenLater::Plugin::_registerMaterialActions();
Plugins::ListenLater::Plugin::_writeMaterialActions();
is('pref ON: the refused entry lives in the file',
    scalar @{ read_file()->{'online-album'} // [] }, 2);
Plugins::ListenLater::Plugin::_clearMaterialActions();
my $pref_off = read_file();
is('pref OFF: the file half is withdrawn, not re-written',
    scalar @{ $pref_off->{'online-album'} // [] }, 0);
is('...and nothing of ours is left in the file at all', ours_in_file($pref_off), 0);
is('...nor a suppressor for entries that are no longer anywhere',
    (exists $pref_off->{'listenlater-album'} ? 'wrote' : 'clean'), 'clean');

# The gate still has to hold the OTHER way: nothing live, nothing written. This is the
# pref-off-at-startup path, and a suppressor left there would hide ANOTHER plugin's online-*
# actions on every radio and podcast row with nothing of ours left to clean it up.
reset_all();
install_api();
set_material_version('6.4.9');
Plugins::ListenLater::Plugin::_writeMaterialActions();     # no registration ever ran
my $untouched = read_file();
is('nothing registered and nothing refused leaves no suppressor behind',
    (exists $untouched->{'listenlater-album'} || exists $untouched->{$a_radio}) ? 'wrote' : 'clean',
    'clean');
is('...and nothing of ours in the file at all', ours_in_file($untouched), 0);

# ---------------------------------------------------------------------------
section('the per-service diagnostic reads BOTH delivery halves');
# The dump's last block is the one a remote "Add has gone" report is actually read from: per
# installed service, will its browse rows show Add. It resolved that from the FILE alone,
# which was complete until 6.4.8 and wrong after it — on tier 2 our own suppressors and the
# podcasts override are REGISTERED and the file is pruned, so the file-only test reported
# "Add shown (via online-*)" for precisely the rows we hold Add off. Material itself reads
# both lists (`(appCat in customActions) || (appCat in pluginCustomActions)`), so the
# diagnostic has to as well — and it has to say WHICH half, since that is the difference
# between "hard-refresh the tab" and "look in actions.json".
sub svc_line {
    my ($cmd) = @_;
    my ($line) = grep { /^service '\Q$cmd\E'/ }
        split /\n/, ($Slim::Utils::Prefs::VALUES{material_debug_snapshot} // '');
    return $line // "(no line for $cmd)";
}
Slim::Utils::Prefs::set_test_pref('debug_log', 1);
Slim::Utils::Prefs::set_test_pref_ns('plugin.podcast', 'feeds', [ { url => 'http://x/f.xml' } ]);
$Slim::Control::Request::RESULTS{apps} = [
    { cmd => 'listenlater', name => 'Listen Later' },
    { cmd => 'podcasts',    name => 'Podcasts' },
    { cmd => 'qobuz',       name => 'Qobuz' },
];
$Slim::Control::Request::RESULTS{radios} = [ { cmd => 'music', name => 'Radio' } ];

reset_all();
install_api();
set_material_version('6.4.9');
Plugins::ListenLater::Plugin::_registerMaterialActions();
Plugins::ListenLater::Plugin::_writeMaterialActions();
is('tier 2: our own list rows report the REGISTERED suppressor',
    (svc_line('listenlater') =~ /Add HIDDEN \(registered empty 'listenlater-album' section\)/)
        ? 'registered' : svc_line('listenlater'), 'registered');
is('tier 2: a radio browse command too',
    (svc_line('music') =~ /Add HIDDEN \(registered empty 'music-album' section\)/)
        ? 'registered' : svc_line('music'), 'registered');
is('tier 2: a plain streaming app still falls through to online-*',
    (svc_line('qobuz') =~ /Add shown \(via online-\*\)/) ? 'online' : svc_line('qobuz'), 'online');

# The same three services on tier 1, where every one of those categories IS the file. Same
# verdicts, different half named.
reset_all();
install_api();
set_material_version('6.4.7');
Plugins::ListenLater::Plugin::_registerMaterialActions();
Plugins::ListenLater::Plugin::_writeMaterialActions();
is('tier 1: our own list rows report the FILE suppressor',
    (svc_line('listenlater') =~ /Add HIDDEN \(empty 'listenlater-album' in actions\.json\)/)
        ? 'file' : svc_line('listenlater'), 'file');
is('tier 1: and online-* still carries the rest',
    (svc_line('qobuz') =~ /Add shown \(via online-\*\)/) ? 'online' : svc_line('qobuz'), 'online');

# A suppressor that reached NEITHER half must read as online-* — the state worth reporting,
# and the one an "intent" list (our @radioCats) used to paper over by claiming a category we
# had not delivered.
reset_all();
install_failing_api(sub { $_[0] =~ /^music-/ });
set_material_version('6.4.9');
Plugins::ListenLater::Plugin::_registerMaterialActions();
Plugins::ListenLater::Plugin::_writeMaterialActions();
is('an undelivered suppressor is not claimed as a suppressor',
    (svc_line('music') =~ /Add HIDDEN \(empty 'music-album' in actions\.json\)/) ? 'file fallback'
        : svc_line('music'), 'file fallback');

Slim::Utils::Prefs::set_test_pref('debug_log', 0);
Slim::Utils::Prefs::set_test_pref_ns('plugin.podcast', 'feeds', []);
delete $Slim::Control::Request::RESULTS{apps};
delete $Slim::Control::Request::RESULTS{radios};

# ---------------------------------------------------------------------------
section('tier 2 — the deferred pass registers radio commands discovered late');

reset_all();
install_api();
set_material_version('6.4.9');
Plugins::ListenLater::Plugin::_registerMaterialActions();
my $empties1 = n_empties();
is('bbcsounds is not known at postinit (its directory has not loaded)',
    (grep { $_ eq 'bbcsounds-album' } registered_empties()) ? 'known' : 'unknown', 'unknown');

# TuneIn's directory arrives ~60s later; the deferred pass is what sees it (0.1.56).
$Slim::Control::Request::RESULTS{radios} =
    [ { cmd => 'bbcsounds' }, { cmd => 'qobuz' }, { cmd => 'music' } ];
Plugins::ListenLater::Plugin::_writeMaterialActionsDeferred();
is('the deferred pass registers the newly-discovered command',
    (grep { $_ eq 'bbcsounds-album' } registered_empties()) ? 'registered' : 'missed', 'registered');
is('...but not one we can actually replay',
    (grep { $_ eq 'qobuz-album' } registered_empties()) ? 'suppressed' : 'left alone',
    'left alone');
is('...and does NOT re-register the ones it already asked for',
    n_empties(), $empties1 + 2);
is('...nor re-register any positive entry', n_actions(), $T2TOTAL);
is('the file is still absent afterwards',
    (-e actions_file() ? 'recreated' : 'absent'), 'absent');
delete $Slim::Control::Request::RESULTS{radios};

# ---------------------------------------------------------------------------
section('tier 2 — turning the pref ON mid-run must REGISTER (reported live, 0.1.111)');

# Reported from the box: installed with "Add to Material context menus" OFF, saw no context
# menus, ticked it on — and nothing happened until a restart.
#
# On tier 0/1 the Settings save wrote the full set to the FILE, and that is what made the
# toggle work before a restart (0.1.96/0.1.97). Tier 2 has no file write, so the save has to
# REGISTER instead. The old comment said it "cannot register (no de-dupe, no unregister, so it
# runs once per server run, in postinit)" — but $REGISTERED *is* the de-dupe, and it is false
# in precisely this case, because the pref being off at startup means postinit never
# registered. There is nothing to double.
reset_all();
install_api();
set_material_version('6.4.9');
Slim::Utils::Prefs::preferences('plugin.listenlater')->set('material_action', 0);
Plugins::ListenLater::Plugin::_clearMaterialActions();     # postinit's pref-off branch
is('the pref-off boot registers nothing', n_actions(), 0);

save_settings(sort => 'added', material_action => 1);
is('ticking it ON registers the whole set there and then', n_actions(), $T2TOTAL);
is('...the empty suppressors too, or "Add" appears inside our own list',
    (grep { $_ eq 'listenlater-album' } registered_empties()) ? 'yes' : 'no', 'yes');
is('...and it still writes nothing to the file',
    (-e actions_file() ? 'wrote a file' : 'nothing'), 'nothing');

# And the guard that makes it safe: a second save must not double anything.
save_settings(sort => 'added', material_action => 1);
is('a second save registers nothing further (the $REGISTERED latch is the de-dupe)',
    n_actions(), $T2TOTAL);
is('...nor re-declares an empty section', n_empties(),
    scalar(() = Plugins::ListenLater::Plugin::_ownSurfaceSuppressorCats())
    + scalar(() = Plugins::ListenLater::Plugin::_radioSuppressorCats()));

# The postinit case must be unaffected: if it already registered, the save adds nothing.
reset_all();
Plugins::ListenLater::Plugin::_registerMaterialActions();  # postinit, pref on
my $postinit = n_actions();
save_settings(sort => 'added', material_action => 1);
is('a save after a normal pref-on boot registers nothing extra', n_actions(), $postinit);
Slim::Utils::Prefs::preferences('plugin.listenlater')->set('material_action', 1);

# ---------------------------------------------------------------------------
section('tier 2 — the pref turned off, and downgrading again');

reset_all();
install_api();
set_material_version('6.4.9');
Plugins::ListenLater::Plugin::_registerMaterialActions();
Plugins::ListenLater::Plugin::_writeMaterialActions();
Slim::Utils::Log::clear();
Plugins::ListenLater::Plugin::_clearMaterialActions();
is('turning the pref off leaves nothing of ours on disk',
    (-e actions_file() ? 'file remains' : 'nothing'), 'nothing');
is('...and says the registered half goes at the next restart',
    (grep { /next\s+server restart/ } Slim::Utils::Log::lines()) ? 'warned' : 'silent',
    'warned');

# The path postinitPlugin's `elsif` takes: the pref was ALREADY off at startup, so nothing
# registered this run. A suppressor only exists to hold OUR live online-* pair off our own
# rows — with nothing of ours live there is nothing to hold back, and writing the empty
# `<cmd>-*` categories anyway would suppress ANOTHER plugin's online-* actions on every radio
# and podcast row, with nothing of ours left running to clean them up. So the file-fallback
# for suppressors is gated on something actually having registered.
reset_all();
install_api();
set_material_version('6.4.9');
File::Path::make_path("$tmp/material-skin");
open my $lfh, '>:raw', actions_file() or die $!;
print $lfh $JSON->encode({ 'listenlater-album' => [], 'music-album' => [],
                           'online-album' => [ { title => 'Add to Listen Later',
                                                 lmscommand => ['listenlater','addctx'] } ] });
close $lfh;
Plugins::ListenLater::Plugin::_clearMaterialActions();     # pref off at startup — no register
is('pref off at STARTUP (nothing registered) removes the file outright',
    (-e actions_file() ? 'file remains' : 'nothing'), 'nothing');

# Uninstall/disable. 0.1.108's rule, unchanged by the tier: on the way out there is no next
# run to protect, so nothing of ours may be left behind — not even a fallback for something
# Material refused, since nothing will ever come back to tidy it.
reset_all();
install_failing_api(sub { $_[0] eq 'online-album' });
set_material_version('6.4.9');
Plugins::ListenLater::Plugin::_registerMaterialActions();
Plugins::ListenLater::Plugin::_writeMaterialActions();
is('a refused section left a file behind while we were running',
    (-e actions_file() ? 'kept' : 'gone'), 'kept');
Plugins::ListenLater::Plugin::_clearMaterialActions(1);    # $departing
is('...and the uninstall takes even that away',
    (-e actions_file() ? 'stranded' : 'nothing'), 'nothing');
install_api();

# A Material downgrade (or an uninstall of it, or a rollback) must self-heal: the tier drops
# and the legacy write rebuilds the file it had removed. Nothing is stranded.
set_material_version('6.4.7');
reset_all();
Plugins::ListenLater::Plugin::_registerMaterialActions();
Plugins::ListenLater::Plugin::_writeMaterialActions();
my $down = read_file();
is('downgrading to 6.4.7 rebuilds the file half', ours_in_file($down), $FILEHALF);
is('...including the suppressors, which no longer register there',
    (exists $down->{'listenlater-album'} && exists $down->{'music-album'}) ? 'yes' : 'no', 'yes');
is('...and no empty section was registered on the way',
    n_empties(), 0);

remove_api();
reset_all();
set_material_version(undef);
Plugins::ListenLater::Plugin::_writeMaterialActions();
is('dropping to a Material with no API at all restores the full legacy file',
    ours_in_file(read_file()), $TOTAL + $FILEHALF);

set_material_version(undef);

# ===========================================================================
# Sources::materialAtLeast — the ONE version comparator (0.1.114)
#
# Three gates used to parse and compare inline (the 6.4.8 tier gate, the 6.4.4
# diagnostics line, Browse::_headerType's 6.4.3). They now share this sub, so its
# three-way answer is pinned here rather than implied by whichever gate a later
# test happens to drive.
# ===========================================================================
section('Sources::materialAtLeast — the one version comparator');

my $mal = \&Plugins::ListenLater::Sources::materialAtLeast;

is('exact match is "at least"',            $mal->('6.4.8', 6,4,8), 1);
is('a later patch',                        $mal->('6.4.9', 6,4,8), 1);
is('an earlier patch',                     $mal->('6.4.7', 6,4,8), 0);
is('minor outranks patch',                 $mal->('6.5.0', 6,4,8), 1);
is('...in both directions',                $mal->('6.3.9', 6,4,8), 0);
is('major outranks minor',                 $mal->('7.0.0', 6,4,8), 1);
is('...in both directions',                $mal->('5.9.9', 6,4,8), 0);
is('trailing text after the triple still parses', $mal->('6.4.8-beta1', 6,4,8), 1);
is('multi-digit parts compare NUMERICALLY, not as strings',
                                           $mal->('6.10.0', 6,4,8), 1);

# The three-way answer. undef and 0 are both falsy so every current caller treats
# them alike, but they are DIFFERENT answers and a caller may one day need to tell
# "cannot tell" from "too old" — so the shape is pinned, not just the truthiness.
is('undef version answers undef (cannot tell), not 0',
                                           $mal->(undef, 6,4,8), undef);
is('a non-numeric dev/test build answers 1 (treated as newest)',
                                           $mal->('test', 6,4,8), 1);
is('...and so does the empty string, which matches no triple',
                                           $mal->('', 6,4,8), 1);
is('cannot-tell is FALSY, so `? A : B` gives every caller its safe answer',
                                           ($mal->(undef, 6,4,8) ? 'true' : 'false'), 'false');

# THE TRAP THIS SUB IS EASIEST TO BREAK BY, and it is not hypothetical: it shipped
# during the 0.1.114 refactor and this suite is what caught it. _materialVersion is
# `return eval { ... }`, and a failed eval BLOCK yields an EMPTY LIST in list context.
# Inlined into the argument list the args collapse from (undef,6,4,8) to (6,4,8), so
# $ver becomes 6, fails the numeric match, and takes the dev-build branch — every
# install without Material silently reaching the NEWEST tier instead of the safest.
my @collapsed = (6, 4, 8);                 # what an inlined empty-list call really passes
is('the arg-collapse shape answers 1 — which is why the call site must use a scalar',
                                           $mal->(@collapsed), 1);
is('...whereas the correct call answers undef',
                                           $mal->(undef, @collapsed), undef);

# Pin the call sites themselves. There is no return value that shows WHICH spelling a
# caller used, so this is a source check — the same reason 0.1.145's handshake test
# added one. A caller that inlines the eval-returning sub reintroduces the trap above.
{
    my $src = do {
        local $/;
        open my $fh, '<', $ENV{LL_PLUGIN_SRC} || "$FindBin::Bin/../ListenLater/Plugin.pm"
            or die "cannot read Plugin.pm: $!";
        <$fh>;
    };
    is('no call site inlines _materialVersion() into materialAtLeast(...)',
        ($src =~ /materialAtLeast\(\s*_materialVersion\(\)/ ? 'inlined' : 'scalar first'),
        'scalar first');
    my $n = () = $src =~ /materialAtLeast\(/g;
    is('Plugin.pm asks through the shared comparator twice (tier gate + diagnostics)',
        $n, 2);
    is('...and parses no version triple of its own any more',
        ($src =~ /\$1\s*<=>\s*\d+\s*\|\|/ ? 'inline compare left' : 'none'), 'none');
}
{
    my $src = do {
        local $/;
        open my $fh, '<', $ENV{LL_BROWSE_SRC} || "$FindBin::Bin/../ListenLater/Browse.pm"
            or die "cannot read Browse.pm: $!";
        <$fh>;
    };
    is('Browse::_headerType asks through the shared comparator too',
        ($src =~ /materialAtLeast\(/ ? 'yes' : 'no'), 'yes');
    is('...and parses no version triple of its own any more',
        ($src =~ /\$1\s*<=>\s*\d+\s*\|\|/ ? 'inline compare left' : 'none'), 'none');
}

# ---------------------------------------------------------------------------
section('the pref-off diagnostics must describe what is LIVE, not what we built');

# Both cases below are the same substitution the third 2026-09-03 round fixed in the writer
# and the per-service verdict — "did our half register" standing in for "is our entry live" —
# caught in the two places that round did not reach. Neither changes behaviour: both are the
# log a "where did Add go" report is made from, which is exactly why they have to be true.

sub snapshot { return $Slim::Utils::Prefs::VALUES{material_debug_snapshot} // '' }

# (a) Registration refuses EVERYTHING, then the user turns the pref off. The prune drops the
# positive file fallback on that path (%fallback = ()), so a count of "built minus %fallback"
# credits every REFUSED entry as delivered — the dump then claims the plugin API carried
# entries that Material never took.
Slim::Utils::Prefs::set_test_pref('debug_log', 1);
reset_all();
install_failing_api(sub { 1 });          # nothing registers, positives land in %UNREGISTERED
set_material_version('6.4.9');
Plugins::ListenLater::Plugin::_registerMaterialActions();
Plugins::ListenLater::Plugin::_writeMaterialActions();
is('the refused positives are recorded as unregistered',
    (scalar keys %Plugins::ListenLater::Plugin::UNREGISTERED) ? 'recorded' : 'none',
    'recorded');
$Slim::Utils::Prefs::VALUES{material_debug_snapshot} = '';
Plugins::ListenLater::Plugin::_clearMaterialActions();      # pref off, tier 2
is('a total registration failure is reported as NONE registered, not as a full set',
    (snapshot() =~ /registered sections = NONE/) ? 'NONE'
        : (snapshot() =~ /registered sections = (.+)/ ? "claimed: $1" : '(no line)'),
    'NONE');
is('...so the dump never calls the API half the delivery route',
    (snapshot() =~ /plugin API \(Material 6\.4\.6\+/) ? 'claimed the API' : 'did not',
    'did not');
is('...and no service is credited with a registered section',
    (snapshot() =~ /Add shown \(via its own registered/) ? 'credited' : 'none', 'none');

# (b) The halves fail independently: the positives register, the one-argument empty-section
# calls are refused. The pref-off warn used to say "No suppressor registered either, so
# another plugin's Add is not being held off those rows" — and _pruneMaterialActions then
# wrote exactly those suppressors to actions.json three lines later.
reset_all();
{
    no strict 'refs';
    no warnings 'redefine';
    # One argument IS the empty-section call; two is a real entry.
    *{'Plugins::MaterialSkin::Plugin::registerCustomAction'} = sub {
        die "registerCustomAction: no empty sections\n" if @_ == 1;
        push @REG, [ @_ ];
    };
}
set_material_version('6.4.9');
Plugins::ListenLater::Plugin::_registerMaterialActions();
Plugins::ListenLater::Plugin::_writeMaterialActions();
is('the positives registered but no empty section did',
    ($Plugins::ListenLater::Plugin::REGISTERED_N
        && !keys %Plugins::ListenLater::Plugin::REGISTERED_EMPTY) ? 'split' : 'not split',
    'split');
Slim::Utils::Log::clear();
Plugins::ListenLater::Plugin::_clearMaterialActions();      # pref off, tier 2
my $warned = join "\n", Slim::Utils::Log::lines();
is('the pref-off warn does not claim another plugin\'s Add is left unsuppressed',
    ($warned =~ /not being held off those rows/) ? 'claimed it' : 'did not', 'did not');
is('...it says the suppressors go to actions.json instead',
    ($warned =~ /go to actions\.json/) ? 'said so' : 'silent', 'said so');
is('...and the prune really did write them, which is what makes that true',
    (grep { exists read_file()->{$_} } qw(listenlater-album music-album)) ? 'written' : 'absent',
    'written');
Slim::Utils::Prefs::set_test_pref('debug_log', 0);
install_api();
set_material_version(undef);

# ---------------------------------------------------------------------------
section('the prune dump does not claim delivery registration never made');
# The pref-off-at-STARTUP path: postinit calls _clearMaterialActions, which on tier 2 prunes.
# Nothing registered, so nothing was refused either, and %UNREGISTERED is empty for the OPPOSITE
# of the usual reason. _deliveredCounts subtracts that ledger, so consulted here it reports the
# whole built set as delivered — and the prune passed a hardcoded $api = 1 alongside it. The dump
# then answered "plugin API", "streaming Add active" and "registered sections = ..." directly
# under "material_action pref = OFF", in the one log a "where did Add go" report is read from.
# Pinned on the DUMP TEXT rather than the counts, because the text is what gets pasted back.
sub snap_lines { return split /\n/, ($Slim::Utils::Prefs::VALUES{material_debug_snapshot} // '') }
sub snap_line {
    my ($re) = @_;
    my ($line) = grep { /$re/ } snap_lines();
    return $line // '(no such line)';
}

reset_all();
install_api();
set_material_version('6.4.9');
Slim::Utils::Prefs::set_test_pref('debug_log', 1);
save_settings(material_action => 0, debug_log => 1);
# NB no _registerMaterialActions() call — that is precisely the state under test.
is('nothing registered, so there is nothing to have refused',
    ($Plugins::ListenLater::Plugin::REGISTERED
        || keys %Plugins::ListenLater::Plugin::UNREGISTERED) ? 'ran' : 'never ran', 'never ran');
Plugins::ListenLater::Plugin::_clearMaterialActions();
is('the dump still reports the pref as off',
    (snap_line(qr/^material_action pref/) =~ /OFF/) ? 'off' : snap_line(qr/^material_action pref/),
    'off');
is('...and does NOT claim the plugin API delivered anything',
    (snap_line(qr/^custom-action delivery/) =~ /plugin API/) ? 'claimed the API' : 'did not',
    'did not');
is('...nor claims streaming Add is active',
    (grep { /streaming Add active/ } snap_lines()) ? 'claimed active' : 'did not', 'did not');
is('...nor lists registered sections',
    (grep { /^registered sections/ } snap_lines()) ? 'listed some' : 'did not', 'did not');
is('...nor credits a service to a registered section it never asked for',
    (grep { /via its own registered/ } snap_lines()) ? 'credited one' : 'did not', 'did not');

# The mirror: when registration HAS run, every one of those statements must come back — or the
# gate above would be indistinguishable from simply never reporting the API half.
reset_all();
install_api();
set_material_version('6.4.9');
save_settings(material_action => 1, debug_log => 1);
Plugins::ListenLater::Plugin::_registerMaterialActions();
Plugins::ListenLater::Plugin::_writeMaterialActions();
is('with registration done the dump does name the plugin API',
    (snap_line(qr/^custom-action delivery/) =~ /plugin API/) ? 'named it' : snap_line(qr/^custom-action delivery/),
    'named it');
is('...and lists the registered sections',
    (grep { /^registered sections = \w/ } snap_lines()) ? 'listed' : 'silent', 'listed');
Slim::Utils::Prefs::set_test_pref('debug_log', 0);
install_api();
set_material_version(undef);

# ---------------------------------------------------------------------------
section('an UNREADABLE actions.json is never written over, and never deleted');

sub raw_on_disk {
    my $f = actions_file();
    return undef unless -e $f;
    open my $fh, '<:raw', $f or return '(unopenable)';
    local $/; my $c = <$fh>; close $fh;
    return defined $c ? $c : '';
}
# Lay down a shared file in whatever state, then run one delivery pass over it.
sub with_file {
    my ($content, $mode, $run) = @_;
    reset_all();
    File::Path::make_path("$tmp/material-skin");
    open my $fh, '>:raw', actions_file() or die $!;
    print $fh $content; close $fh;
    chmod $mode, actions_file() if defined $mode;
    $run->();
    my $got = raw_on_disk();
    chmod 0644, actions_file() if defined $mode && -e actions_file();
    return $got;
}
# Someone else's actions, and our own entries alongside them — so a pass that DID go through
# would visibly change the file either way (stripping ours, or blanking the lot).
my $shared = $JSON->encode({
    'album'             => [ { title => 'Their Thing', command => [ 'their', 'cmd' ] } ],
    'otherplugin-album' => [],
});
my $damaged = ($shared =~ s/\}\s*\z//r);      # truncated mid-object, as a bad hand-edit is

# --- tier 2: the prune, which is the pass that used to unlink ---
my $t2 = sub { install_api(); set_material_version('6.4.9');
               Plugins::ListenLater::Plugin::_registerMaterialActions();
               Plugins::ListenLater::Plugin::_writeMaterialActions(); };

is('tier 2 prune: a malformed file is not deleted',
    (defined with_file($damaged, undef, $t2) ? 'kept' : 'DELETED'), 'kept');
is('...and not altered by so much as a byte',
    with_file($damaged, undef, $t2), $damaged);
is('tier 2 prune: an unopenable file is not deleted',
    (defined with_file($shared, 0000, $t2) ? 'kept' : 'DELETED'), 'kept');
is('...and its contents are intact',
    with_file($shared, 0000, sub { $t2->(); chmod 0644, actions_file() }), $shared);
is('tier 2 prune: valid JSON that is not an OBJECT is left alone too',
    with_file('[1,2,3]', undef, $t2), '[1,2,3]');

# The husk case the {} answer was RIGHT about, and which must keep working: a file holding
# nothing at all belongs to nobody, so the prune still removes it.
is('tier 2 prune: an EMPTY file is still removed as a husk',
    (defined with_file('', undef, $t2) ? 'kept' : 'removed'), 'removed');
is('...whitespace only, the same', 
    (defined with_file("\n  \n", undef, $t2) ? 'kept' : 'removed'), 'removed');

# --- tier 0/1: the write and clear passes, which used to overwrite ---
my $t01 = sub { remove_api(); set_material_version(undef);
                Plugins::ListenLater::Plugin::_writeMaterialActions(); };
is('tier 0 write: a malformed file is not overwritten with our set',
    with_file($damaged, undef, $t01), $damaged);
is('tier 0 write: an unopenable file is not overwritten',
    with_file($shared, 0000, sub { $t01->(); chmod 0644, actions_file() }), $shared);

my $clear = sub { remove_api(); set_material_version(undef);
                  Plugins::ListenLater::Plugin::_clearMaterialActions(); };
is('tier 0 clear: a malformed file is not blanked',
    with_file($damaged, undef, $clear), $damaged);
is('tier 0 clear: an unopenable file is not blanked',
    with_file($shared, 0000, sub { $clear->(); chmod 0644, actions_file() }), $shared);

my $uninstall = sub { install_api(); set_material_version('6.4.9');
                      Plugins::ListenLater::Plugin::_registerMaterialActions();
                      Plugins::ListenLater::Plugin::_clearMaterialActions(1) };
is('uninstall: a malformed file survives the departing clean',
    with_file($damaged, undef, $uninstall), $damaged);

# And the healthy file still goes through all of it, so none of the guards above is just
# switching the passes off. Our own entries are put in it by a tier-0 write first, so there
# is something for the prune to actually do.
reset_all();
remove_api(); set_material_version(undef);
Plugins::ListenLater::Plugin::_writeMaterialActions();          # tier 0: ours land in the file
{
    my $d = read_file();
    $d->{'album'} = [ @{ $d->{'album'} || [] },
                      { title => 'Their Thing', command => [ 'their', 'cmd' ] } ];
    open my $fh, '>:raw', actions_file() or die $!;
    print $fh $JSON->encode($d); close $fh;
}
is('a readable file really does hold our entries at this point',
    (ours_in_file(read_file()) > 0 ? 'yes' : 'no'), 'yes');
install_api(); set_material_version('6.4.9');
Plugins::ListenLater::Plugin::_registerMaterialActions();
Plugins::ListenLater::Plugin::_writeMaterialActions();
is('a READABLE shared file is still pruned — the guards gate on damage, not on sharing',
    ours_in_file(read_file()), 0);
is('...and the third party is still in it', scalar @{ read_file()->{'album'} || [] }, 1);
set_material_version(undef);
reset_all();

printf "\n%d passed, %d failed\n", $pass, $fail;
exit($fail ? 1 : 0);
