# JuliaTalk Mobile

Flutter client for JuliaTalk.

## Run Against Deployed Backend

Install Flutter dependencies from this directory:

```bash
flutter pub get
```

Run the app with the deployed backend URL:

```bash
flutter run --dart-define=API_BASE_URL=https://YOUR_BACKEND_DOMAIN
```

Use the same value for release builds:

```bash
flutter build apk --dart-define=API_BASE_URL=https://YOUR_BACKEND_DOMAIN
flutter build ios --dart-define=API_BASE_URL=https://YOUR_BACKEND_DOMAIN
```

`API_BASE_URL` must be an absolute `http` or `https` URL.

## Test

```bash
flutter analyze
flutter test
```
