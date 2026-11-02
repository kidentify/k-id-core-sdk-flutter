# k_id_core example

An app with the age gate and the settings menu. Register the bundle id and package name `com.kid.core.flutter.example`
on your test key in Kai, then run it with that key:

```sh
flutter run --dart-define=KID_PUBLISHABLE_KEY=kgp_test_...
```

On the web, add the page's origin (for example `http://localhost:8080`) to the key and run
`flutter run -d chrome --web-port 8080 --dart-define=KID_PUBLISHABLE_KEY=kgp_test_...`.
