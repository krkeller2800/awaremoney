#if canImport(Testing)
import Testing
@testable import DebtScope

@Suite("DebtScope Fuzzy Search Tests")
struct DebtScopeFuzzySearchTests {
    @Test("Exact and case-insensitive matches still work")
    func exactAndCaseInsensitiveMatchesStillWork() {
        #expect(DebtScopeFuzzySearch.matches(query: "visa", values: ["Rewards Visa Card"]))
        #expect(DebtScopeFuzzySearch.matches(query: "123.45", values: ["$123.45"]))
    }

    @Test("Typo-tolerant token matching finds likely account and payee results")
    func typoTolerantTokenMatchingFindsLikelyResults() {
        #expect(DebtScopeFuzzySearch.matches(query: "capitol", values: ["Capital One Quicksilver"]))
        #expect(DebtScopeFuzzySearch.matches(query: "netflx", values: ["Netflix.com"]))
        #expect(DebtScopeFuzzySearch.matches(query: "chse crd", values: ["Chase Credit Card"]))
    }

    @Test("Multiple query tokens must each match")
    func multipleQueryTokensMustEachMatch() {
        #expect(DebtScopeFuzzySearch.matches(query: "cap one", values: ["Capital One Checking"]))
        #expect(!DebtScopeFuzzySearch.matches(query: "cap mortgage", values: ["Capital One Checking"]))
    }

    @Test("Very short unrelated queries do not fuzzy match")
    func veryShortUnrelatedQueriesDoNotFuzzyMatch() {
        #expect(!DebtScopeFuzzySearch.matches(query: "x", values: ["Checking Account"]))
        #expect(!DebtScopeFuzzySearch.matches(query: "zz", values: ["Checking Account"]))
    }
}
#endif
