#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROJECT_DIR="$ROOT_DIR/mobile/android-local"
ANDROID_JAR="/usr/lib/android-sdk/platforms/android-23/android.jar"
DX="/usr/lib/android-sdk/build-tools/debian/dx"
APK_NAME="BadmintonTournament-Android12-local.apk"

rm -rf "$PROJECT_DIR/build"
mkdir -p "$PROJECT_DIR/assets" "$PROJECT_DIR/build/gen" "$PROJECT_DIR/build/obj" "$PROJECT_DIR/build/pkg" "$PROJECT_DIR/dist" "$ROOT_DIR/dist"
cp "$ROOT_DIR/tournament.html" "$PROJECT_DIR/assets/index.html"

aapt package -f -m   -J "$PROJECT_DIR/build/gen"   -M "$PROJECT_DIR/AndroidManifest.xml"   -S "$PROJECT_DIR/res"   -I "$ANDROID_JAR"

javac -source 8 -target 8   -bootclasspath "$ANDROID_JAR"   -classpath "$ANDROID_JAR"   -d "$PROJECT_DIR/build/obj"   $(find "$PROJECT_DIR/src" "$PROJECT_DIR/build/gen" -name '*.java')

"$DX" --dex --output="$PROJECT_DIR/build/classes.dex" "$PROJECT_DIR/build/obj"

aapt package -f   -M "$PROJECT_DIR/AndroidManifest.xml"   -S "$PROJECT_DIR/res"   -A "$PROJECT_DIR/assets"   -I "$ANDROID_JAR"   -F "$PROJECT_DIR/build/unsigned.apk"

(cd "$PROJECT_DIR/build" && aapt add unsigned.apk classes.dex >/dev/null)
zipalign -f 4 "$PROJECT_DIR/build/unsigned.apk" "$PROJECT_DIR/build/aligned.apk"

if [ ! -f "$PROJECT_DIR/local-release.keystore" ]; then
  keytool -genkeypair -v     -keystore "$PROJECT_DIR/local-release.keystore"     -storepass tournamentapp     -keypass tournamentapp     -alias tournamentapp     -keyalg RSA     -keysize 2048     -validity 10000     -dname "CN=Tournament App, OU=Local, O=TournamentApp, L=Local, S=Local, C=US"
fi

apksigner sign   --ks "$PROJECT_DIR/local-release.keystore"   --ks-pass pass:tournamentapp   --key-pass pass:tournamentapp   --out "$PROJECT_DIR/dist/$APK_NAME"   "$PROJECT_DIR/build/aligned.apk"

apksigner verify --print-certs "$PROJECT_DIR/dist/$APK_NAME"
cp "$PROJECT_DIR/dist/$APK_NAME" "$ROOT_DIR/dist/$APK_NAME"
ls -lh "$ROOT_DIR/dist/$APK_NAME"
