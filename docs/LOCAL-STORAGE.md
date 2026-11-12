# Swift SDK storage

The SDK uses its own Application Support/Corlex directory, excluded from backup with restrictive file permissions and platform data protection. SHA-256 owner scopes bind the SDK write key and complete ingest/config base URLs. Global privacy generation checks fence identity, events, config, crash files, delayed callbacks and network sends. Another credential/proxy cannot inherit captured history. Invalid or unreadable privacy state stays pending; explicit opt-in may start only fresh memory state when protected persistence is unavailable.

Only actual optIn stores an owner grant in SDK-only owner-choices.json outside captured generations (256 owners / 32 KiB, no credentials or telemetry). Default configured grant and ATT observations create no marker. ATT restriction/restoration discards captured scopes but retains the explicit choice; SDK withdrawal or a new pending floor clears old markers and fences earlier activations. A stale cleanup/write cannot authorize a later generation. Repeated optIn preserves current identity, event IDs and config. Captured pending events are memory-only; no crash report is written without effective permission.

The OS sandbox/data-at-rest protection applies; no independent SDK encryption, host-wide backup policy change or retroactive cloud-backup erasure is claimed.
