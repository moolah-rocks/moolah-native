/// SF Symbol used for an account in the sidebar and in account-selection
/// pickers. Keep this mapping in one place so the sidebar and the pickers
/// stay in sync.
extension Account {
  var sidebarIcon: String {
    switch type {
    case .bank: return "building.columns"
    case .asset: return "house.fill"
    case .creditCard: return "creditcard"
    case .investment: return "chart.line.uptrend.xyaxis"
    // Sharing the .investment chart icon for now: the design treats
    // crypto wallets as in the `.investments` bucket. A dedicated crypto
    // SF Symbol can land in a UI follow-up once the wallet feature
    // surfaces a distinct visual identity.
    case .crypto: return "chart.line.uptrend.xyaxis"
    // Exchange accounts share the chart icon (also in the `.investments`
    // bucket); a dedicated exchange SF Symbol can land in a UI follow-up.
    case .exchange: return "chart.line.uptrend.xyaxis"
    }
  }
}
