package Koha::Plugin::Pro::Koha::PigeonPost::Digest;

# Weekly activity digest. build_html() is pure (styled per the koha.pro /
# RustSearch palette, inline styles for email clients) so it can be unit-tested.

use strict;
use warnings;
use Koha::Plugin::Pro::Koha::PigeonPost::Util qw(escape_html add_days wday_of days_between);

my %C = (navy => '#002f65', blue => '#07448f', ink => '#142033', muted => '#607086', line => '#d7e0eb',
         wash => '#f3f7fc', accent => '#7ec9ff', light => '#b7dfff', ok => '#16855c', warn => '#b28b37', bad => '#c8463d');

# Send on the configured weekday, at most once per 6 days.
sub should_send {
    my (%a) = @_;    # today, weekday (0-6), last_sent
    return 0 unless defined $a{weekday} && $a{weekday} =~ /^[0-6]$/;
    return 0 unless wday_of($a{today}) == $a{weekday};
    return 1 unless $a{last_sent};
    return days_between($a{last_sent}, $a{today}) - 1 >= 6 ? 1 : 0;
}

sub parse_recipients {
    my ($s) = @_;
    my %seen;
    return [ grep { !$seen{ lc $_ }++ } grep { /^[^@\s,;]+@[^@\s,;]+\.[^@\s,;]+$/ } split /[\s,;]+/, ($s // '') ];
}

sub _pct_change {
    my ($now, $prev) = @_;
    return 'new' if !$prev && $now;
    return '—'   if !$prev;
    my $p = 100 * ($now - $prev) / $prev;
    return sprintf('%s%.0f%%', $p >= 0 ? '+' : '', $p);
}

sub _fmt { my $n = shift // 0; 1 while $n =~ s/^(\d+)(\d{3})/$1,$2/; return $n }

# $d = { from, to, week => {sent, failed, failure_rate}, prev => {sent, failed},
#        reasons => [{code,n}], letters => [{letter_code,sent,failed}],
#        cleared, candidates, queue => {pending, oldest_age_minutes},
#        smtp => [{name, light, ms, message}], dashboard_url, library }
sub build_html {
    my ($d) = @_;
    my $e = \&escape_html;
    my $w = $d->{week} || {};
    my $p = $d->{prev} || {};
    my $card = "background:#fff;border:1px solid $C{line};border-radius:10px;padding:20px 22px;margin:0 0 16px";
    my $eyebrow = "font-size:10px;font-weight:700;letter-spacing:1.7px;text-transform:uppercase;color:$C{blue};margin:0 0 10px";

    my $kpi = sub {
        my ($label, $value, $sub) = @_;
        return qq{<td style="padding:6px 18px 6px 0;vertical-align:top"><div style="font-size:30px;font-weight:700;letter-spacing:-1px;color:$C{light}">}
             . $e->($value) . qq{</div><div style="font-size:11px;font-weight:600;color:#fff">} . $e->($label)
             . qq{</div><div style="font-size:10px;color:#c8d8ed">} . $e->($sub // '') . '</div></td>';
    };

    my $rows = sub {
        my ($items, $render) = @_;
        return qq{<p style="color:$C{muted};font-size:13px;margin:0">Nothing to report.</p>} unless $items && @$items;
        return '<table role="presentation" width="100%" style="border-collapse:collapse;font-size:13px">'
             . join('', map { $render->($_) } @$items) . '</table>';
    };
    my $tr = sub { my ($l, $r) = @_; qq{<tr><td style="padding:6px 0;border-bottom:1px solid $C{line};color:$C{ink}">$l</td><td align="right" style="padding:6px 0;border-bottom:1px solid $C{line};color:$C{navy};font-weight:600">$r</td></tr>} };

    my %light = (green => $C{ok}, amber => $C{warn}, red => $C{bad});
    my %word  = (green => 'UP', amber => 'SLOW', red => 'DOWN');
    my $smtp = $rows->($d->{smtp}, sub {
        my $s = shift;
        my $col = $light{ $s->{light} } // $C{muted};
        $tr->(qq{<span style="display:inline-block;width:8px;height:8px;border-radius:50%;background:$col"></span>&nbsp; } . $e->($s->{name}),
              qq{<span style="color:$col">} . ($word{ $s->{light} } // '?') . '</span>' . (defined $s->{ms} ? " <span style=\"color:$C{muted};font-weight:400\">$s->{ms} ms</span>" : ''));
    });

    my $q = $d->{queue} || {};
    my $age = defined $q->{oldest_age_minutes} ? ($q->{oldest_age_minutes} >= 120 ? sprintf('%.1f h', $q->{oldest_age_minutes} / 60) : "$q->{oldest_age_minutes} min") : '—';
    my $stuck = defined $q->{oldest_age_minutes} && $q->{oldest_age_minutes} > 60;

    my $html = qq{<!doctype html><html><body style="margin:0;background:$C{wash};font-family:Inter,ui-sans-serif,system-ui,-apple-system,'Segoe UI',sans-serif;color:$C{ink}">
<table role="presentation" width="100%" style="border-collapse:collapse"><tr><td align="center" style="padding:0">
<table role="presentation" width="640" style="max-width:640px;width:100%;border-collapse:collapse">
<tr><td style="background:$C{navy};padding:22px 26px;color:#fff">
<div style="font-size:24px;font-weight:800;letter-spacing:-1px">Pigeon <span style="color:$C{accent}">Post</span></div>
<div style="font-size:10px;font-weight:700;letter-spacing:1.7px;text-transform:uppercase;color:#8fc8ff;margin-top:4px">Weekly email digest · } . $e->("$d->{from} – $d->{to}") . qq{</div>
<table role="presentation" style="margin-top:16px;border-collapse:collapse"><tr>}
        . $kpi->('Sent', _fmt($w->{sent}), _pct_change($w->{sent} // 0, $p->{sent}) . ' vs last week')
        . $kpi->('Failed', _fmt($w->{failed}), _pct_change($w->{failed} // 0, $p->{failed}) . ' vs last week')
        . $kpi->('Failure rate', ($w->{failure_rate} // 0) . '%', '')
        . $kpi->('Backlog', _fmt($q->{pending}), "oldest $age")
        . qq{</tr></table></td></tr>
<tr><td style="padding:22px 26px 6px">}
        . ($stuck ? qq{<div style="border:1px solid #d7b76f;background:#fff8e9;border-radius:10px;padding:14px 18px;margin:0 0 16px;font-size:13px"><b style="color:$C{warn}">Queue may be stuck.</b> The oldest pending email has waited $age. Check that process_message_queue.pl is running.</div>} : '')
        . qq{<div style="$card"><p style="$eyebrow">SMTP status</p>$smtp</div>}
        . qq{<div style="$card"><p style="$eyebrow">Top failure reasons</p>} . $rows->([ @{ $d->{reasons} || [] }[ 0 .. 4 ] ], sub { my $r = shift; defined $r ? $tr->($e->($r->{code}), _fmt($r->{n})) : '' }) . '</div>'
        . qq{<div style="$card"><p style="$eyebrow">Busiest notice types</p>} . $rows->([ @{ $d->{letters} || [] }[ 0 .. 4 ] ], sub { my $r = shift; defined $r ? $tr->($e->($r->{letter_code}), _fmt($r->{sent}) . ' sent' . ($r->{failed} ? " · <span style=\"color:$C{bad}\">" . _fmt($r->{failed}) . ' failed</span>' : '')) : '' }) . '</div>'
        . qq{<div style="$card"><p style="$eyebrow">Invalid address cleanup</p><table role="presentation" width="100%" style="border-collapse:collapse;font-size:13px">}
        . $tr->('Addresses cleared this week', _fmt($d->{cleared}))
        . $tr->('Addresses currently over the failure threshold', _fmt($d->{candidates}))
        . '</table></div>'
        . ($d->{dashboard_url} ? qq{<p style="margin:6px 0 22px"><a href="} . $e->($d->{dashboard_url}) . qq{" style="display:inline-block;background:$C{blue};color:#fff;text-decoration:none;font-weight:650;font-size:13px;border-radius:5px;padding:12px 18px">Open the Pigeon Post Dashboard</a></p>} : '')
        . qq{</td></tr>
<tr><td style="padding:14px 26px 26px;font-size:10px;color:$C{muted};border-top:1px solid $C{line}">Sent by the Pigeon Post plugin for } . $e->($d->{library} // 'Koha') . qq{ · koha.pro</td></tr>
</table></td></tr></table></body></html>};
    return $html;
}

sub subject {
    my ($d) = @_;
    my $w = $d->{week} || {};
    return sprintf('Pigeon Post weekly digest: %s sent, %s failed (%s – %s)', _fmt($w->{sent}), _fmt($w->{failed}), $d->{from}, $d->{to});
}

sub enqueue {
    my ($d, $recipients) = @_;
    require C4::Letters;
    require C4::Context;
    my $from = C4::Context->preference('KohaAdminEmailAddress');
    my $html = build_html($d);
    my @ids;
    for my $to (@$recipients) {
        push @ids, C4::Letters::EnqueueLetter({
            letter => { title => subject($d), content => $html, 'content-type' => 'text/html; charset="UTF-8"', is_html => 1, code => 'PIGEON_DIGEST' },
            message_transport_type => 'email',
            to_address             => $to,
            ($from ? (from_address => $from) : ()),
        });
    }
    return \@ids;
}

1;
