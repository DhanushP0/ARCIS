# ARCIS

## Persistent AR waypoint anchors

Waypoints now store their Google Cloud Anchor ID in
`survey_nodes.cloud_anchor_id`. Run the updated [Supabase schema](./supabase/schema.sql)
to add this column to an existing database. New and re-anchored waypoints are
uploaded, and route navigation resolves saved anchors into the current AR
session before showing camera guidance.

Cloud Anchors require the Google Cloud ARCore Cloud Anchor API and platform
authentication to be configured. The plugin's iOS setup expects a
`cloudAnchorKey.json` service-account key in the Runner bundle; Android needs
the OAuth configuration described in the plugin's
[Cloud Anchor setup guide](https://pub.dev/packages/ar_flutter_plugin_plus).
The local iOS key file is excluded from Git and the Xcode Runner target now
includes the exact `cloudAnchorKey.json` filename in **Copy Bundle Resources**.
This puts the private key inside the app and makes it extractable, so do not
bundle it in any app distributed to other users.
The current plugin's iOS authentication flow expects this bundled key; use a
backend-based token flow or another plugin before production. Use a restricted
development project, and rotate/revoke the key if it was exposed. Anchors are
hosted for up to 365 days and must be resolved while they remain available.

## iOS Cloud Anchor authorization troubleshooting

The app uses a local fork of `ar_flutter_plugin_plus` in
`third_party/ar_flutter_plugin_plus`. Its iOS JWT uses the documented audience
`https://arcore.googleapis.com/` and a standard `JWT` header; the published
1.1.3 package used a different audience and could cause
`Authentication failed: Not Authorized`. If authorization still fails, confirm
the ARCore API is enabled for the service account's project and that the key is
valid. Do not distribute an app containing the private service-account key; use
a protected server to issue tokens for production.

For an end-to-end test:

1. Enable the ARCore Cloud Anchor API in the Google Cloud project for this key.
2. Run `supabase/schema.sql` in the Supabase SQL editor to add the stored anchor
   ID column.
3. Build and run on a physical iPhone. Place waypoints and wait for the app to
   confirm each anchor was saved to the cloud.
4. On the second device, open the same survey ID, select its current floor and
   starting point, then select the destination and start camera guidance. Test
   at the mapped physical location while the anchors are still valid.

If route setup reports that a waypoint could not be localized, resolving must
happen at the same physical place where the anchor was hosted. Scan that area
slowly with good lighting and visible detail, and confirm the device has
internet access. Native Cloud Anchor resolution failures are now returned to
the route UI immediately; if no resolution result arrives within 60 seconds,
the UI reports a localization timeout. Route anchors are resolved one at a time
to limit AR memory usage, and completed native Cloud Anchor tasks release their
retained listeners and resolve futures. Each placement also gets a unique local
AR anchor name; reusing a waypoint ID during re-anchoring could make the plugin
associate an upload callback with the wrong pending anchor.

Saved database coordinates are still only a route/map fallback. After a new AR
session, navigation uses the resolved Cloud Anchor poses, not old session-local
coordinates. On the route page, copy the survey ID from the mapping device and
open that shared ID on the other device. Select the starting point and final
current floor there, choose the starting waypoint on that floor, then choose
the final destination (which may be on another connected floor). The app loads
the shared survey graph and resolves only the selected route's Cloud Anchors.
Changing the selected floor in survey/route setup displays only that floor's
anchored waypoint models. During navigation it keeps only the final
destination's 3D marker visible while showing the camera arrow. A survey ID is
a locator, not secure access control: the current anonymous Supabase policies
allow public access and should be replaced with authenticated, survey-scoped
policies before production.
