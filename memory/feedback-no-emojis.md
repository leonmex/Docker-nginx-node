---
name: no_emojis_in_docs
description: User prefers no emoji characters in documentation output
metadata:
  type: feedback
---

No emoji characters in generated documentation files. User rejected document that used emoji indicators (✅, ❌, ❓, etc.).

**Why:** Cleaner, more professional technical documentation. Emoji noise detracts from readability in formal bug reports and technical guides.

**How to apply:** When generating .md files for documentation, use plain text alternatives:
- Instead of "✅ DONE" → use "DONE" or "Complete"
- Instead of "❌ FAILED" → use "FAILED" or "Broken"
- Instead of "⚠️ WARNING" → use "WARNING" or "Needs Investigation"
- Use text-only markers like "VERIFIED", "PENDING", "TODO", "BLOCKED"
