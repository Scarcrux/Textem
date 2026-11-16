# Phone conversation previews

This implementation replaces the empty phone-only surface when no existing
linked image or supported saved preview is available. Existing preview/image
paths keep their behavior. A linked notification source takes priority on reopen.

## Current path

- Android companion v0.12 captures only content already exposed to its approved
  notification listener. Its private atomic journal retains up to four snapshots
  per source, 32 overall, eight MiB overall, and seven days at the next write.
  Count/byte/age eviction is reported as `dropped`; this is not proof of lossless
  notification delivery. The worker queue is bounded and reports unavailable on
  overflow. Distinct sources no longer cancel each other's queued capture.
- In a selected, verified phone-only web route, **Read phone preview** reads the
  journal over the existing authenticated developer transport. Select a source,
  inspect its actual preview, and confirm **This belongs here — link and refresh
  previews**. Brand/title matching never creates a link.
- The binding includes an account/route digest and installation/source digest.
- Journal retrieval accepts a fresh, stable `SAVED` or `SOURCE_REQUIRED` status:
  the latter describes a latest unidentified event, not deletion of earlier
  identified captures. Journal writes and captures may be up to seven days old;
  expiry is measured against the current time without refreshing capture dates.
  Permission/deletion states, malformed journals and transfer races still fail
  closed. The separate latest-notification/AutoFill reader retains its stricter
  `SAVED`-only and 30-minute freshness rules.
  Only the confirmed source is refreshed every 15 seconds while its pane is open.
  Pause with the toggle. Route/account changes or closing the pane cancel pending
  publication. Transfers verify the current route before and after fetching.
- The private Mac cache retains up to four snapshots per linked conversation,
  20 links, 16 MiB overall. A full library refuses further writes and preserves
  existing content. Reopening reads the cache without requiring the phone.
- Text stays literal, with explicit HTTPS links. Supported PNGs are validated and
  rendered as notification-level pictures; missing references explain the limit.
  **Shared graphics** opens the existing explicit image library.
- Unlink deletes this conversation's preview cache. Removing an account deletes
  its preview records. This mapping does not authorize code AutoFill. Turning off
  phone capture/content or deleting saved notification content clears the phone
  journal. Already imported Mac copies require unlink/deletion on the Mac.

## Release gates still open

This is developer-connected partial preview recovery. It does not retrieve past
RCS history from Google, continuously sync a complete inbox, reproduce full
business cards/actions, or remove the need for a production companion transport.
The libgm helper remains disabled in normal launches. No additional pairing,
permissions or competing Google relay is started by selecting a conversation.

Synthetic store/model/render controls and a no-UI handset instrumentation runner
validate the mechanism. Actual selected business-thread linkage/reopen, graphics,
reconnect and web-inbox coexistence still need live evidence; do not substitute
the tests for those release criteria. See `PREREGISTRATION.md`.
