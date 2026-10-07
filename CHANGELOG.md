# Changelog

All notable changes to Pullse are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versions follow
[Semantic Versioning](https://semver.org/). Every merge to main with notes under
Unreleased is released, and the headings decide the bump: Fixed or Security is a patch,
Added, Changed, Deprecated or Removed is a minor, and Breaking is a major.

## [Unreleased]

### Added
- A notification when one of your open pull requests becomes ready to merge: approved,
  no conflicts, not a draft, and every check green. It fires on the change, stays quiet
  while the pull request is still ready, and fires again if the pull request leaves that
  state and comes back. Turn it off under Notifications.

## [0.8.1] - 2026-09-28

### Security
- Clicking a notification or activity item only opens GitHub pages over https. A CI
  link set by the reporting integration to anything else (another site, `file://`,
  `smb://`, another app's URL scheme) now opens the pull request's checks page instead.

## [0.8.0] - 2026-09-28

### Changed
- Automatic updates wait while the menu or Settings is open, so Pullse never restarts
  while you're using it.

### Added
- "Notify me after Pullse updates" in Settings → Updates, to turn off the "Pullse updated
  to x.y.z" notification.

## [0.7.0] - 2026-09-28

### Added
- A downloaded copy that macOS runs from a temporary location (or from Downloads) offers
  to move itself to Applications, so it can update itself from then on. The update banner
  and Settings → Updates offer the same move instead of a Download button.

## [0.6.0] - 2026-09-24

### Added
- When "Check now" (or any check) finds a new version, the Updates tab shows it with
  What's new and Install buttons, so there's no need to go back to the menu.

## [0.5.0] - 2026-09-24

### Changed
- Updates are checked every hour instead of every 6 hours.

### Fixed
- "Checked … ago" in Settings now keeps counting instead of freezing at the time the
  window opened.

## [0.4.0] - 2026-09-24

### Changed
- Settings is split into tabs listed down the left: GitHub, Notifications (with the
  filters), Updates and App. A dot marks a tab that needs attention.

## [0.3.0] - 2026-09-24

### Added
- Right-click (or Control-click) the menu bar icon for a menu with About Pullse (opens
  the GitHub repository), Settings and Quit.

## [0.2.0] - 2026-09-24

### Changed
- "Clear" moved from Settings to the menu, next to "Mark all read".

## [0.1.0] - 2026-09-23

### Added
- Menu bar app that notifies about new comments, reviews, CI results and @mentions on
  your pull requests in one GitHub organization, each type toggleable.
- Bots are muted by default, with a toggle and per-repository muting.
- Menu listing recent activity grouped by pull request, with unread markers.
- Settings kept in `~/.config/pullse/settings.json`, outside the repository.
- Read-only GitHub access using the local `gh` login.
- Version shown in the app, update checks against GitHub releases, and optional automatic
  updates.
- GitHub Actions: pull requests are built and tested with downloadable artifacts, and
  every push to main with changelog notes is released automatically, with a version bump and
  notes from this changelog.
- A warning in the menu and in Settings when macOS isn't showing Pullse's notifications,
  with a button to the right System Settings page.
- "Send test notification" also adds a test item to the activity list, linking to the
  Pullse repository.
