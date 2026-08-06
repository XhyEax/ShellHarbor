# Prebuilt BoringSSL

`CCryptoBoringSSL.xcframework` contains the iOS device and Apple Silicon iOS
Simulator static libraries used by the vendored Swift Crypto package. Keeping
this C/C++ layer prebuilt prevents every clean ShellHarbor iOS build from
compiling the hundreds of vendored BoringSSL translation units again.

The library was built from Swift Crypto 3.15.1, whose vendored BoringSSL
revision is `0226f30467f540a3f62ef48d453f93927da199b6`. It combines the
`CCryptoBoringSSL` and `CCryptoBoringSSLShims` archives; the framework module
map exposes both Clang modules so the upstream Swift sources remain unchanged.

When Swift Crypto or Xcode's target ABI is upgraded, regenerate both slices
from the matching upstream sources and replace the complete XCFramework.
