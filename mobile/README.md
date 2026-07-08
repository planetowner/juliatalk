# JuliaTalk Mobile

Flutter client for JuliaTalk.

## Run Against Local Backend

Start the FastAPI backend first from the repository root:

```bash
python -m uvicorn app.main:app --host 127.0.0.1 --port 8000
```

Install Flutter dependencies from this directory:

```bash
flutter pub get
```

Then run Flutter with `API_BASE_URL`.

iOS simulator or Chrome on the same machine:

```bash
flutter run --dart-define=API_BASE_URL=http://127.0.0.1:8000
```

Android emulator:

```bash
flutter run --dart-define=API_BASE_URL=http://10.0.2.2:8000
```

Physical phone on the same Wi-Fi:

Start the backend on all interfaces:

```bash
python -m uvicorn app.main:app --host 0.0.0.0 --port 8000
```

Then run Flutter from this directory:

```bash
flutter run --dart-define=API_BASE_URL=http://YOUR_COMPUTER_LAN_IP:8000
```

Make sure your computer firewall allows the phone to reach port `8000`.

## Test

```bash
flutter analyze
flutter test
```
