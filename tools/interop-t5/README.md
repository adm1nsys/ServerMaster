# T5 production codec harness

This console harness links the existing Windows model/store/localization source files unchanged. It does not build WinUI or emulate Windows GUI behavior. `PlatformStubs.cs` supplies only UI/Storage type boundaries; fixture stores use an isolated `SERVERMASTER_DATA_DIR`. Run it through the Swift test, which creates its input files and removes its fixtures.

Requires .NET SDK 8 and Xcode. The .NET SDK is a test dependency only. Before first SDK use, disable telemetry and automatic ASP.NET development-certificate creation. Keep SDK/build caches outside the checkout:

```sh
export DOTNET_CLI_TELEMETRY_OPTOUT=1
export DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1
export DOTNET_GENERATE_ASPNET_CERTIFICATE=false
interop_root=$(mktemp -d /tmp/servermaster-interop.XXXXXX)
export DOTNET_CLI_HOME="$interop_root/sdk-home"
export NUGET_PACKAGES="$interop_root/nuget"
dotnet build tools/interop-t5/Interop.csproj \
  --output "$interop_root/harness" \
  -p:BaseIntermediateOutputPath="$interop_root/obj/" \
  -p:UseSharedCompilation=false
TEST_RUNNER_SERVERMASTER_TEST_DOTNET="$(command -v dotnet)" \
TEST_RUNNER_SERVERMASTER_TEST_INTEROP="$interop_root/harness/Interop.dll" \
xcodebuild -quiet -project macos/ServerMaster.xcodeproj -scheme ServerMaster \
  -configuration Debug -derivedDataPath "$interop_root/derived" \
  -destination 'platform=macOS,arch=arm64' test \
  -only-testing:ServerMasterTests/ProfileTransferTests \
  -only-testing:ServerMasterTests/CrossPlatformTransferTests \
  CODE_SIGNING_ALLOWED=NO
```

The shown destination is the tested Apple Silicon host; select a matching destination on another Mac. Keep the temporary directory until inspecting results, then remove only that directory. The harness must not be run with the real user data directory. Do not use global certificate cleanup or package-management commands as test cleanup.

The Swift suite runs the harness twice: initial C# import/export and `verify-return`. It checks supported fields and records known Windows template/PHP limitations explicitly. The ordinary Swift test run skips the C# suite unless the two TEST_RUNNER variables are supplied; validation tests still run.
