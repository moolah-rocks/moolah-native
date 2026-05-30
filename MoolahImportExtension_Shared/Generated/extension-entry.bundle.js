// Single NSExtensionJavaScriptPreprocessingFile loaded by Safari for the
// Moolah action extension. PluginManifestGen concatenates each plugin's
// `parser.js` after this file and rewrites the `const plugins = {};`
// declaration below to map host strings to plugin classes.
//
// DO NOT rename the marker comments — `JSBundleEmitter` matches them
// literally.

class MoolahDispatch {
  run(args) {
    const host = location.host;
    // The build step appends each plugin class and replaces this map.
    /* GENERATED-PLUGIN-MAP-START */
    const plugins = {};
    /* GENERATED-PLUGIN-MAP-END */
    const match = Object.entries(plugins).find(
      ([h]) => host === h || host.endsWith("." + h));
    if (!match) { args.completionFunction({ error: "no-plugin", host }); return; }
    new match[1]().run(args);
  }
  finalize(args) { /* unused */ }
}
var ExtensionPreprocessingJS = new MoolahDispatch();


