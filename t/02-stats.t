use strict;
use warnings;
use Test::More;
use lib '.';
use Koha::Plugin::Pro::Koha::PigeonPost::Stats;

my $agg = \&Koha::Plugin::Pro::Koha::PigeonPost::Stats::aggregate;
my $rows = [
    { day => '2026-11-01', letter_code => 'CHECKOUT', sent => 10, failed => 1, pending => 0 },
    { day => '2026-11-01', letter_code => 'ODUE',     sent => 5,  failed => 4, pending => 0 },
    { day => '2026-11-03', letter_code => 'CHECKOUT', sent => 7,  failed => 0, pending => 2 },
    { day => '2026-10-31', letter_code => 'CHECKOUT', sent => 99, failed => 9, pending => 0 },    # outside range
    { day => '2026-11-02', letter_code => '',         sent => 1,  failed => 0, pending => 0 },
];

my $r = $agg->($rows, '2026-11-01', '2026-11-03');
is(scalar @{ $r->{series} }, 3, 'contiguous series fills the gap day');
is_deeply($r->{series}[1], { day => '2026-11-02', sent => 1, failed => 0, pending => 0 }, 'day 2');
is_deeply([ @{ $r->{totals} }{qw(sent failed pending)} ], [ 23, 5, 2 ], 'totals exclude out-of-range rows');
is($r->{totals}{failure_rate}, 17.9, 'failure rate = failed/(sent+failed) to 1dp');
is($r->{by_letter}[0]{letter_code}, 'CHECKOUT', 'busiest letter first');
ok((grep { $_->{letter_code} eq '(none)' } @{ $r->{by_letter} }), 'blank letter code labelled');

my $f = $agg->($rows, '2026-11-01', '2026-11-03', 'ODUE');
is_deeply([ @{ $f->{totals} }{qw(sent failed)} ], [ 5, 4 ], 'letter filter');
is(scalar @{ $f->{by_letter} }, 1, 'only filtered letter listed');

my $e = $agg->([], '2026-11-01', '2026-11-01');
is_deeply([ @{ $e->{totals} }{qw(sent failed pending failure_rate)} ], [ 0, 0, 0, 0 ], 'empty range is all zeros, no divide by zero');

my $s = Koha::Plugin::Pro::Koha::PigeonPost::Stats->new;
is($s->cutoff('2026-11-19'), '2026-11-17', 'rollup cutoff lags two days');

done_testing;
