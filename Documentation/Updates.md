# Squirrel updates

Squirrel uses Sparkle 2.9.5 through the Xcode project's dependency integration,
following SwiftMiner's app-owned updater model. The native menu and application
menu both expose Check for Updates. Sparkle owns its scheduling and update UI;
Squirrel does not run a second update polling loop.

Development builds leave the feed and signing key empty and report that updates
are unavailable. They do not contact another application's feed.

Before the first GitHub release:

0. Set `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml` for the
   release (the development value is 0.1.0, build 1) and regenerate the project.
1. Generate a **Squirrel-specific** EdDSA signing key with Sparkle's
   `generate_keys` tool. Keep the private key in the release signing environment
   or Keychain, outside this repository.
2. Set `SPARKLE_FEED_URL` to the public HTTPS appcast URL and
   `SPARKLE_PUBLIC_ED_KEY` to the public key in `project.yml` (or supply the build
   settings in the release build). Regenerate with `xcodegen generate`.
3. Sign and notarize the app with the release identity. Publish signed release
   archives on GitHub and generate the appcast with Sparkle's `generate_appcast`.
   Appcast versions must match the version/build of the exact signed archive.
4. Verify the built app's `SUFeedURL` and `SUPublicEDKey`, serve the appcast, and
   test an update between two signed builds before distributing it.

Automatic checks default on once configured. Automatic downloading/installing
is not enabled by default: installing restarts Squirrel and briefly withdraws
its macOS power source. Schedule updates outside an outage.

No appcast, release URL, private signing key, or published release is invented
by the development setup.
