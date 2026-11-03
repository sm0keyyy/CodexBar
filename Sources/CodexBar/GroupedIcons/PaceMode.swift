enum PaceMode {
    @MainActor static func isActive(settings: SettingsStore, store: UsageStore) -> Bool {
        settings.mergeIcons && settings.menuBarGroupsProviderIcons
            && store.enabledFirstPartyProvidersForDisplay().count >= 2
    }
}
