# Shielded-Vote installer — trust boundaries and security analysis

Review of the installation path Valar Group publishes for joining the
Shielded-Vote chain (`zvote-1`), as consumed by
`gcp/terraform/modules/zcash-vote-validator/`.

**Reviewed at:** 2026-08-06, against `join.sh` (1892 lines, chain version
`v1.0.3`), `svoted-wrapper.sh` (276 lines), `_chain_upgrade_common.sh` (1339
lines), `reset-validator-snapshot.sh`, `remove-validator.sh`, and the reference
page at <https://setup.valargroup.org/>.

Unqualified line numbers refer to `join.sh` as fetched on that date. It is
unversioned and served from a mutable bucket, so they will drift.

**Posture:** this deployment intentionally favours speed over hardening. Nothing
below is fixed upstream by us. What the module does mitigate is called out
per finding; everything else is accepted and recorded here so it can be revisited
deliberately rather than discovered later.

---

## 1. Trust boundaries

| # | Boundary | What it controls | Authentication |
|---|---|---|---|
| TB1 | `shielded-vote.nyc3.digitaloceanspaces.com` (DigitalOcean Spaces) | `join.sh`, `svoted-wrapper.sh`, the `svoted` + `create-val-tx` release tarball **and its `.sha256`**, `_chain_upgrade_common.sh`, every `scripts/upgrade/*` script, genesis fallbacks, `version.txt`, the teardown and snapshot-reset scripts | TLS only |
| TB2 | `voting.valargroup.org` (GitHub Pages) | `dynamic-voting-config.json`: the seed peer list, and transitively the binary version | TLS only. The document carries its own ed25519 `signatures[]` — **not verified by the installer** |
| TB3 | `vote_servers[0]` — currently `prod.vote-chain-primary.valargroup.org` | `/node_info` supplies `application_version.version`, i.e. which binary tag is installed; also the live genesis and the P2P peer | TLS only |
| TB4 | `snapshots.valargroup.org` | `latest.json` → chain-state archive URL **and its SHA-256** | TLS only |
| TB5 | `prod.svote.valargroup.org` | `POST /api/register-validator`, the approval/funding queue | TLS. Request body is signed by the validator account key |
| TB6 | Third parties | Let's Encrypt (certificates), `dl.cloudsmith.io` (Caddy apt repo + GPG key), `sslip.io` (DNS), `ifconfig.me` / `api.ipify.org` (public IP detection), `api.github.com` (our own `rage` install) | TLS only |

### The root assumption

**Control of TB1 is control of every validator.** One unauthenticated origin
serves the installer, the binaries, *and* the checksums used to verify those
binaries, and `join.sh` writes systemd units through `sudo`. There is no signing
at any layer — no GPG, no cosign, no pinned key, no transparency log. TLS is the
only integrity control end to end.

Every other finding is downstream of that one.

---

## 2. Findings

### 2.1 Checksum verification is fail-open — `1025-1047`

Two independent ways to skip it:

```bash
if curl -fsSL -o /tmp/shielded-vote-release.tar.gz.sha256 "${CHECKSUM_URL}" 2>/dev/null; then
  EXPECTED=$(awk '{print $1}' /tmp/shielded-vote-release.tar.gz.sha256)
  if command -v sha256sum > /dev/null 2>&1; then
    ACTUAL=$(sha256sum ... )
  elif command -v shasum > /dev/null 2>&1; then
    ACTUAL=$(shasum -a 256 ... )
  else
    echo "WARNING: Neither sha256sum nor shasum found — skipping checksum verification."
    ACTUAL="$EXPECTED"          # <-- forges a pass
  fi
  ...
else
  echo "WARNING: Checksum file not available — skipping verification."
fi
```

A 404 on the `.sha256` object degrades to installing the binary unverified. And
in the no-hash-tool branch, `ACTUAL="$EXPECTED"` makes the subsequent comparison
succeed by construction rather than aborting.

Notably the *snapshot* path (`737-758`) is correctly fail-closed and rejects a
malformed or missing checksum. So this is an inconsistency in the same script,
not a considered policy.

### 2.2 Checksums share an origin with the artifacts they cover

TB1 serves both the tarball and its digest; TB4 serves both the chain snapshot
and its digest. This detects corruption and TLS-less tampering. It provides no
defence against a compromised bucket, which is the threat that matters most given
§1.

### 2.3 Published signatures are never verified — `827`

`dynamic-voting-config.json` ships exactly the material needed to authenticate
it:

```json
"rounds": { "3fda6c83…": {
  "auth_version": 1,
  "ea_pk": "vLZJEsvRcqLUY9D1NP+B2AUJbwzucbqa/RFZrgxX248=",
  "signatures": [ { "key_id": "valargroup", "alg": "ed25519", "sig": "TzG8cuMd…" } ]
} }
```

The installer's entire interaction with the document is:

```bash
SEED_URL=$(echo "$VOTING_CONFIG" | jq -r '.vote_servers[0].url // empty')
```

No pinned verification key appears anywhere in the script. Wallets presumably
check these signatures; the thing that installs root-level software does not.

### 2.4 A remote party chooses the binary version — `848`, `897`

```bash
CHAIN_BINARY_VERSION=$(echo "$NODE_INFO" | jq -r '.application_version.version // empty')
```

`vote_servers[0]`'s self-reported `/node_info` selects which tarball gets
installed. A compromised or merely misconfigured first entry steers binary
selection for every new validator, bounded only by the tag regex at `897`
(`^v[0-9]+(\.[0-9]+)*…`) and by which objects exist in TB1. `SVOTE_RELEASE_VERSION`
can pin it; the published documentation never suggests doing so.

There is a defensible engineering reason for the design — the *app* version, not
the newest release, is what can replay blocks without app-hash divergence — but
the input is unauthenticated.

### 2.5 Predictable `/tmp` paths, one of them `source`d — `980`, `1025`, `1050`, `1058`, `1618`, `1626`

Fixed, world-predictable filenames rather than `mktemp`:

- `/tmp/shielded-vote-release.tar.gz` and `.sha256` — downloaded, verified, extracted, installed to `$INSTALL_DIR`
- `/tmp/_chain_upgrade_common.sh` — downloaded, then **`source`d** (`1626`): 1339 lines of remote, unchecksummed shell executed in the installer's context

On a multi-user host a local attacker can pre-create or symlink these ahead of the
run, yielding code execution as the installing account — and via its required
sudoers grant (§2.7), as root. The snapshot code path correctly uses
`mktemp -d`, so again this is inconsistent within one script.

*Module mitigation:* the validator host is single-purpose with IAP-only SSH, so
there is no second local user to exploit this. It remains a real defect for
anyone installing on a shared machine.

### 2.6 The generated unit runs as whoever ran the installer, unhardened — `1791-1809`

```ini
[Service]
Type=simple
User=$(whoami)
ExecStart=${WRAPPER_BIN}
Restart=on-failure
```

`User=$(whoami)` means running `join.sh` as root leaves `svoted` — a
network-facing daemon holding the validator signing key — running as root. The
unit also carries **no** `NoNewPrivileges`, `ProtectSystem`, `ProtectHome`,
`PrivateTmp`, or `LimitNOFILE`, making it markedly weaker than the hand-written
units in the sibling `zcash-vote-server` repository.

*Module mitigation:* the installer is run as the unprivileged `svote` account, so
`svoted` inherits that identity; and `10-hardening.conf` is staged into
`/etc/systemd/system/svoted.service.d/` **before** the unit exists. A drop-in was
chosen over editing the generated unit specifically because the installer
rewrites the base unit on any re-run.

### 2.7 Unattended installation requires passwordless sudo

`sudo tee /etc/systemd/system/…` (`1791`), `sudo systemctl` (`1811-1813`),
`sudo -E apt-get` (`298`), `sudo caddy` (`1499`), `sudo gpg --dearmor` (`1409`).
Any automated install therefore needs a NOPASSWD grant, which makes the install
account root-equivalent.

*Module mitigation:* partial only. The grant exists (`/etc/sudoers.d/svote`) and
is documented as revocable once the validator is bonded. Choosing an
unprivileged account is still worth it because of §2.6.

### 2.8 Signing material is generated on-box and never backed up — `1152`

`svoted init-validator-keys` produces `priv_validator_key.json`,
`node_key.json`, `keyring-test/`, `pallas.*` and `ea.*`. The documentation says
to "back up and store encrypted off-host" and to "keep the validator signing key
live on exactly one host", and automates neither.

Compounding it: `--keyring-backend test` (`1158`, `1533`, and throughout
`svoted-wrapper.sh`) means the **operator account key is stored unencrypted on
disk**. A leaked disk image or snapshot is both fund theft and double-signing
capability.

This is also the structural reason key backup cannot be scheduled at provisioning
time: there is nothing to back up until this line has run.

*Module mitigation:* this is the gap the module exists to close —
`svote-backup-keys` (age-encrypted, write-only bucket, fail-closed), a login-time
nag until it has run, and a prompt at the end of `svote join`.

### 2.9 Unconditionally destructive — `1079-1082`, bypass at `511-514`

```bash
if [ -d "${HOME_DIR}" ]; then
  echo "Removing existing ${HOME_DIR}..."
  rm -rf "${HOME_DIR}"
fi
```

No condition. The interactive `RESET` gate at `489-528` precedes it, but
`SVOTE_FORCE_RESET=1` skips that gate entirely, and in a non-interactive run the
gate hard-fails instead of protecting anything.

*Module mitigation:* this is the single biggest reason the installer is not wired
into the GCE startup script, which re-runs on every boot. `svote join` adds an
independent existence check, never sets `SVOTE_FORCE_RESET`, and requires a typed
`RESET` plus a successful key backup before `--force`.

### 2.10 The public helper API is unauthenticated with CORS wide open — `1178-1179`, `1200`

```bash
sed -i.bak '/\[api\]/,/\[.*\]/ s/enable = false/enable = true/' "${APP_TOML}"
sed -i.bak '/\[api\]/,/\[.*\]/ s/enabled-unsafe-cors = false/enabled-unsafe-cors = true/' "${APP_TOML}"
```

plus `api_token = ""` in the generated `[helper]` block, then published to the
internet through Caddy. `POST /shielded-vote/v1/shares` is unauthenticated by
design — it is how clients submit shares — but the practical result is that every
bonded validator runs an open write endpoint driving up to
`max_concurrent_proofs = 8` proof generations, with no rate limiting in front of
it. Denial of service against the helper API looks cheap.

### 2.11 Cosmovisor auto-download is code execution via governance — `1784`

`join.sh` sets `DAEMON_ALLOW_DOWNLOAD_BINARIES=false`. The published upgrade
documentation then instructs operators to enable it alongside
`DAEMON_DOWNLOAD_MUST_HAVE_CHECKSUM=true`.

Requiring a checksum helps less than it appears to. The checksum travels *inside*
the on-chain upgrade proposal's `info` field, next to the URL it describes:

```json
"binaries": {
  "linux/amd64": "https://github.com/valargroup/vote-sdk/releases/download/v1.1.0/…tar.gz?checksum=sha256:bb8df4e9…"
}
```

So the checksum proves integrity **against the proposal**, not against governance.
Whoever can land an upgrade proposal chooses which binary every validator that has
this enabled will run, and can supply a matching checksum for it. The mitigation
`MUST_HAVE_CHECKSUM=true` actually provides is narrower: it prevents accepting a
binary for which the proposal specified *no* checksum, and it prevents a
compromised release host from serving different bytes than the proposal named.

**Module stance: enabled, as an accepted risk.** `allow_binary_autodownload`
defaults to `true`, setting both `DAEMON_ALLOW_DOWNLOAD_BINARIES=true` and
`DAEMON_DOWNLOAD_MUST_HAVE_CHECKSUM=true`. The reasoning:

- A coordinated upgrade halts the node at a fixed height. For a foundation
  validator, silently dropping out of a live vote is a worse outcome — in both
  availability and reputational terms — than the marginal risk of governance
  choosing a binary.
- The trust is not new. Governance already decides the state machine this node
  executes; the difference is whether a human fetches the binary or cosmovisor
  does. A malicious upgrade is a chain-wide event, not one this validator escapes
  by pre-staging.
- It is a fallback, not the plan. Pre-staging via `svote prestage-upgrade` remains
  the primary path, `svote upgrade-status` reports readiness, and a daily timer
  plus login banner chase it.

Two things follow, and both are load-bearing:

1. **`MUST_HAVE_CHECKSUM=true` is mandatory, not decorative.** Without it the same
   mechanism will accept an unchecksummed binary named by a proposal. Never enable
   the first without the second.
2. **Auto-download does not cover every plan.** The already-applied `v1` plan's
   `info` carries no `binaries` map at all, so a validator joining from a snapshot
   cannot self-heal through download — hence `svote-stage-upgrades`, which stages
   the installed binary only when the plan's recorded tag is satisfied by it.

Revisit if the threat model changes — in particular if governance ever becomes
easier to capture than the release bucket in §1.

### 2.12 sslip.io as a hard dependency — `1386`

```bash
SVOTE_DOMAIN="$(echo "$PUBLIC_IP" | tr '.' '-').sslip.io"
```

Discloses the host IP in the public URL, and makes certificate *renewal* — not
just issuance — depend on a third-party wildcard DNS service remaining
operational. If sslip.io disappears, ACME fails and the validator silently stops
being client-ready.

*Module stance:* used as the zero-configuration default, with
`vote_validator_tls_domain` documented as the right choice for anything
long-lived.

### 2.13 A third party influences which certificate is requested — `1381-1382`

```bash
PUBLIC_IP=$(curl -4 -fsSL --connect-timeout 5 https://ifconfig.me 2>/dev/null || \
  curl -4 -fsSL --connect-timeout 5 https://api.ipify.org 2>/dev/null || echo "")
```

The response determines the TLS hostname.

*Module mitigation:* avoided entirely. The sslip.io name is computed in Terraform
from the reserved external address and passed as `--tls-mode custom --domain`, so
the installer never asks.

### 2.14 Registration payload has no nonce — `1530-1541`

```bash
TIMESTAMP=$(date +%s)
REG_PAYLOAD=$(build_register_payload "${TIMESTAMP}")
SIG_JSON=$(svoted sign-arbitrary "$REG_PAYLOAD" --from validator ...)
```

`{operator_address, url, moniker, timestamp}` signed with the validator account
key. No nonce, and any skew tolerance is server-side and unverifiable from the
client. Impact is low — a replayed payload only re-registers its own signer — but
it is a signed credential with no expiry the operator can reason about, and the
`url` field is attacker-relevant if the queue ever renders it.

### 2.15 Robustness issues

- **`1169`** — `sed "s|persistent_peers = \"\"|persistent_peers = \"${PERSISTENT_PEERS}\"|"` silently no-ops if the config template ever ships a non-empty default, producing a node with no peers and no error.
- **`903`** — `SEED_HOST=$(echo "$SEED_URL" | sed -E 's|^https?://||; s|:[0-9]+$||; s|/.*||')` strips a trailing port *before* stripping a path, so a seed URL carrying both (`https://host:443/base`) yields the wrong host.
- **`svoted-wrapper.sh:249-276`** — the funding/bonding loop retries `create-val-tx … || true` every 30 s forever, with no backoff, no attempt cap, and no distinct log signal for a persistently failing transaction versus simply waiting for funds.
- **`1032`** — `DOWNLOAD_SIZE` parsing depends on `content-length` being present in a `HEAD` response; absent, the progress display silently degrades (cosmetic only).

### 2.16 Things done well, for the record

- Snapshot integrity is fail-closed: chain-id match, URL scheme check, strict 64-hex checksum validation, and verification before extraction (`714-759`).
- The snapshot archive listing is validated before extraction, rejecting any entry outside `data/` and any `..` traversal (`766-769`) — a real path-traversal defence, not a token one.
- Local `priv_validator_state.json` is preserved across a snapshot restore and the restored consensus WAL is discarded (`771-790`), which is precisely the correct double-signing precaution.
- `genesis.json` is validated against the built binary and its `chain_id` cross-checked before use (`1127-1138`).
- Cosmovisor auto-download defaults to off (`1784`) — a safe default, even though
  this deployment deliberately overrides it (§2.11).
- Upgrade plans carry per-platform binaries with SHA-256 checksums in the URL
  fragment, which is what makes `DAEMON_DOWNLOAD_MUST_HAVE_CHECKSUM=true`
  meaningful at all.
- The interactive reset gate requires typing `RESET` and enumerates what will be destroyed (`496-527`).

---

## 3. Assumptions the installer makes about its host

Single-purpose Linux or macOS host; passwordless `sudo`; `:80`, `:443` and
`:26656` free and publicly reachable; a public **IPv4** address — IPv6-only is
unsupported (`1378-1384`); an `apt`-based distribution for the automatic Caddy
path; nothing else managing Caddy or binding those ports; `$HOME` writable and
persistent across reboots; an operator watching for the approval prompt out of
band; and `svoted` as the sole consumer of `$HOME/.svoted`.

---

## 4. If this is revisited

Roughly in value order:

1. **Pin the installer.** Set `vote_validator_join_script_sha256`. Cheapest real
   improvement available; costs one `sha256sum` per upstream change.
2. **Ask upstream to sign releases** (minisign/cosign) and to publish the
   verification key out of band from TB1. Without this, §2.1 and §2.2 cannot
   actually be fixed, only narrowed.
3. **Verify the voting-config signatures** in the installer against a pinned
   `valargroup` ed25519 key — the material is already published (§2.3).
4. **Make checksum verification fail-closed** (§2.1) and use `mktemp` throughout
   (§2.5). Both are small, local patches worth offering upstream.
5. **Move the operator key off `--keyring-backend test`** (§2.8), or document that
   the account is expendable and hold only the minimum balance on it.
6. **Rate-limit the helper API** at Caddy (§2.10).
7. **Revoke the `svote` sudoers grant** once bonded (§2.7).
8. **Move to a real domain** and drop the sslip.io dependency (§2.12).
9. **Alerting.** There is none in this repository — no
   `google_monitoring_alert_policy` anywhere. `TF_svote_block_height_distribution`
   gives the signal; a stalled-height and a not-bonded alert would turn it into
   something operational.
