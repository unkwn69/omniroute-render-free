# OmniRoute 3.8.50 — Render Free + Supabase Storage

This bundle uses the exact OmniRoute 3.8.50 Docker image.

Because Render Free has an ephemeral filesystem, the startup wrapper restores
storage.sqlite from a private Supabase Storage signed URL when the local DB is
absent. It also attempts periodic best-effort replacement of the same object
using a server-side Supabase key.

Constraints:
- Render Free: 0.1 CPU / 512 MB RAM.
- Free filesystem is ephemeral.
- Single SQLite writer / single OmniRoute instance only.
- The existing VM must remain untouched until Render passes health, models,
  non-streaming inference, streaming inference, and Claude Desktop inference.
- Keep Azure WireGuard + Mac gateway for the College Noticeboard scanner.
