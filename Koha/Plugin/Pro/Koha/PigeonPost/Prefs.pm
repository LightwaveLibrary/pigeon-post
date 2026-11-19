package Koha::Plugin::Pro::Koha::PigeonPost::Prefs;

# Patrons whose messaging preferences say "email" but who have no address Koha
# will send to. Every notice for them fails with NO_EMAIL. This module lists
# them and (on request) switches their email preferences to print or SMS, so
# they keep getting notices. Every switch is logged and undoable.

use strict;
use warnings;
use JSON qw();
use Koha::Plugin::Pro::Koha::PigeonPost::Util qw(add_days);

our @EMAIL_FIELDS = qw(email emailpro B_email);
my %NOTICE_FIELD_OK = map { $_ => 1 } @EMAIL_FIELDS, 'cardnumber';
our %MODE_OK = (print => 1, sms_or_print => 1);

sub new {
    my ($class, %args) = @_;
    return bless {%args}, $class;    # dbh, log_table, notice_fields (arrayref)
}

# ---- pure logic -------------------------------------------------------------

# Which borrower columns Koha may send notices to, from the EmailFieldPrimary
# syspref (AutoEmailPrimaryAddress before 23.11). Unknown values fall back to
# "any email field", which flags fewer patrons, never more.
sub notice_fields {
    my ($primary, $selection) = @_;
    $primary //= '';
    return [@EMAIL_FIELDS] if $primary eq '' || uc($primary) eq 'OFF';
    if (uc($primary) eq 'MULTI') {
        my @f = grep { $NOTICE_FIELD_OK{$_} } split /[\s,|]+/, ($selection // '');
        return @f ? \@f : [@EMAIL_FIELDS];
    }
    return [$primary] if $NOTICE_FIELD_OK{$primary};
    return [@EMAIL_FIELDS];
}

# $prefs: [{ pref_id, attr_id, transports => [..], available => [..] }]
# Returns [{ pref_id, attr_id, add => 'print'|'sms'|undef }]. Email is always
# removed; the replacement is the first allowed target this notice supports and
# the patron doesn't already have.
sub plan_switch {
    my ($prefs, %o) = @_;
    my @targets = ($o{mode} // 'print') eq 'sms_or_print' && $o{has_sms} ? ('sms', 'print') : ('print');
    my @plan;
    for my $p (@$prefs) {
        my %have  = map { $_ => 1 } @{ $p->{transports} || [] };
        my %avail = map { $_ => 1 } @{ $p->{available} || [] };
        my ($pick) = grep { $avail{$_} } @targets;
        push @plan, { pref_id => $p->{pref_id}, attr_id => $p->{attr_id}, add => ($pick && !$have{$pick} ? $pick : undef),
                      kept => ($pick && $have{$pick} ? $pick : undef) };
    }
    return \@plan;
}

# One CSV line. Cells starting with = + - @ are prefixed with ' so a
# spreadsheet doesn't run them as formulas.
sub csv_line {
    my @c = map {
        my $v = defined $_ ? "$_" : '';
        $v = "'$v" if $v =~ /\A[=+\-@\t\r]/;
        $v =~ /[",\r\n]/ ? '"' . ($v =~ s/"/""/gr) . '"' : $v;
    } @_;
    return join(',', @c) . "\r\n";
}

# ---- queries ----------------------------------------------------------------

sub _no_address_sql {
    my ($self) = @_;
    my @f = grep { $NOTICE_FIELD_OK{$_} } @{ $self->{notice_fields} || [@EMAIL_FIELDS] };
    @f = @EMAIL_FIELDS unless @f;
    return join ' AND ', map { "COALESCE(TRIM(b.$_),'') = ''" } @f;    # columns come from the allowlist
}

sub count_missing {
    my ($self) = @_;
    my $where = $self->_no_address_sql;
    my ($n) = $self->{dbh}->selectrow_array(qq{
        SELECT COUNT(DISTINCT b.borrowernumber)
          FROM borrower_message_preferences bmp
          JOIN borrower_message_transport_preferences bmtp ON bmtp.borrower_message_preference_id = bmp.borrower_message_preference_id
          JOIN borrowers b ON b.borrowernumber = bmp.borrowernumber
         WHERE bmtp.message_transport_type = 'email' AND $where});
    return $n + 0;
}

# [{ borrowernumber, cardnumber, name, branchcode, categorycode, dateexpiry, smsalertnumber, notices }]
sub missing {
    my ($self, %o) = @_;
    my $limit = $o{limit} && $o{limit} =~ /^\d+$/ ? $o{limit} : 1000;
    my $where = $self->_no_address_sql;
    return $self->{dbh}->selectall_arrayref(qq{
        SELECT b.borrowernumber, b.cardnumber, CONCAT_WS(' ', b.firstname, b.surname) AS name,
               b.branchcode, b.categorycode, b.dateexpiry, b.smsalertnumber,
               GROUP_CONCAT(DISTINCT ma.message_name ORDER BY ma.message_name SEPARATOR ', ') AS notices
          FROM borrower_message_preferences bmp
          JOIN borrower_message_transport_preferences bmtp ON bmtp.borrower_message_preference_id = bmp.borrower_message_preference_id
          JOIN borrowers b ON b.borrowernumber = bmp.borrowernumber
          LEFT JOIN message_attributes ma ON ma.message_attribute_id = bmp.message_attribute_id
         WHERE bmtp.message_transport_type = 'email' AND $where
      GROUP BY b.borrowernumber
      ORDER BY b.surname, b.firstname, b.borrowernumber
         LIMIT ?}, { Slice => {} }, $limit);
}

sub has_notice_address {
    my ($self, $bn) = @_;
    my $where = $self->_no_address_sql;
    my ($none) = $self->{dbh}->selectrow_array("SELECT COUNT(*) FROM borrowers b WHERE b.borrowernumber = ? AND $where", undef, $bn);
    return $none ? 0 : 1;
}

sub _email_prefs {
    my ($self, $bn) = @_;
    my $dbh  = $self->{dbh};
    my $rows = $dbh->selectall_arrayref(q{
        SELECT bmp.borrower_message_preference_id AS pref_id, bmp.message_attribute_id AS attr_id, bmp.wants_digest
          FROM borrower_message_preferences bmp
          JOIN borrower_message_transport_preferences bmtp ON bmtp.borrower_message_preference_id = bmp.borrower_message_preference_id
         WHERE bmp.borrowernumber = ? AND bmtp.message_transport_type = 'email'}, { Slice => {} }, $bn);
    for my $p (@$rows) {
        $p->{transports} = $dbh->selectcol_arrayref(
            'SELECT message_transport_type FROM borrower_message_transport_preferences WHERE borrower_message_preference_id = ?', undef, $p->{pref_id});
        my $av = $dbh->selectcol_arrayref(
            'SELECT DISTINCT message_transport_type FROM message_transports WHERE message_attribute_id = ? AND is_digest = ?',
            undef, $p->{attr_id}, $p->{wants_digest} ? 1 : 0);
        $av = $dbh->selectcol_arrayref('SELECT DISTINCT message_transport_type FROM message_transports WHERE message_attribute_id = ?',
            undef, $p->{attr_id}) unless @$av;
        $p->{available} = $av;
    }
    return $rows;
}

sub _txn {
    my ($self, $code) = @_;
    my $dbh = $self->{dbh};
    my $own = $dbh->{AutoCommit};
    $dbh->begin_work if $own;
    my $r = eval { my $v = $code->(); $dbh->commit if $own; $v };
    if (my $e = $@) { eval { $dbh->rollback } if $own; die $e }
    return $r;
}

# Switch one patron's email preferences. Returns { ok, changed, to, log_id } or
# { ok => 0, error }. Does nothing (ok, changed 0) if there are no email prefs.
sub switch {
    my ($self, $bn, %o) = @_;
    my $mode = $MODE_OK{ $o{mode} // '' } ? $o{mode} : 'print';
    my $dbh  = $self->{dbh};
    my $t    = $self->{log_table};
    my ($sms) = $dbh->selectrow_array('SELECT smsalertnumber FROM borrowers WHERE borrowernumber = ?', undef, $bn);
    return { ok => 0, error => 'patron not found' } unless defined $dbh->selectrow_array('SELECT 1 FROM borrowers WHERE borrowernumber = ?', undef, $bn);
    return { ok => 0, error => 'patron now has an email address' } if $self->has_notice_address($bn);
    my $prefs = $self->_email_prefs($bn);
    return { ok => 1, changed => 0 } unless @$prefs;
    my $plan = plan_switch($prefs, mode => $mode, has_sms => (defined $sms && $sms =~ /\S/));

    my %to;
    $to{ $_->{add} // $_->{kept} // 'none' }++ for @$plan;
    my $summary = join ', ', map { "$to{$_} to " . ($_ eq 'none' ? 'nothing (no print or SMS version)' : $_) } sort keys %to;

    my $log_id = $self->_txn(sub {
        for my $p (@$plan) {
            $dbh->do(q{DELETE FROM borrower_message_transport_preferences WHERE borrower_message_preference_id = ? AND message_transport_type = 'email'},
                undef, $p->{pref_id});
            $dbh->do(q{INSERT IGNORE INTO borrower_message_transport_preferences (borrower_message_preference_id, message_transport_type) VALUES (?,?)},
                undef, $p->{pref_id}, $p->{add}) if $p->{add};
        }
        $dbh->do(qq{INSERT INTO $t (borrowernumber, notices, summary, changes, source, changed_at, changed_by) VALUES (?,?,?,?,?,NOW(),?)},
            undef, $bn, scalar(@$plan), $summary, JSON::encode_json($plan), $o{source}, $o{staff});
        return $dbh->{mysql_insertid} // $dbh->last_insert_id(undef, undef, $t, 'id');
    });
    return { ok => 1, changed => scalar(@$plan), summary => $summary, log_id => $log_id };
}

sub undo {
    my ($self, $id, $staff) = @_;
    my $dbh = $self->{dbh};
    my $t   = $self->{log_table};
    my $row = $dbh->selectrow_hashref("SELECT * FROM $t WHERE id = ?", undef, $id) or return { ok => 0, error => 'Log entry not found' };
    return { ok => 0, error => 'Already undone' } if $row->{undone_at};
    my $plan = eval { JSON::decode_json($row->{changes}) } || [];
    my $restored = $self->_txn(sub {
        my $n = 0;
        for my $p (@$plan) {
            # The patron may have edited their preferences since; skip rows that are gone.
            next unless $dbh->selectrow_array('SELECT 1 FROM borrower_message_preferences WHERE borrower_message_preference_id = ? AND borrowernumber = ?',
                undef, $p->{pref_id}, $row->{borrowernumber});
            $dbh->do('DELETE FROM borrower_message_transport_preferences WHERE borrower_message_preference_id = ? AND message_transport_type = ?',
                undef, $p->{pref_id}, $p->{add}) if $p->{add};
            $dbh->do(q{INSERT IGNORE INTO borrower_message_transport_preferences (borrower_message_preference_id, message_transport_type) VALUES (?, 'email')},
                undef, $p->{pref_id});
            $n++;
        }
        $dbh->do("UPDATE $t SET undone_at = NOW(), undone_by = ? WHERE id = ?", undef, $staff, $id);
        return $n;
    });
    return { ok => 1, restored => $restored };
}

# Undo whatever a cleanup-log entry switched (source "cleanup:<id>").
sub undo_source {
    my ($self, $source, $staff) = @_;
    my $ids = $self->{dbh}->selectcol_arrayref("SELECT id FROM $self->{log_table} WHERE source = ? AND undone_at IS NULL", undef, $source);
    return [ map { $self->undo($_, $staff) } @$ids ];
}

sub log_entries {
    my ($self, $limit) = @_;
    my $t = $self->{log_table};
    return $self->{dbh}->selectall_arrayref(
        qq{SELECT l.id, l.borrowernumber, l.notices, l.summary, l.source, l.changed_at, l.changed_by, l.undone_at,
                  CONCAT_WS(' ', b.firstname, b.surname) AS name, b.cardnumber,
                  CONCAT_WS(' ', s.firstname, s.surname) AS changed_by_name
             FROM $t l LEFT JOIN borrowers b ON b.borrowernumber = l.borrowernumber
                       LEFT JOIN borrowers s ON s.borrowernumber = l.changed_by
         ORDER BY l.id DESC LIMIT ?}, { Slice => {} }, $limit || 100);
}

sub switched_between {
    my ($self, $from, $to) = @_;
    my ($n) = $self->{dbh}->selectrow_array(
        "SELECT COUNT(*) FROM $self->{log_table} WHERE changed_at >= ? AND changed_at < ? AND undone_at IS NULL",
        undef, "$from 00:00:00", add_days($to, 1) . ' 00:00:00');
    return $n + 0;
}

# NO_EMAIL failures queued in [from, to]; undef if this Koha has no failure_code column.
sub no_email_failures {
    my ($self, $from, $to, $has_failure_code) = @_;
    return undef unless $has_failure_code;
    my ($n) = $self->{dbh}->selectrow_array(
        q{SELECT COUNT(*) FROM message_queue WHERE message_transport_type = 'email' AND status = 'failed'
             AND failure_code LIKE 'NO_EMAIL%' AND time_queued >= ? AND time_queued < ?},
        undef, "$from 00:00:00", add_days($to, 1) . ' 00:00:00');
    return $n + 0;
}

1;
