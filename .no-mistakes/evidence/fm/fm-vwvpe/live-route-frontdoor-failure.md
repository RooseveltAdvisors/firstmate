# Live CLI drives: Jev task-routing front doors fail a partial/failed auto-charter (R-4, F-1, R3-1)

All drives execute the real bin/fm-route-dispatch.sh and bin/fm-route-domain.sh CLIs;
only the remote SystemOne HTTP call is answered at the urllib boundary (deterministic, no credentials).

### 1) dispatch human banner, partial scaffold (homes dir is a file)  (exit=1)
    === Jev Front-Door Router ===
    Action:     create_secondmate
    Route:      new_domain
    Confidence: 0.95
    New Domain: 0.95
    =============================
    Status: Auto-charter failed: home scaffold failed for /tmp/fm-route-live/homes-is-a-file/quantum-computing-cryptographic: [Errno 20] Not a directory: '/tmp/fm-route-live/homes-is-a-file/quantum-computing-cryptographic'
    error: auto-charter failed: home scaffold failed for /tmp/fm-route-live/homes-is-a-file/quantum-computing-cryptographic: [Errno 20] Not a directory: '/tmp/fm-route-live/homes-is-a-file/quantum-computing-cryptographic'

### 2) dispatch --json, partial scaffold: payload emitted THEN non-zero exit  (exit=1)
    {
      "action": "create_secondmate",
      "route": "new_domain",
      "confidence": 0.95,
      "needs_new_noul": 0.95,
      "probabilities": {},
      "reason": null,
      "seat_wall": {
        "walled": false
      },
      "auto_charter": {
        "chartered": true,
        "domain": "quantum-computing-cryptographic",
        "home": "/tmp/fm-route-live/homes-is-a-file/quantum-computing-cryptographic",
        "charter_appended": true,
        "scaffold_error": "[Errno 20] Not a directory: '/tmp/fm-route-live/homes-is-a-file/quantum-computing-cryptographic'",
        "failure": "home scaffold failed for /tmp/fm-route-live/homes-is-a-file/quantum-computing-cryptographic: [Errno 20] Not a directory: '/tmp/fm-route-live/homes-is-a-file/quantum-computing-cryptographic'"
      }
    }
    error: auto-charter failed: home scaffold failed for /tmp/fm-route-live/homes-is-a-file/quantum-computing-cryptographic: [Errno 20] Not a directory: '/tmp/fm-route-live/homes-is-a-file/quantum-computing-cryptographic'

### 3) producer CLI bin/fm-route-domain.sh itself, partial scaffold  (exit=1)
    === Jev Front-Door Router ===
    Action:     create_secondmate
    Route:      new_domain
    Confidence: 0.95
    New Domain: 0.95
    =============================
    Status: Auto-charter failed: home scaffold failed for /tmp/fm-route-live/homes-is-a-file/quantum-computing-cryptographic: [Errno 20] Not a directory: '/tmp/fm-route-live/homes-is-a-file/quantum-computing-cryptographic'
    error: auto-charter failed: home scaffold failed for /tmp/fm-route-live/homes-is-a-file/quantum-computing-cryptographic: [Errno 20] Not a directory: '/tmp/fm-route-live/homes-is-a-file/quantum-computing-cryptographic'

### 4) dispatch human, charter write fails (read-only registry)  (exit=1)
    === Jev Front-Door Router ===
    Action:     create_secondmate
    Route:      new_domain
    Confidence: 0.95
    New Domain: 0.95
    =============================
    Status: Auto-charter failed: Failed to write charter: [Errno 13] Permission denied: '/tmp/fm-route-live/reg-ro.md'
    error: auto-charter failed: Failed to write charter: [Errno 13] Permission denied: '/tmp/fm-route-live/reg-ro.md'

### 5) dispatch happy path: full scaffold still succeeds (over-tightening control)  (exit=0)
    === Jev Front-Door Router ===
    Action:     create_secondmate
    Route:      new_domain
    Confidence: 0.95
    New Domain: 0.95
    =============================
    Status: Auto-chartered new Second Mate "quantum-computing-cryptographic".
    Home scaffolded: /tmp/fm-route-live/homes-ok/quantum-computing-cryptographic
    Ready to spawn:  bin/fm-spawn.sh quantum-computing-cryptographic --secondmate

Scaffolded home markers from drive 5:
    /tmp/fm-route-live/homes-ok/quantum-computing-cryptographic/.fm-secondmate-home
    /tmp/fm-route-live/homes-ok/quantum-computing-cryptographic/.fm-secondmate-parent
