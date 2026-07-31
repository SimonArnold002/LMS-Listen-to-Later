#!/usr/bin/env perl
# Every shipped module must COMPILE and LOAD. Cheap, and it catches the class of mistake
# `perl -c` misses: a call to a sub that no longer exists compiles fine and only dies when
# that line runs (which is how a rename nearly shipped a runtime crash in 0.1.83). Loading
# each module for real also means the other suites can't pass against a module that never
# compiled.
#
# The called-vs-defined sweep below is the deliberate second half: for each module it
# collects the subs it DEFINES and the plugin-internal subs it CALLS, and reports any call
# with no definition anywhere in the plugin.
use strict;
use warnings;
use FindBin;
require "$FindBin::Bin/t_stubs.pl";

my @MODULES = qw(DB Sources Podcast Browse Played Settings HomeExtras Plugin);

my ($pass, $fail) = (0, 0);
sub is {
    my ($desc, $got, $want) = @_;
    my $ok = (defined $got && defined $want && "$got" eq "$want");
    $ok ? $pass++ : $fail++;
    printf "%s %-40s %s\n", ($ok ? 'ok  ' : 'FAIL'), $desc, ($ok ? '' : "-> $got");
}

print "== every module loads\n";
for my $m (@MODULES) {
    my $err = '';
    eval { ll_require($m); 1 } or $err = $@ || 'unknown error';
    $err =~ s/\s+/ /g;
    is($m, ($err ? substr($err, 0, 120) : 'loaded'), 'loaded');
}

# ---------------------------------------------------------------------------
print "\n== called-vs-defined (perl -c cannot see these)\n";
my $dir = "$FindBin::Bin/../ListenLater";
my (%defined, %called);
for my $m (@MODULES) {
    open(my $fh, '<:encoding(UTF-8)', "$dir/$m.pm") or next;
    my $src = do { local $/; <$fh> }; close $fh;
    # Strip comments and POD so a sub named in prose isn't taken for a call.
    $src =~ s/^=\w.*?^=cut//gsm;
    $src =~ s/^\s*#.*$//gm;
    $defined{"Plugins::ListenLater::${m}::$1"} = 1 while $src =~ /^sub\s+(\w+)/gm;
    $defined{$1} = 1                            while $src =~ /^sub\s+(\w+)/gm;
    # Fully-qualified calls to our own packages, and bare calls to _private helpers.
    while ($src =~ /(Plugins::ListenLater::\w+::\w+)\s*\(/g) { $called{$1} = $m }
    while ($src =~ /(?<![\w:>&])(_\w+)\s*\(/g)               { $called{"${m}::$1"} = $m }
}
my @missing;
for my $c (sort keys %called) {
    my $bare = $c; $bare =~ s/.*:://;
    next if $defined{$c} || $defined{$bare};
    next if $bare =~ /^_(?:norm|artistMatch|albumMatches)$/;   # cross-module matcher calls
    push @missing, "$c (called in $called{$c}.pm)";
}
is('no calls to undefined subs', (@missing ? join('; ', @missing) : 'none'), 'none');

printf "\n%d passed, %d failed\n", $pass, $fail;
exit($fail ? 1 : 0);
