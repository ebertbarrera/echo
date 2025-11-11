## Operating Mode (Single PR, Cost-Guarded, Crash-Safe)
- Deliver EVERYTHING in this issue as **ONE PR**. No child issues, no multi-PR splits.
- **Model & Iterations:** use `${{ vars.LLM_MODEL || 'openai/gpt-4o-mini' }}` with `${{ vars.OPENHANDS_MAX_ITER || '8' }}`.
- **Credit Policy (hard rules):**
  - Keep logs terse; no verbose stack traces unless failing.
  - Prefer diffs over long prose in PR body; max 6 small screenshots total (compress/thumbnails).
  - Avoid re-generating PDFs/images unless inputs changed.
  - Run tests **once** at end of each section; don’t loop tests per file.
  - Use caching where available; don’t reinstall toolchains if already present.
  - If a step will exceed iteration budget, ship the **highest-priority subset** (order below) and open a TODO at the bottom of the PR.

- **Priority Order under budget/time pressure:**  
  1) Contract PDF (unsigned, PH, dates visible)  
  2) E-Sign (signed PDF, SHA-256, audit log)  
  3) Global date helper (long form) + regression test  
  4) Chat per lease + Export (PDF+JSON)  
  5) Notarization helper (fields + file) with optional gate  
  6) Reminders skeleton (logging offsets)

- **Crash-Safety:**
  - Create/reset branch `feat/lease-exec-bundle`.
  - After each major file/migration/template, run `scripts/checkpoint.sh "msg"`. If missing, create it:
    ```bash
    #!/usr/bin/env bash
    set -euo pipefail
    msg="${1:-checkpoint}"; git add -A
    if ! git diff --cached --quiet; then git commit -m "$msg"; git push -u origin HEAD || true; fi
    ```
  - If the job fails, still open the PR with partial commits. Do NOT discard progress.

- **Security/Secrets:** Never commit secrets. Client uses ONLY `NEXT_PUBLIC_SUPABASE_URL` and `NEXT_PUBLIC_SUPABASE_ANON_KEY`. Service-role only in server routes.

---

## A) Idempotent DB Migrations (run first)
Wrap in one transaction; use `IF NOT EXISTS` throughout.

- **leases:**  
  `contract_url text`, `contract_hash_sha256 text`, `contract_version int default 0`,  
  `signed_contract_url text`, `signed_contract_hash_sha256 text`, `signed_at timestamptz`,  
  `notarized_url text`, `notarized_at timestamptz`, `owner_overridden boolean default false`.

- **audit_logs:**  
  `id uuid pk default gen_random_uuid()`, `user_id uuid not null`, `lease_id uuid`,  
  `action text not null`, `details jsonb`, `ip inet`, `user_agent text`, `created_at timestamptz default now()`;  
  RLS: `SELECT` only when `user_id = auth.uid()`.

- **lease_messages:**  
  `id uuid pk default gen_random_uuid()`, `lease_id uuid not null references leases(id) on delete cascade`,  
  `sender_id uuid not null references profiles(id) on delete cascade`, `body text`, `attachment_path text`,  
  `message_hash text not null`, `created_at timestamptz default now()`;  
  RLS: participants-only `SELECT/INSERT` (owner or renter of lease, or sender).

- **Storage buckets (guarded):** ensure `contracts`, `chat-exports` exist; participant-only read via Storage RLS or server download proxy.

**Checkpoint.**

---

## B) Shared Helpers (tiny, reusable)
Create `apps/web/lib/contract.ts`:

- `formatDateLong(d: Date|string, locale='en-PH'): string` → “Month Day, Year”
- `hashBufferSha256(buf: ArrayBuffer|Buffer): Promise<string>` → hex string

**Tests (Vitest, lightweight):** date formatting + deterministic hash.  
**Checkpoint.**

---

## C) Contract PDF (unsigned, PH-ready; dates visible)
- UI: `/app/leases/[id]` shows **Generate Contract (PDF)** and **Download** if exists.
- API: `POST /app/api/contracts/generate { leaseId }`:
  - Build PDF (prefer `@react-pdf/renderer`; fallback `pdfkit`) including: parties; property + slot; fixed term; rent (₱/mo); deposit & advance months; due day & grace; late fee placeholder; obligations; signature blocks (unsigned).
  - **Start & End dates** must appear in header **and** body using `formatDateLong`.
  - Upload to `contracts/{lease_id}/contract_v{n}.pdf`; update `leases.contract_url`, `contract_hash_sha256`, `contract_version`.

**Tests:** filename/version helper; date helper reuse; hash computed.  
**Checkpoint.**

---

## D) E-Signature (signed PDF + SHA-256 + audit)
- UI: “Sign Contract” modal/wizard: capture full name + drawn/typed signature (canvas → PNG data URL).
- API: `POST /app/api/contracts/sign { leaseId, name, signaturePng }`:
  - Embed signature image + printed name + timestamp (Asia/Manila) into finalized **signed PDF**.
  - Save as `contracts/{lease_id}/contract_signed_v{n}.pdf`; set `leases.signed_contract_url`, `signed_contract_hash_sha256`, `signed_at`.
  - Insert audit log: `{ user_id, lease_id, action:'contract.signed', details:{hash}, ip, user_agent }`.

**Tests:** signed hash stored; audit row written.  
**Checkpoint.**

---

## E) Global Date Consistency (one helper everywhere)
Replace ad-hoc date renders across lease UI + PDFs with `formatDateLong`.  
Add a single regression test to prevent format drift.  
**Checkpoint.**

---

## F) Chat per Lease (append-only + export)
- UI: `/app/leases/[id]/chat` → text + attachment (images/PDFs). Server assigns `message_hash`. No edit; soft delete optional.
- Export API: `POST /app/api/chat/export { leaseId }` → produce **PDF + JSON** with Asia/Manila timestamps & integrity note; store under `chat-exports/{lease_id}/export_{ts}.(pdf|json)`.

**Tests:** cannot edit old messages; export includes all messages & integrity banner.  
**Checkpoint.**

---

## G) Notarization Helper (optional gate)
- Lease page inputs: notary name, commission no., place/date; toggle **owner pays notarization**; upload notarized copy → `contracts/{lease_id}/notarized_v{n}.pdf`.
- Gate: block `leases.status='active'` until notarized **OR** `owner_overridden=true`.

**Tests:** state transition blocked until one condition met.  
**Checkpoint.**

---

## H) Reminders Skeleton (offsets + logging only)
- API: `POST /app/api/reminders/run` computes T-3/T-1/T0/T+3 relative to due day; writes audit log entries (email transport stubbed).
- Lease page panel lists reminder logs (most recent first).

**Tests:** offset math & log write.  
**Checkpoint.**

---

## CI / PR Requirements (keep costs down)
- Run ESLint + TS + Vitest once at the end of each major section (C→H).
- PR body: brief summary, bullets of what shipped, list of DB migrations, and 3–6 small screenshots (contract generate/download, sign, chat, export, notarization). No long narratives.
- If a cacheable step exists (node modules), use Actions cache; otherwise skip caching attempts to save tokens.

---

## Failure & Retry Policy (don’t waste credits)
- On any failure: commit what’s done, open/maintain the PR, and:
  - If recoverable: apply a **minimal patch** in the same PR and rerun tests.
  - If environment becomes corrupted: **stop immediately**, push checkpoints, and post a PR comment:  
    `@maintainer environment-corruption; please run Repair & Resume on this issue`
- Never loop on the same failing step more than **2 times** in a single run.

---

## Done Means (for THIS run)
- One PR from `feat/lease-exec-bundle` that includes: migrations; contract PDF (unsigned); E-sign (signed PDF + hash + audit); global date helper; chat + export; notarization helper; reminders skeleton; tests passing; CI green; Storage/DB RLS enforced; artifacts downloadable.
 

