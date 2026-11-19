use strict;
use warnings;
use Test::More;
use lib '.';
use Koha::Plugin::Pro::Koha::PigeonPost::Prefs;
use Koha::Plugin::Pro::Koha::PigeonPost::Digest;

my $nf = \&Koha::Plugin::Pro::Koha::PigeonPost::Prefs::notice_fields;
is_deeply $nf->(undef), [qw(email emailpro B_email)], 'no syspref: any email field';
is_deeply $nf->('OFF'), [qw(email emailpro B_email)], 'OFF: any email field';
is_deeply $nf->(''), [qw(email emailpro B_email)], 'empty: any email field';
is_deeply $nf->('emailpro'), ['emailpro'], 'single field';
is_deeply $nf->('cardnumber'), ['cardnumber'], 'cardnumber allowed when chosen';
is_deeply $nf->('MULTI', 'email|B_email'), [qw(email B_email)], 'MULTI uses EmailFieldSelection';
is_deeply $nf->('MULTI', ''), [qw(email emailpro B_email)], 'MULTI with no selection: any';
is_deeply $nf->('borrowers; DROP'), [qw(email emailpro B_email)], 'unknown value never reaches SQL';

my $plan = \&Koha::Plugin::Pro::Koha::PigeonPost::Prefs::plan_switch;
my $prefs = [
    { pref_id => 1, attr_id => 1, transports => ['email'],          available => [qw(email print sms)] },
    { pref_id => 2, attr_id => 2, transports => ['email', 'print'], available => [qw(email print)] },
    { pref_id => 3, attr_id => 3, transports => ['email'],          available => ['email'] },
    { pref_id => 4, attr_id => 4, transports => ['email'],          available => [qw(email sms)] },
];
my %by = map { $_->{pref_id} => $_ } @{ $plan->($prefs, mode => 'print') };
is $by{1}{add}, 'print', 'print mode adds print';
is $by{2}{add}, undef,   'already has print: nothing added';
is $by{2}{kept}, 'print', '... and it is noted as kept';
is $by{3}{add}, undef,   'no print/SMS version: email just removed';
is $by{4}{add}, undef,   'print mode never adds SMS';

%by = map { $_->{pref_id} => $_ } @{ $plan->($prefs, mode => 'sms_or_print', has_sms => 1) };
is $by{1}{add}, 'sms',   'SMS preferred when patron has a number';
is $by{2}{add}, undef,   'falls back to print, which they already have';
is $by{4}{add}, 'sms',   'SMS-only notice gets SMS';

%by = map { $_->{pref_id} => $_ } @{ $plan->($prefs, mode => 'sms_or_print', has_sms => 0) };
is $by{1}{add}, 'print', 'no SMS number: print';
is $by{4}{add}, undef,   'no SMS number and no print version: removed';

my $csv = \&Koha::Plugin::Pro::Koha::PigeonPost::Prefs::csv_line;
is $csv->('a', 'b,c', 'say "hi"', undef), qq{a,"b,c","say ""hi""",\r\n}, 'CSV quoting';
is $csv->('=1+1', '-2', '@x', 'ok'), qq{'=1+1,'-2,'\@x,ok\r\n}, 'CSV formula guard';

my $html = Koha::Plugin::Pro::Koha::PigeonPost::Digest::build_html({ from => '2026-11-09', to => '2026-11-15',
    no_address => 42, no_email_week => 7, no_email_prev => 14, prefs_switched => 3 });
like $html, qr/Patrons without an email address/, 'digest has the no-address card';
like $html, qr/>42</, '... with the count';
like $html, qr/-50% vs last week/, '... and the NO_EMAIL trend';
unlike Koha::Plugin::Pro::Koha::PigeonPost::Digest::build_html({ from => 'a', to => 'b' }), qr/without an email address/, 'card hidden when data missing';

done_testing;
