# Upstream contribution: generic hardening for `omarchy.agents`

This plugin vendors `ui/Main.qml` from the built-in `omarchy.agents` plugin.
Two changes made here are **generic** (not antigravity-specific) and belong
upstream so every copy inherits them. This file is the prepared contribution;
open a PR against the Omarchy source when convenient.

Target file: `shell/plugins/agents/Main.qml` (packaged at
`/usr/share/omarchy/shell/plugins/agents/Main.qml`).

---

## 1. Null-prototype maps for synced snapshot aggregation

**Why:** `aggregateSnapshots()` builds plain `({})` maps keyed by values taken
from JSON snapshots synced from other machines. A key such as `__proto__`
then becomes a prototype mutation in the Quickshell JS runtime instead of an
ordinary data key. Snapshot files are user- or sync-directory-controlled input.

**Change:** create the maps with `Object.create(null)`.

```diff
 function emptyTokenBucket() {
-  return { inputTokens: 0, outputTokens: 0, cacheReadInputTokens: 0, cacheCreationInputTokens: 0 }
+  // Null-prototype maps so untrusted JSON keys such as "__proto__" become
+  // ordinary own properties instead of mutating object prototypes.
+  var bucket = Object.create(null)
+  bucket.inputTokens = 0
+  bucket.outputTokens = 0
+  bucket.cacheReadInputTokens = 0
+  bucket.cacheCreationInputTokens = 0
+  return bucket
 }
```

```diff
 function aggregateSnapshots(snapshots) {
   var dates = recentDateStrings()
-  var devices = {}
-  var providers = {}
+  var devices = Object.create(null)
+  var providers = Object.create(null)

   function providerAcc(id) {
     if (providers[id]) return providers[id]
-    var recentByDay = {}
+    var recentByDay = Object.create(null)
     for (var d = 0; d < dates.length; d++) recentByDay[dates[d]] = 0
     providers[id] = {
       ...
-      todayTokensByModel: ({}),
+      todayTokensByModel: Object.create(null),
       recentByDay: recentByDay,
       ...
-      activeDates: ({}),
-      modelUsage: ({}),
-      devices: ({})
+      activeDates: Object.create(null),
+      modelUsage: Object.create(null),
+      devices: Object.create(null)
     }
     return providers[id]
   }
```

```diff
-  var outProviders = {}
+  var outProviders = Object.create(null)
```

```diff
 function localSnapshot() {
-  var providerMap = {}
+  var providerMap = Object.create(null)
```

`Object.keys()` / `for…in` / `JSON.stringify()` behave identically on these
objects, so no other call site changes.

---

## 2. Reject path traversal in `expandPath()`

**Why:** the sync feature concatenates the configured directory into shell
arguments and a snapshot path. Rejecting `..` prevents a configured/entered
path from escaping the intended directory.

```diff
 function expandPath(path) {
   var value = String(path || "").trim()
   if (value === "") return ""
+  if (value.indexOf("..") !== -1) return ""
   if (value === "~") return home
```

---

## Verification
- `qmllint ui/Main.qml` passes with these changes.
- The vendored copy in this repository carries both changes and all plugin
  tests pass, so the patch is proven in production use.
