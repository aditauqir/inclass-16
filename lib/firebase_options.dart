import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;

/// Firebase configuration for In-Class Activity 16 Class A.
class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      default:
        throw UnsupportedError(
          'Firebase is only configured for Android in this classroom build.',
        );
    }
  }

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'AIzaSyB7TJNJAWKySXT0yMp-eLEeteYCUI3LkRE',
    appId: '1:1098740231106:android:4269b057f1b2773339445b',
    messagingSenderId: '1098740231106',
    projectId: 'cw-02-mad',
    storageBucket: 'cw-02-mad.firebasestorage.app',
  );
}
