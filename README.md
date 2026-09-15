# Offline + Online Flutter Notes App

## What it does
- Works without internet using SQLite on the device.
- Shows Online/Offline status.
- Saves notes locally first.
- Marks changed notes as unsynced.
- When online, the Sync button sends unsynced notes to `POST /api/sync`.

## Run
```bash
flutter pub get
flutter run
```

## APK
```bash
flutter build apk --release
```
APK: `build/app/outputs/flutter-apk/app-release.apk`

## Connect a real backend
Open `lib/main.dart` and change:
```dart
static const apiBaseUrl = 'https://example.com/api';
```
to your API URL.

The app expects:
```http
POST /api/sync
Content-Type: application/json
```
with:
```json
{"notes":[{"id":"...","title":"...","content":"...","updated_at":"..."}]}
```
Return any HTTP 2xx response after saving/upserting the notes.
