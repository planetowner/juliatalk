import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:juliatalk/features/auth/data/auth_session_store.dart';
import 'package:juliatalk/features/auth/domain/app_user.dart';
import 'package:juliatalk/features/auth/domain/auth_session.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
  });

  test('returns null when no saved session exists', () async {
    const AuthSessionStore store = AuthSessionStore();

    expect(await store.load(), isNull);
  });

  test('saves and restores the complete auth session', () async {
    const AuthSessionStore store = AuthSessionStore();
    const AuthSession session = AuthSession(
      accessToken: 'test-access-token',
      tokenType: 'bearer',
      user: AppUser(
        id: '11111111-1111-4111-8111-111111111111',
        username: 'test-user',
        displayName: 'June',
        profileImageUrl: 'https://example.com/profile.jpg',
        preferredLanguage: 'ko',
      ),
    );

    await store.save(session);

    final AuthSession? restoredSession = await store.load();

    expect(restoredSession, isNotNull);
    expect(restoredSession!.accessToken, session.accessToken);
    expect(restoredSession.tokenType, session.tokenType);
    expect(restoredSession.user.id, session.user.id);
    expect(restoredSession.user.username, session.user.username);
    expect(restoredSession.user.displayName, session.user.displayName);
    expect(restoredSession.user.profileImageUrl, session.user.profileImageUrl);
    expect(
      restoredSession.user.preferredLanguage,
      session.user.preferredLanguage,
    );
  });

  test('clear removes the saved session', () async {
    const AuthSessionStore store = AuthSessionStore();
    const AuthSession session = AuthSession(
      accessToken: 'test-access-token',
      tokenType: 'bearer',
      user: AppUser(
        id: '11111111-1111-4111-8111-111111111111',
        username: 'test-user',
        displayName: 'June',
        preferredLanguage: 'ko',
      ),
    );

    await store.save(session);
    await store.clear();

    expect(await store.load(), isNull);
  });
}
