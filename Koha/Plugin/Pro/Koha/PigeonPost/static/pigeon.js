/* Pigeon Post dashboard. Plain JS + Chart.js 4 (bundled). */
(function () {
  'use strict';
  var root = document.getElementById('pigeon');
  if (!root) return;

  var TOOL = root.dataset.toolUrl;
  var CLASS = root.dataset['class'];
  var CAN_MANAGE = root.dataset.canManage === '1';
  var TODAY = root.dataset.today;
  var C = { navy: '#002f65', blue: '#07448f', muted: '#607086', line: '#edf2f8', bad: '#c8463d',
            series: ['#07448f', '#c8463d', '#b6cde6', '#7ec9ff', '#002f65', '#607086', '#d7b76f', '#16855c'] };
  var state = { from: root.dataset.from || null, to: root.dataset.to || null, letter: root.dataset.letter || '' };
  var charts = {};

  // The script is running, so take down the "script blocked?" notice.
  var boot = document.getElementById('pp-boot');
  if (boot) boot.hidden = true;
  if (!window.Chart) showError('The chart library did not load, so charts are hidden. The numbers and tables still work.');

  function showError(msg) {
    var box = document.getElementById('pp-error');
    if (!box) return;
    var line = document.createElement('div');
    line.textContent = msg;
    if (!box.firstChild) { var b = document.createElement('b'); b.textContent = 'Something went wrong. '; box.appendChild(b); }
    box.appendChild(line);
    box.hidden = false;
  }

  // ---------- helpers ----------
  function $(id) { return document.getElementById(id); }
  function el(tag, attrs, kids) {
    var e = document.createElement(tag);
    if (attrs) Object.keys(attrs).forEach(function (k) {
      if (k === 'text') e.textContent = attrs[k];
      else if (k === 'class') e.className = attrs[k];
      else e.setAttribute(k, attrs[k]);
    });
    (kids || []).forEach(function (c) { if (c != null) e.appendChild(typeof c === 'string' ? document.createTextNode(c) : c); });
    return e;
  }
  function fmt(n) { return n == null ? '—' : Number(n).toLocaleString(); }
  function addDays(d, n) {
    var p = d.split('-'); var t = Date.UTC(+p[0], +p[1] - 1, +p[2]) + n * 864e5;
    return new Date(t).toISOString().slice(0, 10);
  }
  function shortDay(d) {
    var p = d.split('-');
    return new Date(Date.UTC(+p[0], +p[1] - 1, +p[2])).toLocaleDateString(undefined, { month: 'short', day: 'numeric', timeZone: 'UTC' });
  }
  function ageText(min) {
    if (min == null) return 'nothing waiting';
    if (min < 60) return 'oldest waiting ' + min + ' min';
    if (min < 2880) return 'oldest waiting ' + (min / 60).toFixed(1) + ' h';
    return 'oldest waiting ' + Math.round(min / 1440) + ' days';
  }
  // Turn any response into data or a readable error. A proxy/WAF (e.g. BunkerWeb)
  // answers with its own HTML page, so a non-JSON reply is reported by status.
  function readJSON(r) {
    return r.text().then(function (t) {
      var j = null;
      try { j = JSON.parse(t); } catch (e) { /* not JSON */ }
      if (j && r.ok) return j;
      var why = j && j.error ? j.error
        : 'HTTP ' + r.status + (r.statusText ? ' ' + r.statusText : '') +
          (r.status === 403 ? ': blocked (a firewall or a missing permission)'
            : r.status === 429 ? ': too many requests (rate limited by a proxy or firewall)'
            : r.status >= 500 ? ': server error (see Koha\'s plack-intranet-error.log)'
            : !j ? ': the reply was not dashboard data (possibly a proxy or login page)' : '');
      throw new Error(why.replace(/\s+$/, ''));
    });
  }
  function getJSON(op, params) {
    var q = new URLSearchParams(params || {});
    return fetch(TOOL + '&op=' + encodeURIComponent(op) + '&' + q.toString(), { credentials: 'same-origin', headers: { Accept: 'application/json' } })
      .then(readJSON);
  }
  function csrfToken() {
    var i = document.querySelector('#pp-csrf input[name="csrf_token"]');
    if (i) return i.value;
    var m = document.querySelector('meta[name="csrf-token"]');
    return m ? m.getAttribute('content') : '';
  }
  function postJSON(op, pairs) {
    var body = new URLSearchParams();
    body.append('class', CLASS); body.append('method', 'tool'); body.append('op', op);
    var tok = csrfToken(); if (tok) body.append('csrf_token', tok);
    (pairs || []).forEach(function (p) { body.append(p[0], p[1]); });
    return fetch('/cgi-bin/koha/plugins/run.pl', { method: 'POST', credentials: 'same-origin', body: body, headers: { Accept: 'application/json' } })
      .then(readJSON);
  }

  if (window.Chart) {
    Chart.defaults.font.family = 'Inter, ui-sans-serif, system-ui, -apple-system, "Segoe UI", sans-serif';
    Chart.defaults.font.size = 11;
    Chart.defaults.color = C.muted;
    Chart.defaults.plugins.legend.display = false;
    Chart.defaults.maintainAspectRatio = false;
  }
  function chart(id, cfg) {
    if (!window.Chart) return;
    if (charts[id]) charts[id].destroy();
    charts[id] = new Chart($(id), cfg);
  }
  var grid = { color: C.line, drawTicks: false };
  var noGrid = { display: false };

  // ---------- range ----------
  function setRange(from, to) {
    state.from = from; state.to = to;
    $('pp-from').value = from; $('pp-to').value = to;
  }
  function preset(p) {
    if (p === 'ytd') return setRange(TODAY.slice(0, 4) + '-01-01', TODAY);
    setRange(addDays(TODAY, -(+p - 1)), TODAY);
  }
  root.querySelectorAll('[data-preset]').forEach(function (b) {
    b.addEventListener('click', function () {
      root.querySelectorAll('[data-preset]').forEach(function (x) { x.classList.toggle('is-active', x === b); });
      preset(b.dataset.preset); loadAll();
    });
  });
  $('pp-range').addEventListener('submit', function (e) {
    e.preventDefault();
    var f = $('pp-from').value, t = $('pp-to').value;
    if (f && t) setRange(f <= t ? f : t, f <= t ? t : f);
    state.letter = $('pp-letter').value;
    root.querySelectorAll('[data-preset]').forEach(function (x) { x.classList.remove('is-active'); });
    try {   // keep the range in the address bar so reloads and bookmarks keep it
      var u = new URL(location.href);
      u.searchParams.set('from', state.from); u.searchParams.set('to', state.to);
      if (state.letter) u.searchParams.set('letter', state.letter); else u.searchParams.delete('letter');
      history.replaceState(null, '', u.toString());
    } catch (err) { /* old browser: fine */ }
    loadAll();
  });

  // ---------- summary ----------
  function renderSummary(d) {
    $('kpi-lifetime').textContent = fmt(d.lifetime.sent);
    $('kpi-lifetime-sub').textContent = d.lifetime.since ? 'since ' + d.lifetime.since : 'no history yet';
    $('kpi-sent').textContent = fmt(d.range.sent);
    $('kpi-range-label').textContent = shortDay(d.from) + ' – ' + shortDay(d.to) + (d.letter ? ' · ' + d.letter : '');
    $('kpi-failed').textContent = fmt(d.range.failed);
    $('kpi-lifetime-failed').textContent = fmt(d.lifetime.failed) + ' failed all time';
    $('kpi-rate').textContent = (d.range.failure_rate || 0) + '%';
    $('kpi-pending').textContent = fmt(d.queue.pending);
    $('kpi-oldest').textContent = ageText(d.queue.oldest_age_minutes);

    var w = $('pp-queue-warning');
    if (d.queue.oldest_age_minutes != null && d.queue.oldest_age_minutes > 60) {
      w.innerHTML = '';
      w.appendChild(el('b', { text: 'The email queue may be stuck. ' }));
      w.appendChild(document.createTextNode('The oldest waiting email was queued ' + ageText(d.queue.oldest_age_minutes).replace('oldest waiting ', '') +
        ' ago. Check that Koha\'s process_message_queue.pl cron job is running.'));
      w.hidden = false;
    } else w.hidden = true;

    // notice-type filter options
    var sel = $('pp-letter'), cur = state.letter;
    if (sel.options.length <= 1 && d.letter_codes) {
      d.letter_codes.forEach(function (c) { sel.appendChild(el('option', { value: c, text: c })); });
      sel.value = cur;
    }

    var note = $('pp-history-note');
    if (d.retained_from) {
      note.textContent = 'Daily totals and the all-time count include history Pigeon Post saved before Koha purged it. ' +
        'Failure reasons, hours of day and the failed-address list come from emails Koha still keeps (from ' + d.retained_from + ').';
      note.hidden = false;
    }

    var labels = d.series.map(function (s) { return shortDay(s.day); });
    chart('chart-daily', {
      type: 'line',
      data: { labels: labels, datasets: [
        { label: 'Sent', data: d.series.map(function (s) { return s.sent; }), borderColor: C.blue, backgroundColor: '#07448f1a',
          fill: true, tension: .25, pointRadius: d.series.length > 60 ? 0 : 2, borderWidth: 2 },
        { label: 'Failed', data: d.series.map(function (s) { return s.failed; }), borderColor: C.bad, backgroundColor: '#c8463d14',
          fill: true, tension: .25, pointRadius: d.series.length > 60 ? 0 : 2, borderWidth: 2 } ] },
      options: { interaction: { mode: 'index', intersect: false },
        scales: { x: { grid: noGrid, ticks: { maxTicksLimit: 10, maxRotation: 0 } }, y: { beginAtZero: true, grid: grid, border: { display: false }, ticks: { precision: 0 } } },
        plugins: { tooltip: { backgroundColor: C.navy } } }
    });

    var reasons = d.reasons || [];
    $('reasons-empty').hidden = reasons.length > 0;
    $('chart-reasons').parentNode.hidden = reasons.length === 0;
    if (reasons.length) chart('chart-reasons', {
      type: 'doughnut',
      data: { labels: reasons.map(function (r) { return r.code; }),
        datasets: [{ data: reasons.map(function (r) { return r.n; }), backgroundColor: C.series.slice(1).concat(C.series), borderWidth: 2, borderColor: '#fff' }] },
      options: { cutout: '62%', plugins: { legend: { display: true, position: 'right', labels: { boxWidth: 10, boxHeight: 10 } }, tooltip: { backgroundColor: C.navy } } }
    });

    var bars = $('pp-letters'); bars.innerHTML = '';
    var top = d.by_letter || [];
    var max = top.reduce(function (m, r) { return Math.max(m, r.sent + r.failed); }, 0) || 1;
    if (!top.length) bars.appendChild(el('p', { class: 'pp-empty', text: 'No emails in this range.' }));
    top.forEach(function (r) {
      var tot = r.sent + r.failed;
      var track = el('div', { class: 'pp-bar-track', title: fmt(r.sent) + ' sent, ' + fmt(r.failed) + ' failed' }, [
        el('div', { class: 'pp-bar-fill', style: 'width:' + (100 * r.sent / max).toFixed(2) + '%' }),
        r.failed ? el('div', { class: 'pp-bar-fail', style: 'width:' + (100 * r.failed / max).toFixed(2) + '%' }) : null ]);
      bars.appendChild(el('div', { class: 'pp-bar-row' }, [
        el('span', { class: 'pp-bar-label', text: r.letter_code, title: r.letter_code }), track,
        el('span', { class: 'pp-bar-number', text: fmt(tot) }) ]));
    });

    chart('chart-hours', {
      type: 'bar',
      data: { labels: d.by_hour.map(function (h) { return (h.hour < 10 ? '0' : '') + h.hour; }), datasets: [
        { label: 'Sent', data: d.by_hour.map(function (h) { return h.sent; }), backgroundColor: C.blue, borderRadius: 2, stack: 's' },
        { label: 'Failed', data: d.by_hour.map(function (h) { return h.failed; }), backgroundColor: C.bad, borderRadius: 2, stack: 's' } ] },
      options: { scales: { x: { stacked: true, grid: noGrid, ticks: { maxRotation: 0, autoSkip: true, maxTicksLimit: 12 } },
        y: { stacked: true, beginAtZero: true, grid: grid, border: { display: false }, ticks: { precision: 0 } } },
        plugins: { tooltip: { backgroundColor: C.navy, callbacks: { title: function (i) { return i[0].label + ':00'; } } } } }
    });
  }

  // ---------- failed table ----------
  var failedRows = [], sortKey = 'failures', sortDir = -1;
  function renderFailed() {
    var tb = $('pp-failed').querySelector('tbody'); tb.innerHTML = '';
    var q = ($('pp-failed-filter').value || '').toLowerCase();
    var rows = failedRows.filter(function (r) {
      return !q || (r.address || '').toLowerCase().indexOf(q) >= 0 || (r.patron || '').toLowerCase().indexOf(q) >= 0;
    }).sort(function (a, b) {
      var x = a[sortKey], y = b[sortKey];
      if (sortKey === 'failures') { x = +x; y = +y; } else { x = (x || '').toString(); y = (y || '').toString(); }
      return x < y ? -sortDir : x > y ? sortDir : 0;
    });
    if (!rows.length) tb.appendChild(el('tr', null, [el('td', { colspan: 5, class: 'pp-muted', text: q ? 'No matches.' : 'No failed deliveries in this range.' })]));
    rows.forEach(function (r) {
      var patron = r.borrowernumber
        ? el('a', { href: '/cgi-bin/koha/members/moremember.pl?borrowernumber=' + encodeURIComponent(r.borrowernumber), text: (r.patron || '').trim() || '#' + r.borrowernumber })
        : el('span', { class: 'pp-muted', text: '—' });
      tb.appendChild(el('tr', null, [
        el('td', { text: r.address || '(no address)' }), el('td', null, [patron]),
        el('td', { class: 'num', text: fmt(r.failures) }),
        el('td', null, [r.last_code ? el('span', { class: 'pp-code', text: r.last_code }) : el('span', { class: 'pp-muted', text: '—' })]),
        el('td', { text: r.last_failed || '' }) ]));
    });
    $('pp-failed-count').textContent = rows.length + ' address' + (rows.length === 1 ? '' : 'es') + (failedRows.length >= 500 ? ' (showing the 500 with the most failures)' : '');
  }
  $('pp-failed-filter').addEventListener('input', renderFailed);
  $('pp-failed').querySelectorAll('th[data-sort]').forEach(function (th) {
    th.addEventListener('click', function () {
      var k = th.dataset.sort;
      sortDir = sortKey === k ? -sortDir : (k === 'failures' || k === 'last_failed' ? -1 : 1);
      sortKey = k;
      $('pp-failed').querySelectorAll('th').forEach(function (x) { x.classList.remove('sorted-asc', 'sorted-desc'); });
      th.classList.add(sortDir > 0 ? 'sorted-asc' : 'sorted-desc');
      renderFailed();
    });
  });

  // ---------- SMTP ----------
  var WORD = { green: 'UP', amber: 'SLOW', red: 'DOWN' };
  function loadSmtp(refresh) {
    var btn = $('pp-smtp-refresh'); btn.disabled = true; btn.textContent = 'Checking…';
    return getJSON('smtp', refresh ? { refresh: 1 } : {}).then(function (d) {
      var ul = $('pp-smtp-list'); ul.innerHTML = '';
      if (!d.servers.length) ul.appendChild(el('li', { class: 'pp-muted', text: 'No SMTP servers configured.' }));
      d.servers.forEach(function (s) {
        var desc = (s.host || '') + (s.port ? ':' + s.port : '') + (s.ssl_mode && s.ssl_mode !== 'disabled' ? ' · ' + s.ssl_mode.toUpperCase() : '') + (s.is_default ? ' · default' : '');
        ul.appendChild(el('li', null, [
          el('span', { class: 'pp-light ' + s.light, role: 'img', 'aria-label': WORD[s.light] || 'unknown' }),
          el('span', { class: 'pp-light-name' }, [s.name || s.host, el('small', { text: desc })]),
          el('span', { class: 'pp-light-state ' + s.light, text: (WORD[s.light] || '?') + (s.ms != null ? ' · ' + s.ms + ' ms' : '') }),
          s.light !== 'green' && s.message ? el('span', { class: 'pp-light-msg', text: s.message }) : null ]));
      });
      $('pp-smtp-at').textContent = 'Checked ' + new Date(d.checked_at * 1000).toLocaleTimeString() + (d.cached ? ' (saved result, under a minute old)' : '') +
        '. Green means the server answered, amber means it was slow or TLS failed, and red means it is unreachable.';
    }).catch(function (e) {
      $('pp-smtp-list').innerHTML = ''; $('pp-smtp-list').appendChild(el('li', { class: 'pp-muted', text: 'Could not check: ' + e.message }));
      showError('SMTP check: ' + e.message);
    }).then(function () { btn.disabled = false; btn.textContent = 'Check now'; });
  }
  $('pp-smtp-refresh').addEventListener('click', function () { loadSmtp(true); });

  // ---------- cleanup ----------
  function loadCleanup() {
    if (!CAN_MANAGE || !$('pp-cleanup')) return Promise.resolve();
    return getJSON('cleanup').then(function (d) {
      renderLog(d);
      var tb = $('pp-candidates').querySelector('tbody'); tb.innerHTML = '';
      var h = $('pp-health');
      if (d.health && d.health.outage) {
        h.innerHTML = ''; h.appendChild(el('b', { text: 'Possible mail server problem. ' }));
        h.appendChild(document.createTextNode(fmt(d.health.failed) + ' of ' + fmt(d.health.sent + d.health.failed) +
          ' emails failed in the last 24 hours. That usually means SMTP is down, not that the addresses are bad. Check the SMTP status before clearing anything. Automatic cleanup is paused until this improves.'));
        h.hidden = false;
      } else h.hidden = true;
      if (!d.candidates.length) tb.appendChild(el('tr', null, [el('td', { colspan: 7, class: 'pp-muted', text: 'No addresses are over the threshold right now.' })]));
      d.candidates.forEach(function (c) {
        tb.appendChild(el('tr', null, [
          el('td', { class: 'pp-check' }, [el('input', { type: 'checkbox', class: 'pp-cand', value: c.borrowernumber + ':' + c.field, 'aria-label': 'Select ' + c.address })]),
          el('td', null, [el('a', { href: '/cgi-bin/koha/members/moremember.pl?borrowernumber=' + encodeURIComponent(c.borrowernumber), text: (c.name || '').trim() || c.cardnumber || '#' + c.borrowernumber })]),
          el('td', { text: { email: 'Primary', emailpro: 'Secondary', B_email: 'Alternate' }[c.field] || c.field }),
          el('td', { text: c.address }), el('td', { class: 'num', text: fmt(c.fails) }),
          el('td', null, [c.last_code ? el('span', { class: 'pp-code', text: c.last_code }) : el('span', { class: 'pp-muted', text: '—' })]),
          el('td', { text: c.last_time || '' }) ]));
      });
      $('pp-check-all').checked = false; updateClearButton();
    }).catch(function (e) {
      var tb = $('pp-candidates').querySelector('tbody'); tb.innerHTML = '';
      tb.appendChild(el('tr', null, [el('td', { colspan: 7, class: 'pp-muted', text: 'Could not load: ' + e.message })]));
      var lb = $('pp-log').querySelector('tbody'); lb.innerHTML = '';
      lb.appendChild(el('tr', null, [el('td', { colspan: 7, class: 'pp-muted', text: 'Could not load: ' + e.message })]));
      showError('Cleanup list: ' + e.message);
    });
  }
  function selected() { return Array.prototype.map.call(root.querySelectorAll('.pp-cand:checked'), function (c) { return c.value; }); }
  function updateClearButton() { var n = selected().length; $('pp-clear').disabled = !n; $('pp-clear').textContent = n ? 'Clear ' + n + ' selected' : 'Clear selected addresses'; }
  if ($('pp-cleanup')) {
    $('pp-candidates').addEventListener('change', function (e) {
      if (e.target.id === 'pp-check-all') root.querySelectorAll('.pp-cand').forEach(function (c) { c.checked = e.target.checked; });
      updateClearButton();
    });
    $('pp-clear').addEventListener('click', function () {
      var n = selected().length;
      $('pp-clear-confirm').querySelector('.pp-confirm-text').textContent = 'Clear ' + n + ' email address' + (n === 1 ? '' : 'es') + ' from patron records?';
      $('pp-clear-confirm').hidden = false; $('pp-clear').hidden = true;
    });
    $('pp-clear-no').addEventListener('click', function () { $('pp-clear-confirm').hidden = true; $('pp-clear').hidden = false; });
    $('pp-clear-yes').addEventListener('click', function () {
      var items = selected();
      $('pp-clear-yes').disabled = true; $('pp-clear-msg').textContent = 'Clearing…';
      postJSON('cud-cleanup-apply', items.map(function (i) { return ['item', i]; })).then(function (d) {
        var ok = d.results.filter(function (r) { return r.ok; }).length;
        var bad = d.results.filter(function (r) { return !r.ok; });
        var moved = d.results.filter(function (r) { return r.prefs_switched; }).length;
        $('pp-clear-msg').textContent = 'Cleared ' + ok + '.' + (moved ? ' Moved the email notices of ' + moved + ' patron' + (moved === 1 ? '' : 's') + ' left with no address.' : '') + (bad.length ? ' Skipped ' + bad.length + ': ' + bad.map(function (r) { return r.address + ' (' + r.error + ')'; }).join('; ') : '') +
          (items.length > d.results.length ? ' Some selections were no longer over the threshold and were left alone.' : '');
      }).catch(function (e) { $('pp-clear-msg').textContent = 'Failed: ' + e.message; })
        .then(function () { $('pp-clear-yes').disabled = false; $('pp-clear-confirm').hidden = true; $('pp-clear').hidden = false; loadCleanup().then(loadPrefs); });
    });
  }
  function renderLog(d) {
    (function () {
      var tb = $('pp-log').querySelector('tbody'); tb.innerHTML = '';
      var la = d.last_auto;
      $('pp-last-auto').textContent = la ? 'Last automatic run ' + la.at + ': ' + (la.skipped || ('cleared ' + la.cleared + '.')) : '';
      if (!d.log.length) tb.appendChild(el('tr', null, [el('td', { colspan: 7, class: 'pp-muted', text: 'Nothing has been cleared yet.' })]));
      d.log.forEach(function (r) {
        var undo = r.undone_at ? el('span', { class: 'pp-muted', text: 'Undone ' + r.undone_at })
          : el('button', { type: 'button', class: 'pp-button pp-secondary pp-small', 'data-undo': r.id, text: 'Undo' });
        var tr = el('tr', { class: r.undone_at ? 'is-undone' : '' }, [
          el('td', { text: r.cleared_at }),
          el('td', null, [el('a', { href: '/cgi-bin/koha/members/moremember.pl?borrowernumber=' + encodeURIComponent(r.borrowernumber), text: (r.name || '').trim() || '#' + r.borrowernumber })]),
          el('td', { text: r.field }), el('td', { text: r.old_address }), el('td', { class: 'num', text: fmt(r.failures) }),
          el('td', { text: r.cleared_by ? (r.cleared_by_name || '#' + r.cleared_by) : 'Automatic' }) ]);
        tr.appendChild(el('td', null, [undo]));
        tb.appendChild(tr);
      });
    })();
  }
  if ($('pp-log')) $('pp-log').addEventListener('click', function (e) {
    var id = e.target.getAttribute && e.target.getAttribute('data-undo');
    if (!id) return;
    e.target.disabled = true; e.target.textContent = 'Restoring…';
    postJSON('cud-undo', [['id', id]]).then(function (d) {
      if (!d.ok) { e.target.textContent = d.error; return; }
      loadCleanup().then(loadPrefs);
    }).catch(function (err) { e.target.textContent = err.message; });
  });

  // ---------- email preferred, no address ----------
  function patronLink(bn, name, card) {
    return el('a', { href: '/cgi-bin/koha/members/moremember.pl?borrowernumber=' + encodeURIComponent(bn), text: (name || '').trim() || card || '#' + bn });
  }
  function loadPrefs() {
    if (!CAN_MANAGE || !$('pp-prefs')) return Promise.resolve();
    return getJSON('prefs').then(function (d) {
      $('pp-prefs-total').textContent = fmt(d.total);
      if (d.mode) $('pp-prefs-mode').value = d.mode;
      $('pp-prefs-fields').textContent = d.fields && d.fields.length < 3
        ? 'Following your EmailFieldPrimary setting, only ' + d.fields.join(', ') + ' counts as an address.' : '';
      var tb = $('pp-prefs-table').querySelector('tbody'); tb.innerHTML = '';
      if (!d.rows.length) tb.appendChild(el('tr', null, [el('td', { colspan: 7, class: 'pp-muted', text: 'Every patron set to get email notices has an address. Nice.' })]));
      d.rows.forEach(function (r) {
        var expired = r.dateexpiry && r.dateexpiry < TODAY;
        tb.appendChild(el('tr', null, [
          el('td', { class: 'pp-check' }, [el('input', { type: 'checkbox', class: 'pp-pref', value: r.borrowernumber, 'aria-label': 'Select ' + ((r.name || '').trim() || r.cardnumber) })]),
          el('td', null, [patronLink(r.borrowernumber, r.name, r.cardnumber), r.cardnumber ? el('div', { class: 'pp-muted', text: r.cardnumber }) : null]),
          el('td', { text: r.branchcode || '' }), el('td', { text: r.categorycode || '' }),
          el('td', null, [r.dateexpiry ? el('span', { class: expired ? 'pp-tag is-expired' : '', text: expired ? 'Expired ' + r.dateexpiry : r.dateexpiry }) : el('span', { class: 'pp-muted', text: '—' })]),
          el('td', { text: (r.smsalertnumber || '').trim() || '—' }),
          el('td', { text: r.notices || '' }) ]));
      });
      $('pp-prefs-all').checked = false; updatePrefsButton();
      var foot = d.total > d.rows.length ? 'Showing the first ' + fmt(d.rows.length) + ' of ' + fmt(d.total) + '. The CSV has all of them.' : '';
      $('pp-prefs-msg').textContent = foot;
      renderPrefsLog(d.log || []);
    }).catch(function (e) {
      var tb = $('pp-prefs-table').querySelector('tbody'); tb.innerHTML = '';
      tb.appendChild(el('tr', null, [el('td', { colspan: 7, class: 'pp-muted', text: 'Could not load: ' + e.message })]));
      showError('Patrons without an address: ' + e.message);
    });
  }
  var WHY = { manual: 'Switched by hand' };
  function renderPrefsLog(rows) {
    var tb = $('pp-prefs-log').querySelector('tbody'); tb.innerHTML = '';
    if (!rows.length) tb.appendChild(el('tr', null, [el('td', { colspan: 6, class: 'pp-muted', text: 'No preferences have been changed yet.' })]));
    rows.forEach(function (r) {
      var why = WHY[r.source] || (/^cleanup:/.test(r.source || '') ? 'Address was cleared' : (r.source || ''));
      tb.appendChild(el('tr', { class: r.undone_at ? 'is-undone' : '' }, [
        el('td', { text: r.changed_at }),
        el('td', null, [patronLink(r.borrowernumber, r.name, r.cardnumber)]),
        el('td', { text: fmt(r.notices) + ' notice' + (r.notices == 1 ? '' : 's') + ': ' + (r.summary || '') }),
        el('td', { text: why }),
        el('td', { text: r.changed_by ? (r.changed_by_name || '#' + r.changed_by) : 'Automatic' }),
        el('td', null, [r.undone_at ? el('span', { class: 'pp-muted', text: 'Undone ' + r.undone_at })
          : el('button', { type: 'button', class: 'pp-button pp-secondary pp-small', 'data-prefs-undo': r.id, text: 'Undo' })]) ]));
    });
  }
  function prefsSelected() { return Array.prototype.map.call(root.querySelectorAll('.pp-pref:checked'), function (c) { return c.value; }); }
  function updatePrefsButton() {
    var n = prefsSelected().length;
    $('pp-prefs-go').disabled = !n;
    $('pp-prefs-go').textContent = n ? 'Switch ' + n + ' selected' : 'Switch selected patrons';
  }
  if ($('pp-prefs')) {
    $('pp-prefs-table').addEventListener('change', function (e) {
      if (e.target.id === 'pp-prefs-all') root.querySelectorAll('.pp-pref').forEach(function (c) { c.checked = e.target.checked; });
      updatePrefsButton();
    });
    $('pp-prefs-go').addEventListener('click', function () {
      var n = prefsSelected().length, sms = $('pp-prefs-mode').value === 'sms_or_print';
      $('pp-prefs-confirm').querySelector('.pp-confirm-text').textContent =
        'Move the email notices of ' + n + ' patron' + (n === 1 ? '' : 's') + ' to ' + (sms ? 'SMS or print' : 'print') + '?';
      $('pp-prefs-confirm').hidden = false; $('pp-prefs-go').hidden = true;
    });
    $('pp-prefs-no').addEventListener('click', function () { $('pp-prefs-confirm').hidden = true; $('pp-prefs-go').hidden = false; });
    $('pp-prefs-yes').addEventListener('click', function () {
      var items = prefsSelected();
      $('pp-prefs-yes').disabled = true; $('pp-prefs-msg').textContent = 'Switching…';
      var pairs = items.map(function (i) { return ['item', i]; }); pairs.push(['mode', $('pp-prefs-mode').value]);
      postJSON('cud-prefs-switch', pairs).then(function (d) {
        var ok = d.results.filter(function (r) { return r.ok && r.changed; }).length;
        var bad = d.results.filter(function (r) { return !r.ok; });
        return loadPrefs().then(function () {
          $('pp-prefs-msg').textContent = 'Switched ' + ok + ' patron' + (ok === 1 ? '' : 's') + '.' +
            (bad.length ? ' Skipped ' + bad.length + ': ' + bad.map(function (r) { return '#' + r.borrowernumber + ' (' + r.error + ')'; }).join('; ') : '');
        });
      }).catch(function (e) { $('pp-prefs-msg').textContent = 'Failed: ' + e.message; })
        .then(function () { $('pp-prefs-yes').disabled = false; $('pp-prefs-confirm').hidden = true; $('pp-prefs-go').hidden = false; });
    });
    $('pp-prefs-log').addEventListener('click', function (e) {
      var id = e.target.getAttribute && e.target.getAttribute('data-prefs-undo');
      if (!id) return;
      e.target.disabled = true; e.target.textContent = 'Restoring…';
      postJSON('cud-prefs-undo', [['id', id]]).then(function (d) {
        if (!d.ok) { e.target.textContent = d.error; return; }
        loadPrefs();
      }).catch(function (err) { e.target.textContent = err.message; });
    });
  }

  // ---------- load ----------
  function loadAll() {
    var p = { from: state.from, to: state.to }; if (state.letter) p.letter = state.letter;
    $('pp-error').hidden = true; $('pp-error').innerHTML = '';
    return getJSON('data', p).then(function (d) {
      renderSummary(d);
      failedRows = d.failed_rows || []; renderFailed();
    }).catch(function (e) {
      ['kpi-lifetime', 'kpi-sent', 'kpi-failed', 'kpi-rate', 'kpi-pending'].forEach(function (id) { $(id).textContent = '!'; });
      var tb = $('pp-failed').querySelector('tbody'); tb.innerHTML = '';
      tb.appendChild(el('tr', null, [el('td', { colspan: 5, class: 'pp-muted', text: 'Could not load: ' + e.message })]));
      showError('Dashboard data: ' + e.message);
    });
  }

  // Start-up: one request at a time, so rate limiters in front of Koha aren't tripped.
  if (state.from && state.to) {
    setRange(state.from, state.to);
    var isDefault = state.to === TODAY && state.from === addDays(TODAY, -29) && !state.letter;
    root.querySelectorAll('[data-preset]').forEach(function (x) { x.classList.toggle('is-active', isDefault && x.dataset.preset === '30'); });
  } else preset('30');
  loadAll()
    .then(function () { return loadSmtp(false); })
    .then(function () { return loadCleanup(); })
    .then(function () { return loadPrefs(); });
})();
