import Foundation

extension CostUsagePricing {
    package struct GrokTokens {
        package let fresh: Double
        package let output: Double
        package let cacheRead: Double
        package let cacheCreation: Double

        package init(fresh: Double, output: Double, cacheRead: Double, cacheCreation: Double) {
            self.fresh = fresh
            self.output = output
            self.cacheRead = cacheRead
            self.cacheCreation = cacheCreation
        }
    }

    package struct GrokResolver {
        private let catalog: ModelsDevCatalog?
        package let fingerprint: String

        // Provider-specific by design: Grok fingerprints and resolves only xAI's catalog, never another vendor's prices.
        package init(cacheRoot: URL? = nil) {
            let artifact = ModelsDevCache.load(cacheRoot: cacheRoot).artifact
            self.catalog = artifact?.catalog
            self.fingerprint = CostUsagePricingKey.codex(
                modelsDevArtifact: artifact,
                formulaVersion: 1,
                modelsDevProviderIDs: ["xai"],
                customPricingFingerprint: "")
        }

        init(catalog: ModelsDevCatalog?) {
            self.catalog = catalog
            self.fingerprint = ""
        }

        package func rates(model: String, promptTokens: Double = 0) -> GroupedCostPriceTable.Rates? {
            let canonical = GroupedCostPriceTable.canonicalModel(model)
            let lookup = self.catalog?.pricing(providerID: "xai", modelID: model)
                ?? self.catalog?.pricing(providerID: "xai", modelID: canonical)
            guard let pricing = lookup?.pricing else {
                return GroupedCostPriceTable.rates(model: model, promptTokens: promptTokens)
            }
            if let threshold = pricing.thresholdTokens, promptTokens >= Double(threshold) {
                return .init(
                    input: (pricing.inputCostPerTokenAboveThreshold ?? pricing.inputCostPerToken) * 1_000_000,
                    output: (pricing.outputCostPerTokenAboveThreshold ?? pricing.outputCostPerToken) * 1_000_000,
                    cached: (pricing.cacheReadInputCostPerTokenAboveThreshold
                        ?? pricing.cacheReadInputCostPerToken ?? pricing.inputCostPerToken) * 1_000_000)
            }
            // models.dev can omit xAI's inclusive long-context tier. Keep the official tuple intact.
            if pricing.thresholdTokens == nil, promptTokens >= 200_000,
               let official = GroupedCostPriceTable.rates(model: model, promptTokens: promptTokens)
            {
                return official
            }
            let fallback = GroupedCostPriceTable.rates(model: model)
            return .init(
                input: pricing.inputCostPerToken * 1_000_000,
                output: pricing.outputCostPerToken * 1_000_000,
                cached: pricing.cacheReadInputCostPerToken.map { $0 * 1_000_000 }
                    ?? fallback?.cached ?? pricing.inputCostPerToken * 1_000_000)
        }

        package func cost(model: String, tokens: GrokTokens) -> Double? {
            guard let rates = self.rates(
                model: model,
                promptTokens: tokens.fresh + tokens.cacheRead + tokens.cacheCreation) else { return nil }
            return ((tokens.fresh + tokens.cacheCreation) * rates.input
                + tokens.output * rates.output + tokens.cacheRead * rates.cached) / 1_000_000
        }
    }

    // Provider-specific by design: Native Grok unknown-model refreshes must stay in xAI's catalog.
    package static func refreshGrokPricingIfNeeded(now: Date, unpricedModels: [String] = []) async {
        await ModelsDevPricingPipeline.refreshIfNeeded(now: now)
        if !unpricedModels.isEmpty {
            _ = await ModelsDevPricingPipeline.refreshForUnknownModelsIfNeeded(
                providerID: "xai",
                modelIDs: Set(unpricedModels.map(GroupedCostPriceTable.canonicalModel)),
                now: now)
        }
    }
}
