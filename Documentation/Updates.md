# Squirrel updates

Squirrel uses Sparkle 2.9.5 through the Xcode project's dependency integration,
following SwiftMiner's app-owned updater model. The native menu and application
menu both expose Check for Updates. Sparkle owns its scheduling and update UI;
Squirrel does not run a second update polling loop.

Squirrel uses the shared ShipHook Sparkle public key, matching the setup in
SwiftMiner. ShipHook holds the corresponding private key and handles building,
signing, notarization, release publishing, and appcast updates.

The configuration in `project.yml` is:

- `SPARKLE_FEED_URL`: `https://johnwatso.github.io/Squirrel/appcast.xml`
- `SPARKLE_PUBLIC_ED_KEY`: `rxaJsfCpTKtpqRubSfkJwKnztT5S8RHsdAueuT+jKck=`

Keep these settings in the committed Xcode project in sync by running
`xcodegen generate` after changing `project.yml`. Do not generate a separate
Squirrel signing key or manually edit ShipHook's appcast.

Before distributing a release, verify the built app's `SUFeedURL` and
`SUPublicEDKey`, and test an update between two ShipHook-signed builds.

Automatic checks default on once configured. Automatic downloading/installing
is not enabled by default: installing restarts Squirrel and briefly withdraws
its macOS power source. Schedule updates outside an outage.
