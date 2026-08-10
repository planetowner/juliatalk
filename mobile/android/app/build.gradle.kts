plugins {
    id("com.android.application")
    id("kotlin-android")
    // Flutter 플러그인은 Android와 Kotlin 플러그인이 준비된 뒤 적용해야 해요.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.planetowner.juliatalk"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "com.planetowner.juliatalk"
        minSdk = 23
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // 현재 release 빌드는 로컬 실행을 위해 디버그 키로 서명해요.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}
