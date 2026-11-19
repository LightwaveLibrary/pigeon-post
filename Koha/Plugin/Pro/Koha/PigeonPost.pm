package Koha::Plugin::Pro::Koha::PigeonPost;

# Pigeon Post — email activity dashboard for Koha (Tools → Pigeon Post Dashboard).

use strict;
use warnings;
use base qw(Koha::Plugins::Base);

use C4::Context;
use JSON qw();
use Koha::Plugin::Pro::Koha::PigeonPost::Util qw(today add_days parse_range);
use Koha::Plugin::Pro::Koha::PigeonPost::Stats;
use Koha::Plugin::Pro::Koha::PigeonPost::Cleanup;
use Koha::Plugin::Pro::Koha::PigeonPost::Digest;
use Koha::Plugin::Pro::Koha::PigeonPost::Smtp;
use Koha::Plugin::Pro::Koha::PigeonPost::Prefs;
use Koha::Plugin::Pro::Koha::PigeonPost::PrintQueue;

our $VERSION = '0.3.0';
our $metadata = {
    name            => 'Pigeon Post',
    author          => 'koha.pro',
    description     => 'Email activity dashboard: lifetime and date-range send/failure counts, charts, SMTP status lights, invalid-address cleanup and a weekly digest.',
    date_authored   => '2026-11-19',
    date_updated    => '2026-11-19',
    minimum_version => '22.11.00.000',
    maximum_version => undef,
    version         => $VERSION,
};

my %DEFAULTS = (
    threshold      => 3,
    lookback_days  => 90,
    fields         => 'email',
    auto_cleanup   => 0,
    auto_cap       => 50,
    digest_enabled => 0,
    digest_to      => '',
    digest_weekday => 1,    # Monday
    smtp_cache_s   => 60,
    switch_on_clear => 1,         # clearing an address also moves that patron's email notices
    switch_to       => 'print',   # 'print' or 'sms_or_print'
    print_clear_auto => 0,        # nightly: clear unprinted print notices older than print_clear_days
    print_clear_days => 90,
);

# Assets are addressed by short keys (no file names in the URL, which some WAF
# rules treat as file-access attempts). The page needs exactly one request: the
# bundle. CSS and the logo are inlined into the HTML.
my %ASSETS = (
    bundle => { type => 'application/javascript', files => [ 'chart.umd.min.js', 'pigeon.js' ] },
);

sub new {
    my ($class, $args) = @_;
    $args ||= {};
    $args->{metadata} = { %$metadata, class => $class };
    return $class->SUPER::new($args);
}

# ---- settings ---------------------------------------------------------------

sub setting {
    my ($self, $key) = @_;
    my $v = $self->retrieve_data($key);
    return defined $v && length $v ? $v : $DEFAULTS{$key};
}

sub settings {
    my ($self) = @_;
    my %s = map { $_ => $self->setting($_) } keys %DEFAULTS;
    $s{fields_list} = [ grep { $Koha::Plugin::Pro::Koha::PigeonPost::Cleanup::FIELD_OK{$_} } split /,/, $s{fields} ];
    $s{fields_list} = ['email'] unless @{ $s{fields_list} };
    $s{digest_last_sent} = $self->retrieve_data('digest_last_sent');
    return \%s;
}

# ---- tables -----------------------------------------------------------------

sub stats_table { $_[0]->get_qualified_table_name('daily_stats') }
sub log_table   { $_[0]->get_qualified_table_name('cleanup_log') }
sub prefs_table { $_[0]->get_qualified_table_name('prefs_log') }
sub print_log_table { $_[0]->get_qualified_table_name('print_log') }
sub print_ids_table { $_[0]->get_qualified_table_name('print_cleared') }
sub _print { my $s = shift; Koha::Plugin::Pro::Koha::PigeonPost::PrintQueue->new(dbh => C4::Context->dbh, log_table => $s->print_log_table, ids_table => $s->print_ids_table) }

sub _stats   { my $s = shift; Koha::Plugin::Pro::Koha::PigeonPost::Stats->new(dbh => C4::Context->dbh, rollup_table => $s->stats_table) }
sub _cleanup { my $s = shift; Koha::Plugin::Pro::Koha::PigeonPost::Cleanup->new(dbh => C4::Context->dbh, log_table => $s->log_table) }
sub _prefs {
    my $s = shift;
    my $primary = C4::Context->preference('EmailFieldPrimary') // C4::Context->preference('AutoEmailPrimaryAddress');
    return Koha::Plugin::Pro::Koha::PigeonPost::Prefs->new(
        dbh => C4::Context->dbh, log_table => $s->prefs_table,
        notice_fields => Koha::Plugin::Pro::Koha::PigeonPost::Prefs::notice_fields($primary, C4::Context->preference('EmailFieldSelection')));
}

sub install {
    my ($self) = @_;
    my $dbh = C4::Context->dbh;
    my ($st, $lt) = ($self->stats_table, $self->log_table);
    $dbh->do(qq{CREATE TABLE IF NOT EXISTS $st (
        day DATE NOT NULL,
        letter_code VARCHAR(64) NOT NULL DEFAULT '',
        sent INT UNSIGNED NOT NULL DEFAULT 0,
        failed INT UNSIGNED NOT NULL DEFAULT 0,
        pending INT UNSIGNED NOT NULL DEFAULT 0,
        deleted INT UNSIGNED NOT NULL DEFAULT 0,
        PRIMARY KEY (day, letter_code)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci});
    $dbh->do(qq{CREATE TABLE IF NOT EXISTS $lt (
        id INT NOT NULL AUTO_INCREMENT PRIMARY KEY,
        borrowernumber INT NOT NULL,
        field VARCHAR(16) NOT NULL,
        old_address VARCHAR(255) NOT NULL,
        failures INT NOT NULL DEFAULT 0,
        last_failure_code VARCHAR(255) NULL,
        pending_marked INT NOT NULL DEFAULT 0,
        cleared_at DATETIME NOT NULL,
        cleared_by INT NULL,
        undone_at DATETIME NULL,
        undone_by INT NULL,
        KEY pp_log_borrower (borrowernumber),
        KEY pp_log_cleared (cleared_at)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci});
    my $pt = $self->prefs_table;
    $dbh->do(qq{CREATE TABLE IF NOT EXISTS $pt (
        id INT NOT NULL AUTO_INCREMENT PRIMARY KEY,
        borrowernumber INT NOT NULL,
        notices INT NOT NULL DEFAULT 0,
        summary VARCHAR(255) NULL,
        changes TEXT NOT NULL,
        source VARCHAR(32) NULL,
        changed_at DATETIME NOT NULL,
        changed_by INT NULL,
        undone_at DATETIME NULL,
        undone_by INT NULL,
        KEY pp_prefs_borrower (borrowernumber),
        KEY pp_prefs_changed (changed_at),
        KEY pp_prefs_source (source)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci});
    my ($plt, $pit) = ($self->print_log_table, $self->print_ids_table);
    $dbh->do(qq{CREATE TABLE IF NOT EXISTS $plt (
        id INT NOT NULL AUTO_INCREMENT PRIMARY KEY,
        days INT NOT NULL,
        cutoff DATETIME NOT NULL,
        cleared INT NOT NULL DEFAULT 0,
        source VARCHAR(32) NULL,
        ran_at DATETIME NOT NULL,
        ran_by INT NULL,
        undone_at DATETIME NULL,
        undone_by INT NULL,
        KEY pp_print_ran (ran_at)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci});
    $dbh->do(qq{CREATE TABLE IF NOT EXISTS $pit (
        log_id INT NOT NULL,
        message_id INT NOT NULL,
        PRIMARY KEY (log_id, message_id)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci});
    $self->_rollup;    # backfill whatever queue history Koha still has
    return 1;
}

sub upgrade { my ($self) = @_; return $self->install }    # CREATE TABLE IF NOT EXISTS: adds prefs_log (0.2.0), print_log + print_cleared (0.3.0)

sub uninstall {
    my ($self) = @_;
    my $dbh = C4::Context->dbh;
    $dbh->do('DROP TABLE IF EXISTS ' . $self->stats_table);
    $dbh->do('DROP TABLE IF EXISTS ' . $self->log_table);
    $dbh->do('DROP TABLE IF EXISTS ' . $_) for $self->prefs_table, $self->print_log_table, $self->print_ids_table;
    return 1;
}

sub _rollup {
    my ($self) = @_;
    my $through = $self->retrieve_data('rolled_through');
    my $new = eval { $self->_stats->rollup($through || undef) };
    if ($@) { warn "Pigeon Post rollup failed: $@"; return }
    $self->store_data({ rolled_through => $new }) if $new && (!$through || $new ne $through);
    return $new;
}

# ---- helpers ----------------------------------------------------------------

sub _cgi { my $s = shift; return $s->{cgi} ||= do { require CGI; CGI->new } }

sub _url {
    my ($self, $method, %q) = @_;
    my $u = '/cgi-bin/koha/plugins/run.pl?class=' . ref($self) . '&method=' . $method;
    $u .= join '', map { "&$_=$q{$_}" } sort keys %q;
    return $u;
}

sub _json {
    my ($self, $data, $status) = @_;
    my $cgi = $self->_cgi;
    print $cgi->header(-type => 'application/json', -charset => 'UTF-8', -status => $status || '200 OK', -cache_control => 'no-store');
    print JSON->new->utf8->canonical->allow_nonref->encode($data);
    return;
}

sub _staff { my $u = C4::Context->userenv; return $u ? $u->{number} : undef }

sub can_manage {
    my ($self) = @_;
    my $u = C4::Context->userenv or return 0;
    return 1 if ($u->{flags} // 0) & 1;
    require C4::Auth;
    return C4::Auth::haspermission($u->{id}, { borrowers => 'edit_borrowers' }) ? 1 : 0;
}

sub _is_post { (shift->_cgi->request_method // '') eq 'POST' }

# ---- Tools page -------------------------------------------------------------

sub tool {
    my ($self) = @_;
    my $cgi = $self->_cgi;
    my $op  = $cgi->param('op') // '';

    return $self->_asset(scalar $cgi->param('asset')) if $op eq 'asset';
    return $self->_prefs_csv if $op eq 'prefs-csv';

    my %json_get = (
        data    => \&_op_data,
        smtp    => \&_op_smtp,
        cleanup => \&_op_cleanup,
        prefs   => \&_op_prefs,
        print   => \&_op_print,
    );
    my %json_post = (
        'cud-cleanup-apply' => \&_op_cleanup_apply,
        'cud-undo'          => \&_op_undo,
        'cud-prefs-switch'  => \&_op_prefs_switch,
        'cud-prefs-undo'    => \&_op_prefs_undo,
        'cud-print-clear'   => \&_op_print_clear,
        'cud-print-undo'    => \&_op_print_undo,
    );
    if (my $h = $json_get{$op}) {
        my $r = eval { $h->($self) };
        return $self->_json({ error => "$@" }, '500 Internal Server Error') if $@;
        return $self->_json($r);
    }
    if (my $h = $json_post{$op}) {
        return $self->_json({ error => 'POST required' }, '405 Method Not Allowed') unless $self->_is_post;
        return $self->_json({ error => 'You need permission to edit patrons to do this.' }, '403 Forbidden') unless $self->can_manage;
        my $r = eval { $h->($self) };
        return $self->_json({ error => "$@" }, '500 Internal Server Error') if $@;
        return $self->_json($r);
    }

    my $template = $self->get_template({ file => 'templates/dashboard.tt' });
    my $s = $self->settings;
    my ($from, $to, $letter) = $self->_range;
    $template->param(
        $self->_inline,
        from => $from, to => $to, letter => $letter // '',
        version    => $VERSION,
        tool_url   => $self->_url('tool'),
        config_url => $self->_url('configure'),
        can_manage => $self->can_manage,
        threshold  => $s->{threshold},
        lookback   => $s->{lookback_days},
        auto       => $s->{auto_cleanup},
        switch_on_clear => $s->{switch_on_clear},
        switch_to  => $s->{switch_to},
        today      => today(),
    );
    $self->output_html($template->output);
    return;
}

sub _slurp {
    my ($self, $file) = @_;
    open(my $fh, '<:raw', $self->mbf_path("static/$file")) or die "Cannot read $file: $!\n";
    local $/;
    my $body = <$fh>;
    close $fh;
    return $body;
}

sub _inline {
    my ($self) = @_;
    require Encode;
    return (
        pp_css  => Encode::decode('UTF-8', $self->_slurp('pigeon.css')),
        pp_logo => Encode::decode('UTF-8', $self->_slurp('pigeon.svg')),
    );
}

sub _asset {
    my ($self, $key) = @_;
    my $cgi = $self->_cgi;
    my $a = defined $key ? $ASSETS{$key} : undef;
    unless ($a) { print $cgi->header(-status => '404 Not Found', -type => 'text/plain'); print 'Not found'; return }
    my $body = eval { join "\n;\n", map { $self->_slurp($_) } @{ $a->{files} } };
    unless (defined $body) {
        print $cgi->header(-status => '500 Internal Server Error', -type => 'text/plain');
        print "Pigeon Post asset error: $@";
        return;
    }
    print $cgi->header(-type => $a->{type}, -charset => 'UTF-8', -cache_control => 'public, max-age=86400');
    print $body;
    return;
}

sub _range {
    my ($self) = @_;
    my $cgi = $self->_cgi;
    my ($from, $to) = parse_range(scalar $cgi->param('from'), scalar $cgi->param('to'));
    my $letter = $cgi->param('letter');
    $letter = undef unless defined $letter && $letter =~ /\A[\w.\-]{1,64}\z/;
    return ($from, $to, $letter);
}

sub _op_data {
    my ($self) = @_;
    my ($from, $to, $letter) = $self->_range;
    $self->_rollup;    # keeps totals correct even if the nightly cron isn't running
    my $stats = $self->_stats;
    my $sum = $stats->summary(from => $from, to => $to, letter => $letter);
    $sum->{rolled_through} = $self->retrieve_data('rolled_through');
    $sum->{failed_rows}    = $stats->failed_list(from => $from, to => $to, letter => $letter);
    return $sum;
}

sub _op_smtp {
    my ($self) = @_;
    my $refresh = $self->_cgi->param('refresh') ? 1 : 0;
    my $at      = $self->retrieve_data('smtp_cache_at') // 0;
    if (!$refresh && time - $at < $self->setting('smtp_cache_s')) {
        my $c = eval { JSON::decode_json($self->retrieve_data('smtp_cache')) };
        return { servers => $c, checked_at => $at, cached => 1 } if $c;
    }
    my $res = Koha::Plugin::Pro::Koha::PigeonPost::Smtp::check_all(timeout => 5);
    my $now = time;
    $self->store_data({ smtp_cache => JSON::encode_json($res), smtp_cache_at => $now });
    return { servers => $res, checked_at => $now, cached => 0 };
}

sub _candidates {
    my ($self) = @_;
    my $s = $self->settings;
    my $st = $self->_stats;
    return $self->_cleanup->candidates(
        threshold => $s->{threshold}, days => $s->{lookback_days}, fields => $s->{fields_list},
        has_failure_code => $st->has_failure_code,
    );
}

sub _op_cleanup {
    my ($self) = @_;
    die "You need permission to edit patrons to see cleanup candidates.\n" unless $self->can_manage;
    my $s = $self->settings;
    my $c = $self->_cleanup;
    return {
        candidates => $self->_candidates,
        health     => $c->recent_health,
        threshold  => $s->{threshold} + 0, lookback_days => $s->{lookback_days} + 0, fields => $s->{fields_list},
        log        => $c->log_entries(100),
        last_auto  => scalar eval { JSON->new->allow_nonref->decode($self->retrieve_data('last_auto_cleanup') // 'null') },
    };
}

sub _op_cleanup_apply {
    my ($self) = @_;
    my %want = map { $_ => 1 } grep { /\A\d+:\w+\z/ } $self->_cgi->multi_param('item');
    return { results => [], error => 'Nothing selected' } unless %want;
    # Never trust the client: only clear entries that are candidates right now.
    my @items = grep { $want{"$_->{borrowernumber}:$_->{field}"} } @{ $self->_candidates };
    return { results => $self->_cleanup->apply(\@items, $self->_staff, $self->_after_clear($self->_staff)) };
}

# After an address is cleared: if the patron is left with nothing Koha can email,
# move their email notices to print/SMS so they don't start failing with NO_EMAIL.
sub _after_clear {
    my ($self, $staff) = @_;
    return () unless $self->setting('switch_on_clear');
    my $prefs = $self->_prefs;
    my $mode  = $self->setting('switch_to');
    return (after => sub {
        my ($it, $log_id) = @_;
        my $r = $prefs->switch($it->{borrowernumber}, mode => $mode, staff => $staff, source => "cleanup:$log_id");
        return $r->{ok} && $r->{changed} ? { prefs_switched => $r->{changed}, prefs_summary => $r->{summary} } : {};
    });
}

sub _op_undo {
    my ($self) = @_;
    my $id = $self->_cgi->param('id') // '';
    return { ok => 0, error => 'Bad id' } unless $id =~ /\A\d+\z/;
    my $r = $self->_cleanup->undo($id, $self->_staff);
    if ($r->{ok}) {    # put back any notice preferences that clear switched
        my $p = eval { $self->_prefs->undo_source("cleanup:$id", $self->_staff) };
        $r->{prefs_restored} = $p ? scalar(grep { $_->{ok} } @$p) : 0;
        $r->{prefs_error} = "$@" if $@;
    }
    return $r;
}

sub _op_prefs {
    my ($self) = @_;
    die "You need permission to edit patrons to see this list.\n" unless $self->can_manage;
    my $p = $self->_prefs;
    return {
        total  => $p->count_missing,
        rows   => $p->missing(limit => 1000),
        fields => $p->{notice_fields},
        mode   => $self->setting('switch_to'),
        log    => $p->log_entries(100),
    };
}

sub _op_prefs_switch {
    my ($self) = @_;
    my $cgi  = $self->_cgi;
    my $mode = $cgi->param('mode') // '';
    $mode = $self->setting('switch_to') unless $Koha::Plugin::Pro::Koha::PigeonPost::Prefs::MODE_OK{$mode};
    my %seen;
    my @bns = grep { !$seen{$_}++ } grep { /\A\d+\z/ } $cgi->multi_param('item');
    return { results => [], error => 'Nothing selected' } unless @bns;
    my $p = $self->_prefs;
    my @res;
    for my $bn (@bns) {    # switch() re-checks that the patron still has no address
        my $r = eval { $p->switch($bn, mode => $mode, staff => $self->_staff, source => 'manual') } || { ok => 0, error => "$@" };
        $r->{error} =~ s/\s+$// if defined $r->{error};
        push @res, { borrowernumber => $bn, %$r };
    }
    return { results => \@res };
}

sub _op_prefs_undo {
    my ($self) = @_;
    my $id = $self->_cgi->param('id') // '';
    return { ok => 0, error => 'Bad id' } unless $id =~ /\A\d+\z/;
    return $self->_prefs->undo($id, $self->_staff);
}

sub _op_print {
    my ($self) = @_;
    die "You need permission to edit patrons to manage the print queue.\n" unless $self->can_manage;
    my $q = $self->_print;
    my $sum = $q->summary($self->setting('print_clear_days'));
    return { %$sum, auto => $self->setting('print_clear_auto') ? 1 : 0, log => $q->log_entries(50),
             last_auto => scalar eval { JSON->new->allow_nonref->decode($self->retrieve_data('last_print_clear') // 'null') } };
}

sub _op_print_clear {
    my ($self) = @_;
    # The age limit comes from the saved setting, never from the request.
    return $self->_print->clear($self->setting('print_clear_days'), staff => $self->_staff, source => 'manual');
}

sub _op_print_undo {
    my ($self) = @_;
    my $id = $self->_cgi->param('id') // '';
    return { ok => 0, error => 'Bad id' } unless $id =~ /\A\d+\z/;
    return $self->_print->undo($id, $self->_staff);
}

sub _prefs_csv {
    my ($self) = @_;
    my $cgi = $self->_cgi;
    unless ($self->can_manage) { print $cgi->header(-status => '403 Forbidden', -type => 'text/plain'); print 'You need permission to edit patrons.'; return }
    my $rows = $self->_prefs->missing(limit => 100000);
    require Encode;
    my $line = \&Koha::Plugin::Pro::Koha::PigeonPost::Prefs::csv_line;
    print $cgi->header(-type => 'text/csv', -charset => 'UTF-8', -cache_control => 'no-store',
        -attachment => 'patrons-email-preferred-no-address-' . today() . '.csv');
    print "\x{EF}\x{BB}\x{BF}";    # BOM so Excel reads UTF-8
    print Encode::encode('UTF-8', $line->('Card number', 'Name', 'Library', 'Category', 'Expires', 'SMS number', 'Notices set to email', 'Borrowernumber'));
    print Encode::encode('UTF-8', $line->(@$_{qw(cardnumber name branchcode categorycode dateexpiry smsalertnumber notices borrowernumber)})) for @$rows;
    return;
}

# ---- configure page ---------------------------------------------------------

sub configure {
    my ($self) = @_;
    my $cgi = $self->_cgi;
    my $op  = $cgi->param('op') // '';
    my (@errors, $saved, $digest_result);

    if ($self->_is_post && $op =~ /\Acud-/) {
        unless ($self->can_manage) {
            push @errors, 'You need permission to edit patrons to change Pigeon Post settings.';
        } elsif ($op eq 'cud-save') {
            my %n;
            for my $k (qw(threshold lookback_days auto_cap)) {
                my $v = $cgi->param($k) // '';
                if ($v =~ /\A\d+\z/ && $v >= 1 && $v <= 100000) { $n{$k} = $v } else { push @errors, "$k must be a positive whole number" }
            }
            my @f = grep { $Koha::Plugin::Pro::Koha::PigeonPost::Cleanup::FIELD_OK{$_} } $cgi->multi_param('fields');
            push @errors, 'Choose at least one patron email field' unless @f;
            $n{fields}         = join ',', @f;
            $n{auto_cleanup}   = $cgi->param('auto_cleanup') ? 1 : 0;
            $n{switch_on_clear} = $cgi->param('switch_on_clear') ? 1 : 0;
            my $sw = $cgi->param('switch_to') // '';
            if ($Koha::Plugin::Pro::Koha::PigeonPost::Prefs::MODE_OK{$sw}) { $n{switch_to} = $sw } else { push @errors, 'Pick where email notices should go' }
            $n{print_clear_auto} = $cgi->param('print_clear_auto') ? 1 : 0;
            my $pd = $cgi->param('print_clear_days') // '';
            if ($pd =~ /\A\d+\z/ && $pd >= 1 && $pd <= 3650) { $n{print_clear_days} = $pd } else { push @errors, 'Print notice age must be 1 to 3650 days' }
            $n{digest_enabled} = $cgi->param('digest_enabled') ? 1 : 0;
            my $wd = $cgi->param('digest_weekday') // '';
            if ($wd =~ /\A[0-6]\z/) { $n{digest_weekday} = $wd } else { push @errors, 'Pick a digest day' }
            my $raw = $cgi->param('digest_to') // '';
            my $rec = Koha::Plugin::Pro::Koha::PigeonPost::Digest::parse_recipients($raw);
            push @errors, 'Enter at least one valid digest email address' if $n{digest_enabled} && !@$rec;
            $n{digest_to} = join ', ', @$rec;
            unless (@errors) { $self->store_data(\%n); $saved = 1 }
        } elsif ($op eq 'cud-send-digest') {
            $digest_result = eval { $self->send_digest(force => 1) } || { ok => 0, error => "$@" };
        }
    }

    my $template = $self->get_template({ file => 'templates/configure.tt' });
    my $s = $self->settings;
    $template->param(
        $self->_inline,
        version => $VERSION, tool_url => $self->_url('tool'), config_url => $self->_url('configure'),
        s => $s, fields_selected => { map { $_ => 1 } @{ $s->{fields_list} } },
        errors => \@errors, saved => $saved, digest_result => $digest_result, can_manage => $self->can_manage,
    );
    $self->output_html($template->output);
    return;
}

# ---- digest & nightly -------------------------------------------------------

sub digest_data {
    my ($self, $today) = @_;
    $today //= today();
    $self->_rollup;
    my ($from, $to) = (add_days($today, -7), add_days($today, -1));
    my $stats = $self->_stats;
    my $sum   = $stats->summary(from => $from, to => $to, today => $today);
    my ($pf, $pt) = (add_days($today, -14), add_days($today, -8));
    my $prev = Koha::Plugin::Pro::Koha::PigeonPost::Stats::aggregate($stats->day_rows($pf, $pt, $today), $pf, $pt)->{totals};
    my $base = C4::Context->preference('staffClientBaseURL') // '';
    $base =~ s{/+$}{};
    return {
        from => $from, to => $to, week => $sum->{range}, prev => $prev,
        reasons => $sum->{reasons}, letters => $sum->{by_letter}, queue => $sum->{queue},
        cleared    => $self->_cleanup->cleared_between($from, $to),
        candidates => scalar @{ $self->_candidates },
        %{ $self->_digest_prefs($from, $to, $pf, $pt, $stats->has_failure_code) },
        print => scalar eval { my $q = $self->_print; +{ %{ $q->summary($self->setting('print_clear_days')) }, cleared => $q->cleared_between($from, $to) } },
        smtp       => Koha::Plugin::Pro::Koha::PigeonPost::Smtp::check_all(timeout => 5),
        dashboard_url => $base ? $base . $self->_url('tool') : undef,
        library    => C4::Context->preference('LibraryName'),
    };
}

sub _digest_prefs {
    my ($self, $from, $to, $pf, $pt, $has_fc) = @_;
    my $p = $self->_prefs;
    return eval {
        +{ no_address => $p->count_missing, prefs_switched => $p->switched_between($from, $to),
          no_email_week => $p->no_email_failures($from, $to, $has_fc), no_email_prev => $p->no_email_failures($pf, $pt, $has_fc) }
    } || {};
}

sub send_digest {
    my ($self, %o) = @_;
    my $rec = Koha::Plugin::Pro::Koha::PigeonPost::Digest::parse_recipients($self->setting('digest_to'));
    return { ok => 0, error => 'No digest recipients configured' } unless @$rec;
    my $ids = Koha::Plugin::Pro::Koha::PigeonPost::Digest::enqueue($self->digest_data, $rec);
    $self->store_data({ digest_last_sent => today() }) unless $o{force};
    return { ok => 1, queued => scalar(grep defined, @$ids), recipients => $rec };
}

sub run_auto_cleanup {
    my ($self) = @_;
    my $s = $self->settings;
    my $c = $self->_cleanup;
    my $result = { at => scalar(localtime), cleared => 0 };
    my $health = $c->recent_health;
    if ($health->{outage}) {
        $result->{skipped} = "Skipped: $health->{failed} of " . ($health->{sent} + $health->{failed}) . ' emails failed in the last 24 hours, which looks like an SMTP outage rather than bad addresses.';
    } else {
        my $cands = $self->_candidates;
        if (@$cands > $s->{auto_cap}) {
            $result->{skipped} = scalar(@$cands) . " addresses are over the threshold, more than the per-run cap of $s->{auto_cap}. Review them on the dashboard.";
        } elsif (@$cands) {
            my $res = $c->apply($cands, undef, $self->_after_clear(undef));
            $result->{cleared} = grep { $_->{ok} } @$res;
            $result->{errors}  = [ map { "$_->{address}: $_->{error}" } grep { !$_->{ok} } @$res ];
        }
    }
    $self->store_data({ last_auto_cleanup => JSON::encode_json($result) });
    return $result;
}

sub cronjob_nightly {
    my ($self) = @_;
    $self->_rollup;
    if ($self->setting('auto_cleanup')) {
        my $r = eval { $self->run_auto_cleanup } || { error => "$@" };
        print 'Pigeon Post auto-cleanup: ' . ($r->{skipped} // $r->{error} // "cleared $r->{cleared}") . "\n";
    }
    if ($self->setting('print_clear_auto')) {
        my $r = eval { $self->_print->clear($self->setting('print_clear_days'), source => 'auto') } || { ok => 0, error => "$@" };
        $self->store_data({ last_print_clear => JSON::encode_json({ at => scalar(localtime), %$r }) });
        print 'Pigeon Post print queue: ' . ($r->{ok} ? "cleared $r->{cleared} unprinted notice(s)" : "failed: $r->{error}") . "\n";
    }
    if ($self->setting('digest_enabled')
        && Koha::Plugin::Pro::Koha::PigeonPost::Digest::should_send(
            today => today(), weekday => $self->setting('digest_weekday'), last_sent => $self->retrieve_data('digest_last_sent')))
    {
        my $r = eval { $self->send_digest } || { ok => 0, error => "$@" };
        print 'Pigeon Post digest: ' . ($r->{ok} ? "queued for $r->{queued} recipient(s)" : "failed: $r->{error}") . "\n";
    }
    return 1;
}

1;
