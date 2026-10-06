# Permit records keyed to equipment

A working permit register and the database schema behind it, for the article *Your Permit System Files Documents. The Hazard Sits on the Equipment.*

It puts four ideas from the article into code:

- **Records belong to equipment.** Permits, isolations and removed protections are recorded against the equipment they touch. The equipment list knows what belongs to what, so a check on a pump includes its relief valve.
- **What is removed stays open.** A removed protection, such as a relief valve, stays open on the equipment until a later record closes it.
- **Nothing is overwritten.** Every change is a new row in a log that only accepts new rows. Each row carries a hash of its own contents and of the row before it, so a changed or deleted row can be detected (see [Limits](#limits)).
- **The database enforces the rules.** The permit rules run inside the database as triggers, so the app, a manual data fix and a bulk import all go through the same checks.

This is not a certified permit-to-work system, and it has not been used on a site. Use it to write a specification, or to test a vendor's claims against the same scenarios.

## Words used here

- **Open condition:** something a record leaves open on a piece of equipment, such as an open permit, an isolation or a removed relief valve. It stays open until a later record closes it.
- **Seal:** the hash of the newest record. Copy it somewhere outside the system. If anyone later rewrites the log, the seal you kept no longer matches.
- **Catalogue:** the table that says what each record type opens, what it closes, and whether it blocks releasing an isolation.

## Run it

You need Node.js 20 or later (tested on 20, 22 and 24).

```bash
npm install
npm start          # serves http://localhost:4400/app/
npm test           # 15 tests in PGlite, no database server needed
```

The app runs PostgreSQL inside your browser using PGlite, a build of PostgreSQL that runs in WebAssembly. Records stay in your browser's storage (IndexedDB). Nothing is sent anywhere. On first open, the app loads an example and lists the steps to try.

To see the core schema without installing anything, open the [Permit Equipment Sandbox](https://serhat.bio/tools/permit-equipment-sandbox). It runs Piper Alpha's day on two permit systems side by side. One files permits by location, like the paper rack. The other files every record by equipment.

## What the app does

| Screen | What it shows | What you can do |
|---|---|---|
| Equipment | Everything open on a piece of equipment, on what belongs to it, and on what it belongs to. The history of all three. | Issue a permit, isolate, remove a protection, record a gas test, release an isolation, reinstate a protection |
| Permits | Each permit's status, worked out from the log (Active, Suspended, Closed). What the permit still holds open. Its records. | Suspend, revalidate, close |
| Log | Every record in the order it arrived. Whether the log is intact. The latest seal. What was open at a past moment, by when it happened or by what the system knew. | Copy the seal, check a seal you kept, download CSV |
| Equipment list | The copy of the maintenance system (CMMS) list, with "belongs to" links, including equipment that belongs to more than one thing | Add equipment and links |

## The rules the database enforces

The rules are in `app/sql/12_rules.sql` and run on every new row in `asset_events`. Each refusal below is a message the database returns.

| Rule | Example refusal |
|---|---|
| A new permit must name every permit that has something open on the same equipment, on what belongs to it, or on what it belongs to. | `Cross-reference required. Open on this equipment: PTW-114.` |
| An isolation cannot be released while a permit or a removed protection is open on the same equipment, on what belongs to it, or on what it belongs to. | `Release blocked. Still open: Relief valve removed on PSV-12 (PTW-117).` |
| An override needs a reason. The database, not the app, lists every open condition the override passed over. | `An override needs a reason of at least 10 characters.` |
| A permit cannot close while a protection it removed is still off. | `Permit PTW-117 still has protections removed: …` |
| A record that closes something must be the right type, be on the same equipment, point at a record that is still open, and not be dated before it. | `That record is on different equipment.` |
| A suspended permit takes no work until it is revalidated. A closed permit takes no work at all. | `Permit PTW-130 is suspended. Revalidate it before recording work under it.` |
| A suspended hot work permit can be revalidated only if the latest gas test since the suspension reads at or below the site limit. | `Hot work: record a gas test taken after the suspension before revalidating.` |
| The catalogue, not the app, decides whether a record opens something. Unknown record types, times in the future and tags not in the equipment list are refused. | `Unknown record type: valve_vibes.` |

The catalogue is in `app/sql/11_catalogue.sql`. Adding a new kind of removed protection takes one row.

The hot work gas limit is set in `hot_work_lel_limit()`: 0% of the lower explosive limit (LEL). Change it to your site's rule.

## Files

```
sql/01–05_*.sql          core schema: the article's code, plus the chain check as a view
                         (chain_breaks), roles created only if missing, and the
                         open-conditions query as a function
seed/p101_scenario.sql   the article's case, for the core tests
app/sql/10_equipment.sql equipment details, extra owners, scope, loop check
app/sql/11_catalogue.sql what each record type does
app/sql/12_rules.sql     permit status view, scope and release checks, rules trigger, record()
app/                     the browser app (index.html, app.js, app.css, serve.mjs)
tests/*.sql              one file per claim in the article (core schema)
tests/app/*.sql          one file per rule group (core schema + app rules)
```

## Test on real PostgreSQL

The schema needs PostgreSQL 13 or later. All tests pass on 13 through 18.

Docker is all you need. The tests run inside the container, so you do not need a PostgreSQL client on your machine. The `-h localhost` waits for the real server, not the temporary one the image runs while it initialises:

```bash
docker run -d --name permit-pg -e POSTGRES_PASSWORD=postgres -v "$PWD":/work:ro postgres:18
docker exec -u postgres permit-pg bash -c 'until pg_isready -q -h localhost; do sleep 1; done; bash /work/tests/run.sh'
docker rm -f permit-pg
```

To test another version, change `postgres:18`. If you already run a PostgreSQL server and have `psql`, `createdb` and `dropdb` installed, run `npm run test:pg` with the usual `PGHOST`, `PGPORT`, `PGUSER` and `PGPASSWORD` variables.

The tests connect as a superuser, because the tamper tests switch triggers off on purpose, as a privileged administrator could.

## What each test checks

| Test | Claim |
|------|-------|
| `01_start_check` | Searching by permit finds one condition. Searching by the pump's own tag also finds one. Searching by the pump and what belongs to it finds both. P-102 never appears. |
| `02_closing_a_condition` | A suspension does not close the relief valve condition. A refit record that points at the removal closes it. Both rows remain. |
| `03_latest_event_hides_open_condition` | A gas test on P-101, recorded after its isolation, becomes the latest event on P-101. The isolation is still open. |
| `04_append_only` | The application role cannot UPDATE, DELETE or TRUNCATE. The triggers stop a superuser too, even with `session_replication_role = 'replica'`. The trigger overwrites any `server_ingest_ts`, `ingest_seq` and `event_hash` the client sends, and a temporary sequence or table named like the real ones cannot change `ingest_seq` or `prev_hash`. |
| `05_chain_intact` | An untouched log checks clean, including rows from a multi-row INSERT and a check run in a session with a different time zone and bytea format. |
| `06_tamper` | Editing an old row flags that row. If every hash after it is recomputed, the chain check passes, and only the kept seal shows the change. |
| `07_delete` | Deleting a row in the middle flags the row after it. Deleting the newest row flags nothing; only the kept seal shows it. |
| `08_state_at_a_past_moment` | An event recorded offline at 10:15 and synced after an 11:00 event arrives later in `ingest_seq`. It is missing from "what the system knew" and appears in "what had happened", with a sync gap. Both questions are asked of P-101 and its equipment, under any permit. |
| `09_read_committed_only` | Inserts under REPEATABLE READ and SERIALIZABLE are refused. READ COMMITTED is accepted, and the chain stays intact. |
| `10_add_column` | Adding a column to `asset_events` leaves every existing hash valid, and new rows still chain. |
| `app/a01_release_blocked` | The article's case through the rules: the cross-reference is required, the release is refused with both blockers named, even when the session creates its own temporary catalogue or open-conditions table, the override is recorded with its reason, and the valve is still open afterwards. |
| `app/a02_closing` | Closures of the wrong type, on the wrong equipment, backdated, missing or repeated are refused. A permit cannot close with the valve off. |
| `app/a03_hot_work` | Revalidation is refused without a gas test since the suspension, refused above the limit, and accepted after a clean test. |
| `app/a04_equipment_links` | A valve on a shared header blocks a release on either pump. Loops in the equipment list are refused. |
| `app/a05_chain_and_past` | The rules do not break the hash chain or the append-only protection. They refuse inserts under REPEATABLE READ, and they still fire with `session_replication_role = 'replica'`. The state at a past moment ignores later closures. |

## Limits

- **The chain detects tampering; it does not prevent it.** Anyone who can switch triggers off (a superuser, or anyone who can act as `ledger_owner`) can edit rows and recompute every hash. Copy the seal somewhere they cannot reach, such as the shift report, write-once storage or a system run by another team, and check the log against it.
- **Deleting the newest rows does not break the chain.** No row follows them, so only the kept seal shows they are gone.
- **The core schema does not check closures.** On its own, `closes_event_id` can point at any event: the wrong type, other equipment, or an event that opened nothing. A unique index stops a second closure of the same event. The app rules (`app/sql/12_rules.sql`) check type, equipment and dates on insert.
- **Columns added later are not covered by the hash.** The hash covers a fixed list of columns, so adding a column does not break the chain. To cover a new column, start a new hash version for rows written from then on.
- **Logical replication rewrites the server fields.** The triggers are set to `ENABLE ALWAYS`, so they also fire on a logical replication subscriber. The copy gets its own sequence numbers, timestamps and hashes, so it cannot be checked against seals kept from the source. Physical streaming replication is not affected.
- **The schema lives in `public`.** The trigger functions fix `search_path` to `public, pg_temp`, so a session cannot swap in its own temporary sequence or tables. To install the schema in another schema, change that setting in each function.
- **The equipment list has no history.** Checks use today's list. If you change a link, the equipment screens, history included, use the new links; the log itself does not change. In production, read the list from the maintenance system by tag number when a permit is issued or a start is requested.
- **One person, one browser.** "Recording as" is a typed name, not a login, and there are no roles for who may issue, suspend or override. A production system needs signed-in users and a rule for who may record each type.
- **Isolations are single points.** Nothing groups several points into one isolation certificate. Nothing checks that an isolation is on the permit's equipment either, because real isolation points are often upstream valves or breakers elsewhere.
- **Gas tests do not expire.** The latest test since the suspension decides, however long ago it was taken. If your site sets a validity period, add it to the revalidation rule.
- **READ COMMITTED only.** The triggers take a lock, then read the latest state. Under REPEATABLE READ or SERIALIZABLE, a transaction can miss a row committed while it waited, and two rows would point at the same predecessor. Both triggers refuse inserts at those levels (tests `09_read_committed_only` and `app/a05_chain_and_past`).
- **Use `ingest_seq` for arrival order.** Two inserts can share a `server_ingest_ts`. `ingest_seq` never ties.

## Hosting the app

The app loads PGlite from `node_modules`, or from the jsDelivr CDN if that path is missing. To host it, serve `app/` and `sql/` from one root folder. Either include the PGlite files, or let the app load PGlite from the CDN.

## License

MIT. See [LICENSE](LICENSE). The software comes with no warranty. It is a reference schema, not a permit-to-work system.
