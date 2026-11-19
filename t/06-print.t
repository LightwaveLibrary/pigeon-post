use strict;
use warnings;
use Test::More;
use lib '.';
use Koha::Plugin::Pro::Koha::PigeonPost::PrintQueue;
use Koha::Plugin::Pro::Koha::PigeonPost::Digest;

my $vd = \&Koha::Plugin::Pro::Koha::PigeonPost::PrintQueue::valid_days;
is $vd->(30), 30, 'valid days kept';
is $vd->('7'), 7, 'string number kept';
is $vd->(undef), 90, 'missing -> 90';
is $vd->(0), 90, 'zero -> 90';
is $vd->(-5), 90, 'negative -> 90';
is $vd->('90; DROP TABLE x'), 90, 'junk -> 90';
is $vd->(9999), 90, 'too large -> 90';

my $cut = \&Koha::Plugin::Pro::Koha::PigeonPost::PrintQueue::cutoff;
is $cut->(90, '2026-11-19'), '2026-08-21 00:00:00', '90 days before';
is $cut->(1, '2026-03-01'), '2026-02-28 00:00:00', 'month boundary';
is $cut->('bad', '2026-11-19'), '2026-08-21 00:00:00', 'bad value uses the default';

my $html = Koha::Plugin::Pro::Koha::PigeonPost::Digest::build_html({ from => '2026-11-09', to => '2026-11-15',
    print => { pending => 1234, old => 900, days => 90, cleared => 12 } });
like $html, qr/Unprinted print notices/, 'digest has the print card';
like $html, qr/Older than 90 days/, '... with the age';
like $html, qr/1,234/, '... and the waiting count';
like $html, qr/gather_print_notices/, '... and the hint when some are old';
unlike Koha::Plugin::Pro::Koha::PigeonPost::Digest::build_html({ from => 'a', to => 'b' }), qr/Unprinted print/, 'card hidden without data';

done_testing;
