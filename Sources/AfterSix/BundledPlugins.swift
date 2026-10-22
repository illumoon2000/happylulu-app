import AppPluginHost
import CPURunnerIntegration
#if HAPPY_LULU_DAOUOFFICE_ENABLED && canImport(DaouOfficeIntegration)
import DaouOfficeIntegration
#endif

/// The only composition boundary that knows which optional modules ship in this build.
@MainActor
enum BundledPlugins {
    static var modules: [any PluginModule.Type] {
        #if HAPPY_LULU_DAOUOFFICE_ENABLED && canImport(DaouOfficeIntegration)
        [CPURunnerModule.self, DaouOfficeModule.self]
        #else
        [CPURunnerModule.self]
        #endif
    }
    static func legacyDaouConfigured() throws -> Bool {
        #if HAPPY_LULU_DAOUOFFICE_ENABLED && canImport(DaouOfficeIntegration)
        try DaouOfficeModule.hasLegacyConfiguration()
        #else
        false
        #endif
    }
    static func register(in context: PluginHostContext, modules: [any PluginModule.Type] = BundledPlugins.modules,
                         onFailure: @MainActor () -> Void) {
        for module in modules {
            do { try context.install(module) }
            catch { onFailure() }
        }
    }
}
