plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val ciDebugKeystoreFile = providers.environmentVariable("PINGPLACE_DEBUG_KEYSTORE_FILE")
    .orElse(providers.gradleProperty("pingplaceDebugKeystoreFile"))
    .orNull
val ciDebugStorePassword = providers.environmentVariable("PINGPLACE_DEBUG_KEYSTORE_PASSWORD")
    .orElse(providers.gradleProperty("pingplaceDebugKeystorePassword"))
    .orNull
val ciDebugKeyAlias = providers.environmentVariable("PINGPLACE_DEBUG_KEY_ALIAS")
    .orElse(providers.gradleProperty("pingplaceDebugKeyAlias"))
    .orNull
val ciDebugKeyPassword = providers.environmentVariable("PINGPLACE_DEBUG_KEY_PASSWORD")
    .orElse(providers.gradleProperty("pingplaceDebugKeyPassword"))
    .orNull
val hasCiDebugSigning = listOf(
    ciDebugKeystoreFile,
    ciDebugStorePassword,
    ciDebugKeyAlias,
    ciDebugKeyPassword,
).all { !it.isNullOrBlank() }
val requireCiDebugSigning = providers.environmentVariable("PINGPLACE_REQUIRE_CI_DEBUG_SIGNING")
    .orNull == "true"

if (requireCiDebugSigning && !hasCiDebugSigning) {
    error("PINGPLACE_REQUIRE_CI_DEBUG_SIGNING is enabled, but the complete CI signing environment is missing")
}

android {
    namespace = "com.example.pingplace"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.pingplace"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasCiDebugSigning) {
            create("ciDebug") {
                storeFile = file(ciDebugKeystoreFile!!)
                storePassword = ciDebugStorePassword!!
                keyAlias = ciDebugKeyAlias!!
                keyPassword = ciDebugKeyPassword!!
            }
        }
    }

    buildTypes {
        getByName("debug") {
            if (hasCiDebugSigning) {
                signingConfig = signingConfigs.getByName("ciDebug")
            }
        }
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

flutter {
    source = "../.."
}

dependencies {
    implementation("androidx.core:core-ktx:1.15.0")
    implementation("com.google.android.gms:play-services-location:21.3.0")
}
