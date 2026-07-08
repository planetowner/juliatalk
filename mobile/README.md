# JuliaTalk Mobile

Flutter client for JuliaTalk.

## Run Against Local Backend

Start the FastAPI backend first from the repository root:

```powershell
python -m uvicorn app.main:app --host 127.0.0.1 --port 8000
```

Then run Flutter with `API_BASE_URL`.

Android emulator:

```powershell
flutter run --dart-define=API_BASE_URL=http://10.0.2.2:8000
```

iOS simulator, Windows desktop, or Chrome on the same machine:

```powershell
flutter run --dart-define=API_BASE_URL=http://127.0.0.1:8000
```

Physical phone on the same Wi-Fi:

```powershell
flutter run --dart-define=API_BASE_URL=http://YOUR_COMPUTER_LAN_IP:8000
```

If using a physical phone, start the backend on all interfaces:

```powershell
python -m uvicorn app.main:app --host 0.0.0.0 --port 8000
```

## Test

```powershell
flutter analyze
flutter test
```
