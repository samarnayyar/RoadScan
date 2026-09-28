import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.roadscan.roadscan"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // flutter_local_notifications uses java.time APIs (for scheduling) that
        // do not exist below Android 8. Desugaring back-ports them into the
        // APK. Without it the build fails at :app:checkDebugAarMetadata.
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.roadscan.roadscan"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // Google Maps key, read from android/local.properties -- which is
        // gitignored -- and injected into the manifest.
        //
        // It cannot come through --dart-define like the Supabase values do:
        // the Maps SDK reads its key from AndroidManifest meta-data at
        // startup, long before any Dart runs, so it has to be a build-time
        // manifest placeholder. Putting it in the manifest directly would
        // commit a live key to the repository.
        //
        // Absent, the placeholder resolves empty and the Google view renders
        // a blank grey tile while the rest of the app works normally. That is
        // the right failure: a missing key is a setup step, not a crash.
        val localProps = Properties()
        val localPropsFile = rootProject.file("local.properties")
        if (localPropsFile.exists()) {
            localPropsFile.inputStream().use { localProps.load(it) }
        }
        manifestPlaceholders["MAPS_API_KEY"] =
            localProps.getProperty("maps.apiKey") ?: ""
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    // Required by the isCoreLibraryDesugaringEnabled flag above.
    // flutter_local_notifications requires 2.1.4 or newer; older versions
    // build but omit some of the java.time back-ports it calls at runtime.
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

flutter {
    source = "../.."
}

