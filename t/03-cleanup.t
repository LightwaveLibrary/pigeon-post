use strict;
use warnings;
use Test::More;
use lib '.';
use Koha::Plugin::Pro::Koha::PigeonPost::Cleanup;

my $cf = \&Koha::Plugin::Pro::Koha::PigeonPost::Cleanup::consecutive_failures;

my $rows = [
    # a: fails twice, succeeds, then fails three times -> 3
    (map { { address => 'a@x.org', status => 'failed', code => 'SENDMAIL', time => "t$_" } } 1 .. 2),
    { address => 'a@x.org', status => 'sent', time => 't3' },
    (map { { address => 'a@x.org', status => 'failed', code => 'INVALID_EMAIL:to', time => "t$_" } } 4 .. 6),
    # b: fails then succeeds -> 0
    { address => 'B@X.org ', status => 'failed', code => 'SENDMAIL', time => 't1' },
    { address => 'b@x.org',  status => 'sent', time => 't2' },
    # c: ignored codes don't count and don't reset
    { address => 'c@x.org', status => 'failed', code => 'SENDMAIL', time => 't1' },
    { address => 'c@x.org', status => 'failed', code => 'NO_EMAIL', time => 't2' },
    { address => 'c@x.org', status => 'failed', code => 'DUPLICATE_MESSAGE', time => 't3' },
    { address => 'c@x.org', status => 'failed', code => 'SENDMAIL', time => 't4' },
    # blank address ignored
    { address => '  ', status => 'failed', code => 'SENDMAIL', time => 't1' },
];
my $s = $cf->($rows);
is($s->{'a@x.org'}{fails}, 3, 'counts only failures since last success');
is($s->{'a@x.org'}{last_code}, 'INVALID_EMAIL:to', 'last code kept');
is($s->{'a@x.org'}{last_time}, 't6', 'last time kept');
is($s->{'b@x.org'}{fails}, 0, 'success resets; address normalised (case/space)');
ok(!defined $s->{'b@x.org'}{last_code}, 'reset clears last code');
is($s->{'c@x.org'}{fails}, 2, 'non-address failure codes ignored');
ok(!exists $s->{''}, 'blank address skipped');

my $out = \&Koha::Plugin::Pro::Koha::PigeonPost::Cleanup::looks_like_outage;
ok(!$out->(100, 5), 'normal failure rate is not an outage');
ok(!$out->(2, 8), 'too few failures to call it');
ok($out->(5, 50), 'mostly failing = outage');
ok(!$out->(50, 50), 'exactly half is not over 50%');
ok($out->(0, 10), 'all failing = outage');

done_testing;
