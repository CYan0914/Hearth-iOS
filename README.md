# Hearth — iOS client

The iPhone app for Hearth: Home Inventory. Photograph an appliance's model plate, get a maintenance schedule built from it, and get told when something is due.

This is the client only. It talks to the API at `https://hearth.taomindapp.com/v1` and keeps no database of its own — every screen is a read of the server, and the server owns the maintenance knowledge base, the schedule, and the recall corpus.

## Requirements

- iOS 16.0 or later
- Xcode 15 or later (CI selects Xcode 26+, which is what App Store uploads need)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) — `brew install xcodegen`

There is no `.xcodeproj` in the repository. `project.yml` is the project; the Xcode project is generated from it. That keeps the diff readable and means a merge conflict in project settings is a conflict in a five-line YAML block rather than in a 40,000-line pbxproj.

## Building

The usual path is CI, because an App Store build needs a Mac with a current Xcode and this project has none.

```bash
xcodegen generate
open Hearth.xcodeproj
```

Or from the command line, for a compile check with no signing:

```bash
xcodegen generate
xcodebuild build \
  -project Hearth.xcodeproj \
  -scheme Hearth \
  -sdk iphonesimulator \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```

### The API host

`HearthAPIBase` is read from the built `Info.plist` at launch, injected from the `HEARTH_API_BASE` build setting in `project.yml`. The client refuses to start if it is missing or unsubstituted rather than failing later with an unhelpful "unsupported URL". To point a build at a staging server, override the setting:

```bash
xcodebuild build ... HEARTH_API_BASE=https://staging.example.com/v1
```

## Releases

`.github/workflows/build.yml` holds both jobs. It is one workflow on purpose: a compile check and an archive split across two files are two things to watch, and the failure mode is watching the wrong one.

| Dispatch input | What runs |
|---|---|
| `create_ipa` unset or `false` (default) | Simulator compile only. This is also what every push to `main` runs. |
| `create_ipa=true` | Archive, export a signed IPA, upload to TestFlight. |

The archive job needs three repository secrets: `APPSTORE_KEY_ID`, `APPSTORE_ISSUER_ID`, and `APPSTORE_API_KEY` (the contents of the App Store Connect `.p8`). Without them it fails rather than producing an unsigned artifact, because an unsigned IPA cannot be uploaded and a green run that produced one would be misleading.

The build number is `github.run_number`, which is monotonic. Reusing a build number inside a version train is rejected on upload with a 409.

### Signing

The app declares two capabilities, both of which must be enabled on the App ID `com.cyan0914.hearth` before the archive job will sign:

- Sign in with Apple
- Push Notifications

`Resources/Hearth.entitlements` is the source of truth for what the app asks for. Adding a capability there without enabling it on the App ID makes signing fail — which is the right order of failure, since the alternative is a build that installs and then silently never receives a reminder.

## Layout

```
App/        entry point, root routing, theme
Models/     the wire types, decoded straight from the API
Services/   API client, session and keychain, Apple sign-in, OCR, photo upload, push
Views/      one file per screen
Resources/  Info.plist, entitlements, asset catalogue
```

`Services/HearthAPI.swift` is the only place that knows the API's shape. Two things about it are easy to get wrong and are commented where they live:

- Several request models are `extra="forbid"` on the server, so a field the client invents is a 422 rather than an ignored key.
- PATCH bodies carry `PatchField`, because the server reads *presence* rather than difference — an absent key leaves a column alone while an explicit `null` clears it. A bare optional in Swift cannot express both, since the encoder omits nil, so clearing a field would appear to work while changing nothing.

## Backend

The API lives in a separate repository (`hearth-api`). Nothing here is useful without it.
