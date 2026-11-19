# Pigeon Post 🐦✉️

**Pigeon Post** is a Koha plugin from koha.pro. It adds **Tools → Pigeon Post Dashboard**, a page showing how your library's email is doing.

- **How much went out:** emails sent all time, plus sent and failed counts for any date range or notice type.
- **Charts:**
  - sent vs failed per day
  - why emails failed
  - busiest notice types
  - sending by hour of day
- **Failed deliveries:** every address that failed in the range, with its patron, the failure count and the last reason.
- **SMTP lights:** a green, amber or red light for each mail server configured in Koha. The check connects to the server and greets it, but never logs in or sends mail.
- **Stuck-queue warning:** appears when the oldest waiting email is over an hour old, which usually means `process_message_queue.pl` isn't running.
- **Invalid address cleanup:**
  - Finds patron addresses that failed *X times in a row*.
  - Clears them so the queue stops retrying, and drops their waiting messages.
  - Every clear is logged and can be undone.
  - It can also run automatically each night, with safety limits (see below).
- **Email preferred, no address:**
  - Lists patrons whose messaging preferences say email but who have no address Koha can use (it follows the `EmailFieldPrimary` system preference). Every email notice for them fails with `NO_EMAIL`.
  - Download the list as CSV, for example so desk staff can ask for a new address.
  - Switch selected patrons' email notices to print, or to SMS when they have a number. Each switch is logged and can be undone.
  - When an address cleanup leaves a patron with no address, their email notices are switched the same way (on by default; undoing the clear puts them back).
- **Weekly digest:** a summary email of the week, sent to whichever addresses you choose.

Requires Koha 22.11 or later.

## Install
1. Run `tools/build_kpz.sh`, which creates `dist/pigeon-post-v<version>.kpz`.
2. In Koha, go to Administration → Manage plugins → Upload plugin, and choose the KPZ.
3. Open it from Tools → Pigeon Post Dashboard. Settings are under the **Settings** button, or the plugin's *Configure* action.
4. For automatic cleanup and the weekly digest, make sure Koha's nightly plugin job (`misc/cronjobs/plugins_nightly.pl`) runs from cron.

## Permissions
- **Viewing the dashboard:** needs Koha's plugin *tool* permission.
- **Cleanup, preference switching and settings:** also need **Patrons → edit_borrowers** (or superlibrarian).

## Safety
- **What it changes in Koha:** only the patron email fields you choose to clear, and the messaging preferences of patrons left with no address (email moved to print or SMS). It also marks a cleared address's waiting messages as `deleted`; nothing is physically deleted from the queue.
- **Automatic cleanup is off by default.** When it is on, it skips the run in two cases:
  - more than half of the last day's emails failed, which points to an SMTP outage rather than bad addresses
  - more addresses are over the threshold than the per-run cap (default 50)
- **Failure codes that say nothing about the address are ignored:** `NO_EMAIL`, `NO_FROM`, `INVALID_BORNUMBER`, `DUPLICATE_MESSAGE`, `MISSING_SMS`.
- **All-time totals survive Koha's cleanup.** Koha's `cleanup_database.pl --mail` purges old queue rows, so the plugin saves daily totals in its own table (`…_daily_stats`). Uninstalling drops only the plugin's own three tables.

## Development
```
prove -l -I. t/                      # unit tests (no Koha needed)
tools/build_kpz.sh                   # package
PIGEON_SEED_OK=1 perl tools/seed_fixtures.pl   # on a disposable koha-testing-docker only
PIGEON_SEED_OK=1 perl tools/seed_fixtures.pl --purge
```
The look follows koha.pro/rustsearch. See `CLAUDE.md` for the colors and design rules.
