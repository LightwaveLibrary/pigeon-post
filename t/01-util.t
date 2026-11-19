use strict;
use warnings;
use Test::More;
use lib '.';
use Koha::Plugin::Pro::Koha::PigeonPost::Util qw(valid_date add_days days_between parse_range escape_html wday_of);

ok(valid_date('2026-11-19'), 'valid date');
ok(!valid_date('2026-13-01'), 'bad month');
ok(!valid_date('2026-02-30'), 'impossible day');
ok(!valid_date("2026-11-19'; DROP"), 'injection rejected');
ok(!valid_date(undef), 'undef');

is(add_days('2026-11-19', 1), '2026-11-20', 'add 1');
is(add_days('2026-03-01', -1), '2026-02-28', 'month boundary');
is(add_days('2024-03-01', -1), '2024-02-29', 'leap year');
is(add_days('2026-12-31', 1), '2027-01-01', 'year boundary');
is(days_between('2026-11-01', '2026-11-30'), 30, 'inclusive days');
is(wday_of('2026-11-19'), 4, 'Thursday');

my $today = '2026-11-19';
is_deeply([ parse_range(undef, undef, $today) ], [ '2026-10-21', '2026-11-19' ], 'default = last 30 days');
is_deeply([ parse_range('2026-11-10', '2026-11-01', $today) ], [ '2026-11-01', '2026-11-10' ], 'reversed bounds swapped');
is_deeply([ parse_range('2026-11-01', '2027-01-01', $today) ], [ '2026-11-01', '2026-11-19' ], 'future end clamped to today');
is_deeply([ parse_range('2026-12-01', '2027-01-01', $today) ], [ '2026-11-19', '2026-11-19' ], 'entirely future range collapses to today');
is_deeply([ parse_range('1990-01-01', '2026-11-19', $today) ], [ add_days('2026-11-19', -3659), '2026-11-19' ], 'capped at 3660 days');
is_deeply([ parse_range('garbage', '2026-11-19', $today) ], [ '2026-10-21', '2026-11-19' ], 'bad from falls back');

is(escape_html(q{<a href="x">&'</a>}), '&lt;a href=&quot;x&quot;&gt;&amp;&#39;&lt;/a&gt;', 'escape');

done_testing;
