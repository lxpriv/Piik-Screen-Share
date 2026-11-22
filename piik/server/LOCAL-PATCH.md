# Local invitation compatibility patch

Target: Piik v2.8.0, upstream revision `81b4f27eff2a1de1dfe6131c06b525b7ba3508a8`.
Source: https://github.com/TNTcraftHIM/Piik
Patch: [`../patches/mobile-invite-tracking.patch`](../patches/mobile-invite-tracking.patch)
Local build identity: `2.8.0+invitefix.1`.

The browser entry parser removes a trailing `&bdx_monitor_append_params=...`
mobile jump telemetry field before the existing canonical Viewer grant check.
Malformed credentials, duplicate credentials and unknown fragment parameters
remain rejected. The patch includes regression tests and the matching contract update.

## Rebuild from a fresh repository checkout

Run from this integration repository's root. Requires Git, Node.js 24, npm and
Go 1.27.4, matching the pinned upstream source requirements.

```powershell
git clone --no-checkout https://github.com/TNTcraftHIM/Piik.git piik/source
git -C piik/source checkout 81b4f27eff2a1de1dfe6131c06b525b7ba3508a8
git -C piik/source apply ../patches/mobile-invite-tracking.patch
Push-Location piik/source
try {
    npm ci
    npm run typecheck
    npm test -- tests/client-state.test.ts
    npm run build:web
    go build -trimpath -ldflags '-s -w -X main.BuildVersion=2.8.0+invitefix.1 -X main.BuildRevision=81b4f27eff2a1de1dfe6131c06b525b7ba3508a8' -o ../server/piik-server.exe ./cmd/piik-server
} finally { Pop-Location }
```

Check every command's exit status before continuing. The generated executable
is ignored by Git. `server/REVISION`, `LICENSE` and `THIRD-PARTY-NOTICES.txt`
record the distributed Piik build's provenance; retain these when distributing it.

Existing local workspaces may instead have a separate patched worktree at
`piik/build/invite-fix`. Do not overwrite its uncommitted changes. Build caches,
installers and intermediate executables can be regenerated; browser profiles
and room databases are private user data and must be retained locally.

An official server update also replaces this local fix; check whether it already
contains the invitation compatibility correction before reapplying the patch.
