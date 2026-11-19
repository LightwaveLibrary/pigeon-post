#!/usr/bin/perl
# Seed message_queue with fake email activity on a DISPOSABLE Koha test instance
# (koha-testing-docker). Refuses to run unless PIGEON_SEED_OK=1 is set.
#
#   PIGEON_SEED_OK=1 perl tools/seed_fixtures.pl [--days 120] [--per-day 40] [--purge]
#
# Every seeded row has subject 'PIGEON-FIXTURE' so --purge removes exactly these.

use strict;
use warnings;
use Getopt::Long;
use C4::Context;

die "Refusing to run: set PIGEON_SEED_OK=1 to confirm this is a disposable test Koha.\n" unless ($ENV{PIGEON_SEED_OK} // '') eq '1';

my ($days, $per_day, $purge) = (120, 40, 0);
GetOptions('days=i' => \$days, 'per-day=i' => \$per_day, 'purge' => \$purge) or die "bad options\n";
my $dbh = C4::Context->dbh;

if ($purge) {
    my $n = $dbh->do(q{DELETE FROM message_queue WHERE subject = 'PIGEON-FIXTURE'});
    print "Removed $n fixture rows.\n";
    exit 0;
}

my $patrons = $dbh->selectall_arrayref(q{SELECT borrowernumber FROM borrowers ORDER BY borrowernumber LIMIT 40});
die "Need some patrons in the test database\n" unless @$patrons;

# Three patrons get permanently bad addresses so cleanup has candidates.
my @bad = map { $_->[0] } @$patrons[ 0 .. 2 ];
for my $i (0 .. $#bad) {
    $dbh->do(q{UPDATE borrowers SET email = ? WHERE borrowernumber = ?}, undef, "bounce$i\@invalid.example", $bad[$i]);
}

my @letters = qw(CHECKOUT CHECKIN PREDUE DUE ODUE HOLD RENEWAL ACCTDETAILS PASSWORD_RESET);
my @codes   = ('SENDMAIL', 'INVALID_EMAIL:to', 'NO_EMAIL', 'UNKNOWN_ERROR');
my $ins = $dbh->prepare(q{INSERT INTO message_queue
    (borrowernumber, subject, content, letter_code, message_transport_type, status, time_queued, updated_on, to_address, failure_code, content_type)
    VALUES (?, 'PIGEON-FIXTURE', 'fixture', ?, 'email', ?, ?, ?, ?, ?, 'text/plain; charset="UTF-8"')});

my $rows = 0;
srand(42);
for my $d (reverse 0 .. $days) {
    my $n = int($per_day * (0.6 + rand(0.8)));
    $n = int($n / 3) if (localtime(time - $d * 86400))[6] =~ /^[06]$/;    # quieter weekends
    for (1 .. $n) {
        my $bn     = $patrons->[ int rand @$patrons ][0];
        my $hour   = 7 + int(rand(12));
        my $ts     = sprintf('%s %02d:%02d:00', _day($d), $hour, int rand 60);
        my $letter = $letters[ int rand @letters ];
        my ($status, $code, $to) = ('sent', undef, "patron$bn\@example.org");
        my $r = rand;
        if    ($r < 0.06) { ($status, $code) = ('failed', $codes[0]) }
        elsif ($r < 0.08) { ($status, $code, $to) = ('failed', $codes[2], undef) }
        elsif ($d == 0 && $r < 0.15) { $status = 'pending' }
        $ins->execute($bn, $letter, $status, $ts, $ts, $to, $code);
        $rows++;
    }
    # the bad addresses fail every few days
    if ($d % 4 == 0) {
        for my $i (0 .. $#bad) {
            my $ts = _day($d) . ' 09:15:00';
            $ins->execute($bad[$i], 'ODUE', 'failed', $ts, $ts, "bounce$i\@invalid.example", $codes[1]);
            $rows++;
        }
    }
}
# a stuck pending email from 3 hours ago, to exercise the queue warning
my $old = $dbh->selectrow_array(q{SELECT NOW() - INTERVAL 3 HOUR});
$ins->execute($patrons->[0][0], 'HOLD', 'pending', $old, $old, 'patron@example.org', undef);
$rows++;

print "Inserted $rows fixture rows over " . ($days + 1) . " days. Bad addresses on borrowers @bad.\n";

sub _day { my @t = localtime(time - shift() * 86400); return sprintf('%04d-%02d-%02d', $t[5] + 1900, $t[4] + 1, $t[3]) }
