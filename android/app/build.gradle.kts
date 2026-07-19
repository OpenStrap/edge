import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    // START: FlutterFire Configuration
    id("com.google.gms.google-services")
    id("com.google.firebase.firebase-perf")
    id("com.google.firebase.crashlytics")
    // END: FlutterFire Configuration
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing. Locally this reads android/key.properties; in CI the same values
// arrive as env vars (the workflow decodes the keystore from a secret). If neither is
// present we fall back to debug signing so a plain `flutter run` still works.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}
fun signingValue(propKey: String, envKey: String): String? =
    keystoreProperties.getProperty(propKey) ?: System.getenv(envKey)
val hasReleaseSigning =
    signingValue("storeFile", "ANDROID_KEYSTORE_PATH") != null

android {
    namespace = "wtf.openstrap.openstrap_edge"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // Required by ota_update 7.x (desugars java.time/java.nio APIs on older API levels).
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "wtf.openstrap.openstrap_edge"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = maxOf(26, flutter.minSdkVersion) // Health Connect requires API 26+
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // Retain FULL native debug symbols in the release bundle so Play Console
        // AND Crashlytics can symbolicate native/ANR frames. Without this, ANRs
        // sampled in native code (e.g. libm.so __kernel_rem_pio2 / sin / cos, and
        // the Dart AOT frames in libapp.so) show up as raw addresses / blank
        // frames with "root cause unknown" — which is exactly why the v42 staging
        // ANRs on 0.9.13 were unsymbolicated and hard to triage.
        ndk {
            debugSymbolLevel = "FULL"
        }
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                storeFile = file(signingValue("storeFile", "ANDROID_KEYSTORE_PATH")!!)
                storePassword = signingValue("storePassword", "ANDROID_KEYSTORE_PASSWORD")
                keyAlias = signingValue("keyAlias", "ANDROID_KEY_ALIAS")
                keyPassword = signingValue("keyPassword", "ANDROID_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            // Use the real release key when it's configured (local key.properties or CI
            // env), otherwise fall back to debug so `flutter run --release` still works.
            signingConfig = if (hasReleaseSigning) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
            // Upload native symbols to Crashlytics on release builds so ANR/native
            // stacks resolve to real frames instead of "root cause unknown". Pairs
            // with debugSymbolLevel=FULL above. (The Dart AOT layer — libapp.so —
            // additionally needs `flutter build … --split-debug-info=build/symbols`
            // and a `firebase crashlytics:symbols:upload` step in CI; see release
            // docs. Uncaught Dart exceptions already symbolicate via the Flutter
            // error handler — this is specifically for the sampled native/ANR path.)
            configure<com.google.firebase.crashlytics.buildtools.gradle.CrashlyticsExtension> {
                nativeSymbolUploadEnabled = true
            }
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    // Backs isCoreLibraryDesugaringEnabled (required by ota_update 7.x).
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    // KeepAliveWorker (service watchdog). The workmanager Flutter plugin ships the
    // runtime transitively, but as an `implementation` dep it isn't visible to app
    // code at compile time — declare it explicitly for our native Worker.
    implementation("androidx.work:work-runtime-ktx:2.9.1")
}
