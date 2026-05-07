import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../cloud/api.dart';

enum AuthStage { unknown, signedOut, awaitingCode, signedIn }

class AuthState {
  final AuthStage stage;
  final String? email;
  final Map<String, dynamic>? user;
  final String? error;

  const AuthState({
    required this.stage,
    this.email,
    this.user,
    this.error,
  });

  AuthState copyWith({AuthStage? stage, String? email, Map<String, dynamic>? user, String? error}) =>
      AuthState(
        stage: stage ?? this.stage,
        email: email ?? this.email,
        user: user ?? this.user,
        error: error,
      );

  static const initial = AuthState(stage: AuthStage.unknown);
}

class AuthController extends StateNotifier<AuthState> {
  final WhoopsieApi _api;
  AuthController(this._api) : super(AuthState.initial) {
    _restore();
  }

  Future<void> _restore() async {
    final token = await _api.getToken();
    if (token == null) {
      state = state.copyWith(stage: AuthStage.signedOut);
      return;
    }
    try {
      final user = await _api.me();
      if (user == null) {
        state = state.copyWith(stage: AuthStage.signedOut);
      } else {
        state = state.copyWith(stage: AuthStage.signedIn, user: user);
      }
    } catch (_) {
      state = state.copyWith(stage: AuthStage.signedOut);
    }
  }

  Future<void> requestOtp(String email) async {
    state = state.copyWith(error: null);
    try {
      await _api.requestOtp(email);
      state = state.copyWith(stage: AuthStage.awaitingCode, email: email);
    } catch (e) {
      state = state.copyWith(error: e.toString());
    }
  }

  Future<void> verifyOtp(String code, {String? displayName}) async {
    final email = state.email;
    if (email == null) return;
    state = state.copyWith(error: null);
    try {
      final user = await _api.verifyOtp(email, code, displayName: displayName);
      state = state.copyWith(stage: AuthStage.signedIn, user: user);
    } catch (e) {
      state = state.copyWith(error: e.toString());
    }
  }

  Future<void> signOut() async {
    await _api.signOut();
    state = const AuthState(stage: AuthStage.signedOut);
  }

  void resetToEmail() {
    state = state.copyWith(stage: AuthStage.signedOut, error: null);
  }
}

final authControllerProvider =
    StateNotifierProvider<AuthController, AuthState>((ref) => AuthController(ref.read(apiProvider)));
