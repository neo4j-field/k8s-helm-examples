# Reaching the GDS secondary through a composite database

Notes from getting a remote alias on a composite database (e.g. `kgraphsec.customer360`)
to actually reach the GDS-tagged secondary (`customers-gds-1`) in the hybrid cluster,
rather than silently landing on a core member. Everything here was verified live
against the `customers` domain deployment.

## The setup

- Composite database `kgraphsec` with a remote alias to the standard database `customer360`:
  ```cypher
  CREATE ALIAS kgraphsec.customer360 FOR DATABASE customer360
    AT 'neo4j+ssc://<gds-lb-host>:7687?policy=gds'
    USER neo4j PASSWORD '<password>';
  ```
- The alias's `AT` URL points **directly at the GDS-specific load balancer**
  (`lb1-gds.yaml`'s Service), not the shared core LB (`lb-neo4j-core.yaml`).
- `dbms.routing.load_balancing.plugin: server_policies` and
  `dbms.routing.load_balancing.config.server_policies.gds: tags(gds); halt();`
  are set cluster-wide (all core members and the GDS secondary), tagging the
  GDS server so the policy can select it.
- The `AT` URL has to use a routed scheme (`neo4j+ssc://`/`neo4j+s://`) — that's
  a hard requirement of remote aliases, not a choice. But routed-scheme alone,
  pointed at the *shared core LB*, doesn't get you to the GDS secondary: with
  `dbms.routing.default_router: "SERVER"` in effect (see below), `neo4j://`
  routing through that LB just collapses to whichever **primary** the LB
  happened to connect you to — it has no notion of "route me to the GDS
  server" on its own. That's the whole reason the alias's `AT` URL below
  points at the GDS-specific LB directly instead.

## Three things had to be true, and each failure mode was misleading

### 1. `initial.server.tags` is bootstrap-only

`initial.server.tags: "gds"` in the GDS values file only applies the first time
that server registers with the cluster. If the server already registered before
the tag was added (e.g. after an earlier deploy without it), a plain `helm upgrade`
+ rolling restart will **not** apply it — `SHOW SERVERS YIELD name, tags` keeps
showing `tags: []` no matter how many times you redeploy.

Fix live, no restart needed:
```cypher
SHOW SERVERS YIELD name, address, tags;   -- find the GDS server's id
ALTER SERVER '<server-id>' SET OPTIONS {tags: ['gds']};
```

### 2. The `?policy=gds` query param is inert through the shared core LB

`dbms.routing.default_router: "SERVER"` (set so the shared core LB doesn't hand
external clients unreachable internal `*.svc.cluster.local` addresses — see the
comment in `neo4j-core.yaml`/`hybrid-neo4j-gds.yaml`) makes **every real client
connection** collapse to "whichever server I'm actually talking to." This means:

- `CALL dbms.routing.getRoutingTable({policy: 'gds'}, 'customer360')` correctly
  shows the GDS server filtered into the `READ` role — but this is just metadata
  inspection, **not** what a live session actually does.
- A real driver/cypher-shell/Browser connection through the shared core LB with
  `?policy=gds` in the URL still gets serviced by a core member, because
  `default_router: SERVER` intercepts the routing decision before the
  `server_policies` plugin is ever consulted.

The fix is architectural: point the alias's `AT` URL directly at the GDS LB
instead of the shared core LB. Since only one server sits behind that LB, no
policy filtering is even needed there — `default_router: SERVER` naturally
resolves to that one server.

### 3. The client session must explicitly request read-only access mode

Even pointed at the right LB, most Bolt clients default to a **write-mode**
session. Under `default_router: SERVER`, a write-mode session gets steered
toward a writable member — and the GDS secondary
(`initial.server.mode_constraint: SECONDARY`) is never eligible for that role.
So the query gets silently redirected to a core member with no GDS plugin
installed, and fails with:
```
42N08: no such procedure
The procedure gds.pageRank.stream() was not found.
```
— which reads exactly like a missing-plugin error, not a routing/access-mode one.

Fix: request read access mode explicitly.
- `cypher-shell`: `--access-mode read` (default is `write`)
- Neo4j Browser: the connection-level **Read Only** toggle

```bash
cypher-shell -a bolt+ssc://<gds-lb-host>:7687 -d kgraphsec --access-mode read
```
```cypher
USE kgraphsec.customer360
CALL gds.pageRank.stream('customer360Graph') YIELD nodeId, score
RETURN nodeId, score ORDER BY score DESC LIMIT 5;
```

## Which GDS procedures actually work through the alias

Check a procedure's declared mode before relying on it:
```cypher
SHOW PROCEDURES YIELD name, mode WHERE name = 'gds.pageRank.stream' RETURN name, mode;
```

| Procedure | Mode | Works through the alias? |
|---|---|---|
| `gds.graph.project` | `READ` | Yes |
| `gds.pageRank.stream` | `READ` | Yes |
| `gds.pageRank.mutate` | `READ` (writes only to GDS's private in-memory graph catalog, never the actual Neo4j store — hence classified `READ` despite the name) | Yes |
| `gds.pageRank.write` | `WRITE` | **No** — structurally unreachable through the alias |

`.write` variants fail two independent ways:

- **Read-mode session** (required to reach the GDS secondary at all):
  ```
  42N02: writing in read access mode
  Writing in read access mode not allowed.
  ```
- **Write-mode session** (required by the procedure itself): gets redirected
  off the GDS server entirely, back to `42N08: no such procedure`.

And even calling `.write` **directly** against the GDS pod, bypassing the
alias/routing entirely, fails independently on licensing:
```
IllegalStateException: Writing results to the cluster is only available with a
Licensed Neo4j Graph Data Science library deployed on a `Secondary` instance.
```
So `.write`-mode GDS procedures need both a licensed GDS deployment and a
direct (non-routed, non-alias) connection to the GDS server — they cannot be
reached through a composite database alias in this architecture at all.

## Example: end-to-end `stream` + `mutate` through the alias

```cypher
-- 1. Project a graph (READ mode, works through the alias)
USE kgraphsec.customer360
CALL gds.graph.project('customer360Graph', '*', '*')
YIELD graphName, nodeCount, relationshipCount;

-- 2. Stream PageRank scores
USE kgraphsec.customer360
CALL gds.pageRank.stream('customer360Graph') YIELD nodeId, score
RETURN nodeId, score ORDER BY score DESC LIMIT 5;

-- 3. Mutate the projected graph with the scores
USE kgraphsec.customer360
CALL gds.pageRank.mutate('customer360Graph', {mutateProperty: 'pageRankScore'})
YIELD nodePropertiesWritten, ranIterations, didConverge
RETURN nodePropertiesWritten, ranIterations, didConverge;

-- 4. Verify the mutated property is there
USE kgraphsec.customer360
CALL gds.graph.nodeProperties.stream('customer360Graph', 'pageRankScore')
YIELD nodeId, propertyValue
RETURN nodeId, propertyValue ORDER BY propertyValue DESC LIMIT 5;
```

All four run under `--access-mode read` / Browser's Read Only toggle, connected
to the GDS LB host, with `kgraphsec` as the session database.

## Persisting mutated GDS results without `gds.*.write()`

Since `.write` procedures are unreachable here (previous section) — blocked by
routing *and* by licensing even on a direct connection — persisting a `mutate`d
property into the actual graph has to go through plain Cypher instead. Both
approaches below connect **directly** to each server (bypassing the composite
alias entirely), because the two halves of the job must run on physically
different servers: the GDS in-memory catalog only exists on the `SECONDARY`
(`customers-gds-1`), but real graph writes can only land on a writable core
member.

Both options are therefore two-hop **by necessity**, not by choice, and both
need some kind of buffer sitting between the hops — a file (Option A) or the
client's own memory (Option B) — because a single Cypher query/transaction
cannot span both servers. There's no way to read from the GDS catalog and
`SET` a real node property in one statement; whatever holds the intermediate
result is unavoidable, only its shape differs.

The bridge between the two is `gds.util.asNode(nodeId)`, which resolves a
GDS-internal id back to the real underlying node *within that session*, and
`elementId(node)`, which turns that into a string key valid across sessions —
this is what actually lets a separate write query on a different server find
the same node again. (GDS's own `gds.graph.export.csv` was tried first and
rejected for this — its `:ID` column is a GDS-internal sequential id generated
fresh per export, unrelated to `elementId`, meant for `neo4j-admin database
import full` to build a brand-new database, not for patching an existing one.)

At minimum, this is already two separate transactions regardless of how many
rows are involved — one read-only transaction on the GDS secondary, one write
transaction on a core primary — because a single transaction can't span a
`READ`-only server and a `WRITE`-capable one. That split exists even for a
single row. On top of that minimum, both options below also chunk each half
into *multiple* transactions rather than one giant one per side, which is
the separate, scale-driven concern (this graph is 5.18M nodes; a 5M-row
single transaction risks memory pressure and long lock/commit times
regardless of the read/write split).

### Option A — export to CSV (shared EFS), then batched `LOAD CSV`

Step 1, on the GDS pod: `apoc.export.csv.query` writes the bridged
`(elementId, property)` pairs to a CSV, batching the file writes themselves
via `batchSize`. Because `apoc.export.file.enabled: "true"` and no absolute
path is given, the file lands under `server.directories.import` (`/import`
here) — which is the **shared EFS PVC** (`pvc-efs-dynamic`) already mounted on
every pod in the domain, core and GDS alike. No copying required.

```cypher
// on the GDS pod / GDS LB, -d customer360
CALL apoc.export.csv.query(
  "CALL gds.graph.nodeProperties.stream('customer360Graph', 'communityId')
   YIELD nodeId, propertyValue
   WITH gds.util.asNode(nodeId) AS n, propertyValue
   RETURN elementId(n) AS eid, propertyValue AS communityId",
  'customer360-communityId.csv',
  {batchSize: 10000}
) YIELD file, rows, batches, done
RETURN file, rows, batches, done;
// -> customer360-communityId.csv, 5186274 rows, 519 batches, true
```

Step 2, on a core member: `LOAD CSV` + Cypher's native
`CALL {...} IN TRANSACTIONS OF N ROWS` reads the same file straight off the
shared EFS mount and commits the write in chunks instead of one 5M-row
transaction.

```cypher
// on a core member, -d customer360, default write access mode
LOAD CSV WITH HEADERS FROM 'file:///customer360-communityId.csv' AS row
CALL {
  WITH row
  MATCH (n) WHERE elementId(n) = row.eid
  SET n.communityId = toInteger(row.communityId)
} IN TRANSACTIONS OF 10000 ROWS;
```

### Option B — skip the file, drive the write with `apoc.periodic.iterate`

Nothing touches disk here — the buffer is application memory instead of a
file. This requires actual client code (Python, Java, etc., using a Neo4j
driver) to do the buffering. A driver application opens two separate
connections: it runs the GDS stream query against the GDS pod and holds the
resulting `(elementId, property)` pairs in memory, then passes that same
in-memory list as a query parameter to a second connection against a core
member, which runs `apoc.periodic.iterate` to apply the write.
`apoc.periodic.iterate` chunks that write into its own set
of transactions (`batchSize`) — the same idea as Option A's
`CALL {} IN TRANSACTIONS`, just with the intermediate data held in memory
instead of a shared file.

```cypher
// on the GDS pod / GDS LB, -d customer360 — read side, client collects the rows
CALL gds.graph.nodeProperties.stream('customer360Graph', 'communityId')
YIELD nodeId, propertyValue
WITH gds.util.asNode(nodeId) AS n, propertyValue
RETURN elementId(n) AS eid, propertyValue AS communityId;
```

```cypher
// on a core member, -d customer360 — write side, $rows supplied by the client
// from the query above (a list of {eid, communityId} maps)
CALL apoc.periodic.iterate(
  "UNWIND $rows AS row RETURN row",
  "MATCH (n) WHERE elementId(n) = row.eid SET n.communityId = row.communityId",
  {batchSize: 1000, params: {rows: $rows}, parallel: false}
) YIELD batches, total, committedOperations, failedOperations
RETURN batches, total, committedOperations, failedOperations;
```

### Which to use

- **Option A** scales better for very large result sets — the file is written
  once and streamed by `LOAD CSV`, so nothing has to sit in a client's memory
  or get passed as a single large query parameter. It needs the shared EFS
  `import` mount, which this domain already has.
- **Option B** avoids touching disk at all, which is convenient for smaller
  or ad-hoc result sets, but the client has to hold and forward every row —
  impractical for the full 5M-node case without adding its own paging (e.g.
  `SKIP`/`LIMIT` over the GDS stream) on top.
