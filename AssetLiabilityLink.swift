import SwiftData
import Foundation

@Model final class AssetLiabilityLink {
    // Relationship to the asset account
    var asset: Account
    
    // Relationship to the liability account
    var liability: Account
    
    // The date when the link starts
    var startDate: Date
    
    // The optional date when the link ends
    var endDate: Date?
    
    // Memberwise initializer to create a link between an asset and a liability account
    init(asset: Account, liability: Account, startDate: Date, endDate: Date? = nil) {
        self.asset = asset
        self.liability = liability
        self.startDate = startDate
        self.endDate = endDate
    }
}
