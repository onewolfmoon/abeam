const { notarize } = require("@electron/notarize");

// electron-builder afterSign hook. Requires a notarytool keychain profile
// created once via:
//   xcrun notarytool store-credentials "blittie-notarize" \
//     --apple-id <your-apple-id> --team-id <TEAMID> --password <app-specific-password>
// Override the profile name with APPLE_KEYCHAIN_PROFILE if you named it
// something else. Skip notarizing (e.g. local dev builds) with SKIP_NOTARIZE=1.
exports.default = async function notarizing(context) {
  const { electronPlatformName, appOutDir } = context;
  if (electronPlatformName !== "darwin") return;
  if (process.env.SKIP_NOTARIZE) return;

  const appName = context.packager.appInfo.productFilename;
  const appPath = `${appOutDir}/${appName}.app`;
  console.log(`[notarize] submitting ${appPath} to Apple notary service...`);

  await notarize({
    appBundleId: context.packager.config.appId,
    appPath,
    keychainProfile: process.env.APPLE_KEYCHAIN_PROFILE || "blittie-notarize",
  });
  console.log("[notarize] done");
};
