# The first manual sweep

After `scripts/install.sh`, the tunnel hostnames and a green `scripts/smoke.sh`. About an
hour. Note anything off with the step number; a screenshot helps.

Use a normal browser window signed in to Twitch and Kick. Open the site at `https://cyex.tv`.

## 1. Sign-in and the owner
1. "Sign in" → Twitch. Twitch asks for consent once, then you're back on cyex.tv, signed in,
   with your Twitch name and avatar in the header.
2. Account page: link Kick. Kick's consent page, then back; both platforms are listed.
3. Sign out, sign in again with Kick: the same account (both platforms still listed).
4. The admin pages (`/admin`) open: you're the owner through `CYEX_TV_OWNER_IDS`. Roles shows
   the owner as protected.

## 2. Upload and review
1. Upload a static PNG, an animated GIF and an animated WebP (each under 5 MB, ideally square).
   Each shows as pending.
2. Within a minute each has its files: the emote page shows the image in every size. The URLs
   are `https://cdn.cyex.tv/emotes/<hash>/<size>.webp` (and `.avif`).
3. In another browser (signed out), the pending emotes aren't visible on search or their pages.
4. Admin → Review: approve two, reject one with a reason. The rejected owner view shows the
   reason; the approved ones are public now.
5. Upload the same file again: it's taken as a duplicate (same files, no second job).

## 3. Sets and channels
1. Your channel's set: add both approved emotes; rename one in the set.
2. Your sets → editors: add a second account (a test Twitch account) as editor; it can add and
   remove emotes in that set, and nothing else.
3. Your channels: Twitch and Kick channels listed, each with its active set.
4. From a signed-out window: `https://api.cyex.tv/v1/channels/twitch/<your twitch id>` shows
   the active set with the two emotes.

## 4. Live updates
1. Keep `/v1/channels/...` open in one tab and the set page in another. With the extension
   installed (step 6) and your chat open: remove an emote from the set; it stops rendering in
   chat within about a second, and comes back when you re-add it.

## 5. Moderation
1. From the test account, report one of the emotes with a reason.
2. Admin → Reports: the report is there. Take it down: the emote leaves every set, its owner
   gets a notification, and its CDN URL stops loading within a minute or so (the purge).
3. Upload the same image again from any account: refused as blocked.
4. Admin → Users: restrict the test account's uploads; its next upload is refused. Lift it.
5. Audit log: every action above is listed with who did it.

## 6. The browser extension
Load the unpacked build (`deploy-kit/extension/chrome` in `chrome://extensions` with developer
mode on; Firefox: `about:debugging` → This Firefox → Load Temporary Add-on → the `manifest.json`
in `deploy-kit/extension/firefox`). Then the extension's own checklist,
`cyex-tv/extension` `docs/test-checklist.md`, on three Twitch and two Kick channels.

## 7. Failure cases
1. Stop the worker for a minute (`docker compose -f compose/docker-compose.yaml stop worker`),
   upload, start it again: the upload finishes on its own.
2. Within 10 minutes of stopping events (`stop events`), the alert webhook posts; it posts
   "resolved" after `start events`.
3. Run `backups/backup.sh` by hand, then `backups/restore-test.sh`; write the date in
   `docs/restores.md`.

## 8. Phone
On a phone, at `https://cyex.tv`: search, an emote page, sign in, the upload page. Nothing
cut off or scrolling sideways.
