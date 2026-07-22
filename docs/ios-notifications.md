# iOS Notifications

JuliaTalk uses iOS-rendered notification and call interfaces. It does not draw
a look-alike notification view inside Flutter. The implementation is split
between the FastAPI APNs sender, the Runner notification bridge, a Notification
Service Extension, and PushKit/CallKit.

## Implemented behavior

- Each direct message is delivered as its own alert. No APNs collapse ID is
  sent, so a later message does not replace an earlier one.
- Alerts from the same direct conversation share `thread-id`, which lets iOS
  apply its configured stack/list/count grouping.
- The Notification Service Extension converts an alert to an
  `INSendMessageIntent` communication notification and downloads the sender's
  profile image.
- Text and link alerts use the original message body. iOS controls visible
  truncation and expansion.
- Photo alerts show a localized summary and download the first photo or
  thumbnail as a notification attachment. Video and voice-memo alerts use a
  localized summary without playback or a media thumbnail.
- Text, photo, video, file, and voice-memo alerts expose a text-input reply
  action. The native bridge can post the reply even when Flutter was not
  already running.
- The app badge is the recipient's current unread message count.
- Tapping an alert opens the direct conversation for its sender after login.
- Lock-screen preview hiding and Face ID reveal are controlled by the user's
  iOS **Show Previews** setting. JuliaTalk does not bypass that privacy policy.
- An initial call event is sent with a PushKit token and immediately reported
  to CallKit. After that initial VoIP push, call termination is delivered over
  the authenticated `/ws` connection. A missed or unanswered call is then sent
  as a normal APNs alert.

Localized summaries are fixed to the verified reference behavior:

| Event | Korean | Simplified Chinese |
| --- | --- | --- |
| Photo | `사진을 보냈습니다.` | `照片` |
| Video | `동영상을 보냈습니다.` | `视频` |
| File | `파일: {파일명}` | `文件: {파일명}` |
| Voice memo | `음성메시지를 보냈습니다.` | `语音备忘录` |
| Missed call | `부재중 보이스톡` | `未接听语音通话` |
| Reply | `답장` | `答复` |
| Send | `전송` | `发送` |

## Apple Developer setup

The repository contains the targets and entitlement files, but the matching
App ID capabilities and provisioning profiles must also exist in the Apple
Developer account for team `57X5XDTF4Q`.

1. For `com.planetowner.juliatalk`, enable **Push Notifications** and
   **Communication Notifications**.
2. Keep the Runner background modes for **Voice over IP** and
   **Remote notifications** enabled.
3. Create or refresh the Runner development and distribution provisioning
   profiles after enabling those capabilities.
4. Create the extension App ID
   `com.planetowner.juliatalk.NotificationService`, enable
   **Communication Notifications**, and create its provisioning profiles.
5. Create an APNs token-signing key (`.p8`) that can send notifications for the
   app. Keep the key out of Git.
6. In Xcode, confirm that both targets resolve to the intended team and that
   automatic signing can select profiles containing the committed
   entitlements.

## Backend configuration

Set the following on the backend:

```text
APNS_KEY_ID=YOUR_KEY_ID
APNS_TEAM_ID=57X5XDTF4Q
APNS_BUNDLE_ID=com.planetowner.juliatalk
APNS_PRIVATE_KEY="-----BEGIN PRIVATE KEY-----\n...\n-----END PRIVATE KEY-----"
```

`APNS_PRIVATE_KEY_PATH=/secure/path/AuthKey_XXXX.p8` may be used instead of
`APNS_PRIVATE_KEY`. The production service must be able to read that path.
Debug app builds register sandbox tokens; profile/release builds register
production tokens. A token is always sent to the APNs host matching the
environment stored during registration.

On backend startup, the existing compatibility step adds the new installation,
VoIP-token, bundle-ID, and APNs-environment columns and their indexes to
`user_devices`.

## Call event contract

The existing message API starts an incoming voice call with:

```json
{
  "recipient_id": "RECIPIENT_UUID",
  "content": "",
  "message_type": "call",
  "metadata": {
    "kind": "voice",
    "outcome": "started",
    "duration_ms": 0
  }
}
```

The call message UUID is also the CallKit UUID. The sender may finish it with
`ended`, `cancelled`, or `no_answer`; the recipient may finish it with `ended`
or `missed` through `PATCH /messages/{message_id}/call-outcome`. Conflicting
final outcomes return HTTP 409.

The notification layer implements system call presentation and signaling. The
repository does not contain an RTC audio transport, media server, or audio
session that connects two answered callers. A production voice conversation
still requires that separate call-media layer before the CallKit answer action
should be considered connected.

## Commands to run locally

Run these manually from the repository root. They are intentionally listed
here because the project instructions require the developer, not Codex, to
execute terminal commands.

```bash
cd /Users/june/Desktop/projects/juliatalk
python3 -m pip install -r requirements.txt
python3 -m compileall app scripts
python3 -m unittest tests.test_translation tests.test_notifications
git diff --check

cd /Users/june/Desktop/projects/juliatalk/mobile
flutter pub get
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test
flutter build ios --debug --no-codesign \
  --dart-define=API_BASE_URL=https://YOUR_BACKEND_DOMAIN
```

`flutter build ios --debug --no-codesign` verifies compilation but not signing
or entitlement availability. Open `mobile/ios/Runner.xcodeproj` and run the
Runner scheme on a physical iPhone to verify APNs, PushKit, CallKit, Focus,
Face ID preview reveal, notification grouping, sounds, and badge behavior.
PushKit/CallKit delivery must be validated on a real device.

## Real-device matrix

Verify each item with the app in foreground, background, force-quit where iOS
permits delivery, and on the locked screen:

1. Korean and Chinese text, including a long message.
2. Photo, video, and voice memo summaries; only photo has a right-side and
   expanded attachment.
3. Reply from a temporary banner and from the expanded lock-screen alert.
4. Three sequential messages remain separate and expand from one iOS group.
5. **Show Previews: When Unlocked** hides content before Face ID and reveals it
   after authentication.
6. Incoming voice call while locked and unlocked, answer, reject, caller
   cancel, and caller timeout.
7. Missed-call alert in Korean and Simplified Chinese.
8. Notification-disabled, banner-disabled, sound-disabled, and badge-disabled
   system settings.
