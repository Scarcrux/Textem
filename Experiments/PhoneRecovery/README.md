# Phone conversation previews

This implementation replaces the empty phone-only surface when no existing
linked image or supported saved preview is available. Existing preview/image
paths keep their behavior. A linked notification source takes priority on reopen.

## Current path

- Android companion v0.14 captures only content already exposed to its approved
  notification listener. Its private atomic journal retains up to four snapshots
  per source, 32 overall, eight MiB overall, and seven days at the next write.
  Count/byte/age eviction is reported as `dropped`; this is not proof of lossless
  notification delivery. The worker queue is bounded and reports unavailable on
  overflow. Distinct sources no longer cancel each other's queued capture.
- In a selected, verified phone-only web route, **Read phone preview** reads the
  journal over the explicitly paired local HTTPS connection (or a separately
  configured developer transport). Select a source,
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
  Pause with the toggle in the conversation’s options menu (…). Route/account changes or closing the pane cancel pending
  publication. Transfers verify the current route before and after fetching.
- The private Mac cache retains up to four snapshots per linked conversation,
  20 links, 16 MiB overall. A full library refuses further writes and preserves
  existing content. **Phone → Saved Conversation Previews…** opens a read-only,
  account-scoped cache in the conversation surface, even after restarting Textem
  while Google is stuck trying to reach the phone. This path requires neither
  Google navigation nor the phone. Labels identify library entries for display;
  they never establish routes or create links. Live linking and refresh still
  require a verified Google route.
- Text stays literal, with explicit HTTPS links. Supported PNGs are validated and
  rendered as notification-level pictures; missing references explain the limit.
  **Shared graphics** in the options menu opens the existing explicit image library.
- Normal live and saved views combine overlapping observations only when source,
  installation, nonzero message time, text and truncation state match. Repeated
  occurrences within a capture are retained, as are unknown-time messages and
  same-text messages at different times. Original snapshots and picture
  observations remain intact. **Show original captures** in the options menu
  exposes every saved observation. This presentation does not establish full
  history, individual picture attachments or message direction.
- Refresh is in the header; connection setup, shared graphics, automatic refresh,
  original captures and unlinking are in the options menu. Unlinked source
  inspection still requires the same explicit route-validated confirmation.
- Unlink deletes this conversation's preview cache. Removing an account deletes
  its preview records. This mapping does not authorize code AutoFill. Turning off
  phone capture/content or deleting saved notification content clears the phone
  journal. Already imported Mac copies require unlink/deletion on the Mac.

## Release gates still open

This is partial preview recovery. The signed app has verified paired HTTPS
delivery and refresh into a bound pane, plus visible offline retention. Cold
offline rendering through the new saved library remains a separate live gate.
It does not retrieve past
RCS history from Google, continuously sync a complete inbox, reproduce full
business cards/actions, or establish background/event reliability merely from a
successful connection.
The libgm helper remains disabled in normal launches. No additional pairing,
permissions or competing Google relay is started by selecting a conversation.

Synthetic store/model/render controls and a no-UI handset instrumentation runner
validate the mechanism. Actual selected business-thread linkage/reopen, graphics,
reconnect and web-inbox coexistence still need live evidence; do not substitute
the tests for those release criteria. See `PREREGISTRATION.md`.
