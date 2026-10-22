import AppPluginHost
import CPURunnerIntegration
#if HAPPY_LULU_DAOUOFFICE_ENABLED && canImport(DaouOfficeIntegration)
import DaouOfficeIntegration
#endif

#if HAPPY_LULU_AI_USAGE_ENABLED && canImport(AIUsageIntegration)
import AIUsageIntegration
#endif

/// The only composition boundary that knows which optional modules ship in this build.
@MainActor
enum BundledPlugins {
    static var modules: [any PluginModule.Type] {
        var result: [any PluginModule.Type] = [CPURunnerModule.self]
        #if HAPPY_LULU_DAOUOFFICE_ENABLED && canImport(DaouOfficeIntegration)
        result.append(DaouOfficeModule.self)
        #endif
        #if HAPPY_LULU_AI_USAGE_ENABLED && canImport(AIUsageIntegration)
        result.append(AIUsageModule.self)
        #endif
        return result
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
