  import Foundation
  import SwiftData
  import PDFKit

  // MARK: - Quick Ingest Models

  public enum QuickIngestAccountType: String, Sendable {
      case checking
      case savings
      case creditCard
      case loan
      case brokerage
      case other
  }

  public struct QuickIngestHints: Sendable {
      public var institution: String?
      public var accountType: QuickIngestAccountType?

      public init(institution: String? = nil, accountType: QuickIngestAccountType? = nil) {
          self.institution = institution
          self.accountType = accountType
      }
  }

  public struct QuickIngestResult {
      let account: Account
      public let balance: Decimal
      public let balanceAsOf: Date
      public let typicalPayment: Decimal?
      public let aprFraction: Decimal?
      public let aprScale: Int?
      public let paymentDueDate: Date?
      let batch: ImportBatch?
  }

  public enum QuickIngestError: Error, LocalizedError {
      case missingBalance
      case parsingFailed(String)

      public var errorDescription: String? {
          switch self {
          case .missingBalance: return "No usable balance could be determinedfrom this file."
          case .parsingFailed(let msg): return "Parsing failed: \(msg)"
          }
      }
  }

  // MARK: - Service Protocol

  public protocol QuickIngesting {
      func ingest(url: URL, hints: QuickIngestHints, context: ModelContext)
  async throws -> QuickIngestResult
  }

  // MARK: - Service Implementation

public final class QuickIngestor: QuickIngesting {
    
    public init() {}
    
    @MainActor
    public func ingest(url: URL, hints: QuickIngestHints, context:
                       ModelContext) async throws -> QuickIngestResult {
        let existingCompletedImportCount = ((try? context.fetch(FetchDescriptor<ImportBatch>())) ?? [])
            .filter { batch in
                batch.dataSetRaw != "sample"
                    && (!batch.transactions.isEmpty || !batch.balances.isEmpty || !batch.holdings.isEmpty)
            }
            .count
        PurchaseManager.shared.synchronizeInitialFreeImportUsage(existingImportCount: existingCompletedImportCount)
        guard PurchaseManager.shared.isPremiumUnlocked else {
            throw QuickIngestError.parsingFailed("Trial imports used. Unlock Lifetime Premium to continue importing statements and building your local plan.")
        }

        // 1. Classification and Detection
        let classifier = StatementIntakeClassifier()
        let detection = await classifier.classify(url: url)
        
        let institutionHint = hints.institution ?? detection.institution
        let accountTypeHint: Account.AccountType? = {
            if let hint = hints.accountType { return hint.toAccountType() }
            return detection.type?.toAccountType()
        }()
        
        // 2. Import and Extraction
        let importer = StatementImporter()
        let userOverride: StatementImporter.UserOverride? = {
            switch accountTypeHint {
            case .creditCard: return .creditCard
            case .loan: return .loan
            case .checking, .savings: return .bank
            case .brokerage: return .brokerage
            default: return nil
            }
        }()
        
        // Use background task for heavy parsing
        let (staged, fullText) = try await Task.detached(priority:.userInitiated) {
            let result = try await importer.importStatement(from: url, prefer:.transactions, userOverride: userOverride)
            
            var augmentedRows = result.rows
            let fullText = await PDFTextExtractor.extractText(from: url)
            
            if let fullText {
                if let interestSection = await PDFTextExtractor.extractInterestChargesSection(from: fullText) {
                    augmentedRows.append([interestSection])
                }
                if let balanceSection = await PDFTextExtractor.extractBalanceSummarySection(from: fullText) {
                    augmentedRows.append([balanceSection])
                }
                let accountSummaries = await PDFTextExtractor.extractAccountSummarySections(from: fullText)
                for section in accountSummaries {
                    augmentedRows.append([section])
                }
                augmentedRows.append([fullText])
            }
            
            var staged: StagedImport
            do {
                let summaryParser = await PDFSummaryParser()
                staged = try await summaryParser.parse(rows: augmentedRows, headers:result.headers)
            } catch {
                let parser = await MainActor.run {
                    ImportViewModel.defaultParsers().first { $0.canParse(headers: result.headers) }
                }
                if let parser {
                    staged = try await parser.parse(rows: augmentedRows, headers: result.headers)
                } else {
                    throw QuickIngestError.parsingFailed("No matching parser found for this file.")
                }
            }
            
            staged.sourceFileName = url.lastPathComponent
            return (staged, fullText)
        }.value
        
        var processedStaged = staged
        
        // 3. Normalization and Deduplication
        applyHintsAndNormalization(to: &processedStaged, accountTypeHint:accountTypeHint)
        
        if accountTypeHint == .creditCard {processedStaged.balances = deduplicateStagedBalancesForCreditCard(processedStaged.balances)
        } else {
            processedStaged.balances = deduplicateStagedBalancesPreferringNonZeroSameDay(processedStaged.balances)
        }
        
        // 4. APR and Payment Enhancement (PDF only)
        var preferredAPR: (Decimal, Int)? = nil
        var paymentDueDate: Date? = nil
        
        if let fullText {
            preferredAPR = PDFTextExtractor.extractPreferredAPR(from:fullText)
            paymentDueDate = extractPaymentDueDate(from: fullText)
            
            if let (apr, scale) = preferredAPR, accountTypeHint == .creditCard {
                for i in processedStaged.balances.indices {
                    if processedStaged.balances[i].interestRateAPR == nil || apr < processedStaged.balances[i].interestRateAPR! {
                        processedStaged.balances[i].interestRateAPR = apr
                        processedStaged.balances[i].interestRateScale = scale
                    }
                }
            }
        }
        
        // 5. Routing and Persistence
        let routingService = ImportRoutingService()
        var (_, plans) = routingService.buildPlans(staged:processedStaged, context: context)
        
        // Override plans based on hints if routing was ambiguous
        plans = applyRoutingOverrides(plans: plans, hints: hints, context:context)
        
        let resolvedAccounts = try routingService.resolveAccounts(
            for: plans,
            institution: institutionHint,
            currencyCode: "USD",
            context: context,
            applyInstitutionToExisting: true
        )
        
        // We pick the primary account (usually the only one or the first in Quick Ingest)
        guard let primaryLabel = plans.first?.label,
              let account = resolvedAccounts[primaryLabel] else {
            throw QuickIngestError.parsingFailed("Could not resolve an account for this statement.")
        }
        
        // 6. Find Ending Balance
        guard let latestBalance = processedStaged.balances.sorted(by: {
            $0.asOfDate > $1.asOfDate }).first else {
            throw QuickIngestError.missingBalance
        }
        
        // 7. Final Persistence (Batch & Snapshot)
        let batch = ImportBatch(
            label: processedStaged.sourceFileName,
            sourceFileName: processedStaged.sourceFileName,
            parserId: processedStaged.parserId,
            sourceFileLocalPath: url.path // Caller handled caching prior to invoking ingest()
        )
        context.insert(batch)
        
        let snapshot = BalanceSnapshot(
            asOfDate: latestBalance.asOfDate,
            balance: latestBalance.balance,
            interestRateAPR: latestBalance.interestRateAPR,
            interestRateScale: latestBalance.interestRateScale,
            account: account,
            importBatch: batch
        )
        context.insert(snapshot)
        
        // Update account terms
        var terms = account.loanTerms ?? LoanTerms()
        if let apr = latestBalance.interestRateAPR {
            terms.apr = apr
            terms.aprScale = latestBalance.interestRateScale
        }
        if let payment = latestBalance.typicalPaymentAmount {
            terms.paymentAmount = payment
        }
        account.loanTerms = terms
        
        // Negative Amortization Guard
        if let payment = terms.paymentAmount, let apr = terms.apr, apr > 0 {
            let monthlyInterest = (apr / 12) * latestBalance.balance.magnitude
            if payment < monthlyInterest {
                AMLogging.log("QuickIngestor: Warning - typical payment \(payment) is less than estimated first month's interest \(monthlyInterest)", component: "QuickIngest")
            }
        }
        
        try context.save()
        _ = PurchaseManager.shared.recordCompletedImportIfNeeded()
        
        return QuickIngestResult(
            account: account,
            balance: latestBalance.balance,
            balanceAsOf: latestBalance.asOfDate,
            typicalPayment: latestBalance.typicalPaymentAmount,
            aprFraction: latestBalance.interestRateAPR,
            aprScale: latestBalance.interestRateScale,
            paymentDueDate: paymentDueDate,
            batch: batch
        )
    }
    
    // MARK: - Private Helpers
    
    private func applyHintsAndNormalization(to staged: inout StagedImport,accountTypeHint: Account.AccountType?) {
        let type = accountTypeHint ?? .other
        
        // Apply liability safety net for CC/Loan
        if type == .creditCard || type == .loan {
            let nonLiabilityLabels: Set<String> = ["checking", "savings","brokerage", "investment"]
            let areAllNonLiability = staged.balances.allSatisfy { balance in
                let label = (balance.sourceAccountLabel ?? "default").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return nonLiabilityLabels.contains(label) || label == "default"
            }
            
            if areAllNonLiability {
                let sentinel = "__typical_payment__"
                for i in staged.balances.indices {
                    let lbl = (staged.balances[i].sourceAccountLabel ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    if lbl == sentinel { continue }
                    staged.balances[i].sourceAccountLabel = (type == .loan) ? "loan" : "creditcard"
                }
            }
        } else {
            // Normalize bank balances to positive (non-liability convention)
            for i in staged.balances.indices {
                if staged.balances[i].balance < 0 {
                    staged.balances[i].balance = -staged.balances[i].balance
                }
            }
        }
    }
    
    private func deduplicateStagedBalancesPreferringNonZeroSameDay(_ snaps:[StagedBalance]) -> [StagedBalance] {
        if snaps.isEmpty { return snaps }
        var chosen: [String: StagedBalance] = [:]
        var order: [String] = []
        let cal = Calendar.current
        for snap in snaps {
            let label = (snap.sourceAccountLabel ?? "default").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let dayStart = cal.startOfDay(for: snap.asOfDate).timeIntervalSince1970
            let key = "\(label)|\(Int(dayStart))"
            if let existing = chosen[key] {
                if existing.balance == .zero && snap.balance != .zero {
                    chosen[key] = snap
                }
            } else {
                chosen[key] = snap
                order.append(key)
            }
        }
        return order.compactMap { chosen[$0] }
    }
    
    private func deduplicateStagedBalancesForCreditCard(_ snaps:[StagedBalance]) -> [StagedBalance] {
        if snaps.isEmpty { return snaps }
        var chosen: [Int: StagedBalance] = [:]
        var order: [Int] = []
        let cal = Calendar.current
        for snap in snaps {
            let dayStart = cal.startOfDay(for:snap.asOfDate).timeIntervalSince1970
            let key = Int(dayStart)
            if let existing = chosen[key] {
                let e = existing.balance
                let s = snap.balance
                if e == .zero && s != .zero {
                    chosen[key] = snap
                } else if e != .zero && s != .zero {
                    if (e >= 0 && s < 0) {
                        chosen[key] = snap
                    }
                }
            } else {
                chosen[key] = snap
                order.append(key)
            }
        }
        return order.compactMap { chosen[$0] }
    }
    
    @MainActor
    private func applyRoutingOverrides(plans:[ImportRoutingService.RoutedClusterPlan], hints: QuickIngestHints, context:ModelContext) -> [ImportRoutingService.RoutedClusterPlan] {
        guard let institution = hints.institution, let type = hints.accountType?.toAccountType() else { return plans }
        
        var updatedPlans = plans
        for i in updatedPlans.indices {
            let plan = updatedPlans[i]
            
            // If the current candidate is already a matching existing account, leave it
            var alreadyMatches = false
            if case .existing(let id, _) = plan.candidate.action {
                let predicate = #Predicate<Account> { $0.id == id }
                if let matched = try? context.fetch(FetchDescriptor<Account>(predicate: predicate)).first {
                    if matched.institutionName == institution && matched.type == type {
                        alreadyMatches = true
                    }
                }
            }
            if alreadyMatches { continue }
            
            // Try to find a better existing account match for this  institution + type
            let predicate = #Predicate<Account> { $0.institutionName == institution }
            let existingAccounts = (try? context.fetch(FetchDescriptor<Account>(predicate: predicate))) ?? []
            
            if let bestMatch = existingAccounts.first(where: { $0.type == type }) {
                let candidate = RoutingCandidate(
                    action: .existing(accountID: bestMatch.id, name:bestMatch.name),
                    confidence: 1.0,
                    reason: "User hint matched existing account"
                )
                updatedPlans[i] = ImportRoutingService.RoutedClusterPlan(
                    label: plan.label,
                    candidate: candidate,
                    transactions: plan.transactions,
                    balances: plan.balances,
                    holdings: plan.holdings
                )
            } else {
                // Otherwise, ensure we create a new one with the correct type
                let candidate = RoutingCandidate(
                    action: .createNew(type: type),
                    confidence: 0.9,
                    reason: "User hint preferred this account type"
                )
                updatedPlans[i] = ImportRoutingService.RoutedClusterPlan(
                    label: plan.label,
                    candidate: candidate,
                    transactions: plan.transactions,
                    balances: plan.balances,
                    holdings: plan.holdings
                )
            }
        }
        return updatedPlans
    }
    
    private func extractPaymentDueDate(from text: String) -> Date? {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(secondsFromGMT: 0)
        
        // Patterns from PDFSummaryParser mirrored for regex text extraction
        let patterns = [#"(?:payment\s+due\s+date|payment\s+due|due\s+date)\s*[:\-]?\s*(\d{1,2}/\d{1,2}/\d{2,4})"#,
                        #"(?:payment\s+due\s+date|payment\s+due|due\s+date)\s*[:\-]?\s*([A-Za-z]{3,9}\s+\d{1,2}(?:,\s*\d{4})?)"#]
        
        for pattern in patterns {
            if let rx = try? NSRegularExpression(pattern: pattern, options:[.caseInsensitive]),
               let m = rx.firstMatch(in: text, options: [], range:NSRange(text.startIndex..<text.endIndex, in: text)),m.numberOfRanges >= 2,
               let range = Range(m.range(at: 1), in: text) {
                let dateStr = String(text[range])
                for fmt in ["MM/dd/yyyy", "M/d/yy", "MM/dd/yy", "M/d/yyyy","MMMM d, yyyy", "MMM d, yyyy"] {
                    df.dateFormat = fmt
                    if let d = df.date(from: dateStr) { return d }
                }
            }
        }
        return nil
    }
}

extension QuickIngestAccountType {
    func toAccountType() -> Account.AccountType {
        switch self {
        case .checking: return .checking
        case .savings: return .savings
        case .creditCard: return .creditCard
        case .loan: return .loan
        case .brokerage: return .brokerage
        case .other: return .other
        }
    }
}

  extension StatementType {
      func toAccountType() -> Account.AccountType {
          switch self {
          case .bank: return .checking
          case .creditCard: return .creditCard
          case .loan: return .loan
          case .brokerage: return .brokerage
          }
      }
  }

extension StatementType {
    /// Maps a high-level statement type to a QuickIngestAccountType hint.
    /// - Parameter bankSubtype: Optional subtype override when the statement type is `.bank`.
    ///   Pass `nil` (the default) to allow Quick Ingest to infer checking vs savings per cluster.
    /// - Returns: A QuickIngestAccountType when appropriate, or `nil` to leave type inference to the ingestor.
    func toQuickIngestAccountType(bankSubtype: QuickIngestAccountType? = nil) -> QuickIngestAccountType? {
        switch self {
        case .creditCard: return .creditCard
        case .loan:       return .loan
        case .brokerage:  return .brokerage
        case .bank:
            // When a PDF may contain both checking and savings, returning nil lets routing infer per cluster.
            return bankSubtype
        }
    }
}
