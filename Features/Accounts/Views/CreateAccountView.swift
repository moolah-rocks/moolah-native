import SwiftUI

struct CreateAccountView: View {
  @Environment(\.dismiss) private var dismiss

  @State private var name = ""
  @State private var type: AccountType = .bank
  @State private var currency: Instrument
  @State private var balanceDecimal: Decimal = 0
  @State private var date = Date()
  @State private var isSubmitting = false
  @State private var errorMessage: String?
  @FocusState private var focusedField: Field?

  // MARK: - Crypto-only form state
  //
  // Held at this level so the shared shell (Cancel + Save toolbar) and
  // the shared name + type Picker keep one set of bindings regardless of
  // which type is currently selected. Switching from `.crypto` back to
  // `.bank` simply hides these fields; the values are preserved so the
  // user can flip back without retyping.

  @State private var cryptoChain: ChainConfig = .ethereum
  @State private var cryptoWalletAddress = ""

  // MARK: - Exchange-only form state
  //
  // Lifted to the shell for the same reason as the crypto state above:
  // one set of bindings across type switches; the shared Cancel/Create
  // toolbar and shared name + type Picker stay type-agnostic.

  @State private var exchangeProvider: ExchangeProvider = .coinstash
  @State private var exchangeToken = ""

  let instrument: Instrument
  let accountStore: AccountStore
  let cryptoSyncStore: SyncedAccountStore?

  private enum Field: Hashable {
    case name
    case balance
    case walletAddress
    case exchangeToken
  }

  init(
    instrument: Instrument,
    accountStore: AccountStore,
    cryptoSyncStore: SyncedAccountStore? = nil
  ) {
    self.instrument = instrument
    self.accountStore = accountStore
    self.cryptoSyncStore = cryptoSyncStore
    _currency = State(initialValue: instrument)
  }

  var body: some View {
    NavigationStack {
      form
    }
    #if os(macOS)
      .frame(minWidth: 500, minHeight: 400)
    #endif
  }

  private var form: some View {
    Form {
      Section {
        sharedFields
        if type == .crypto {
          cryptoFields
        } else if type != .exchange {
          standardFields
        }
      }
      // The exchange branch renders its own Section (it carries a footer
      // — the read-only-token safety note); it can't nest inside the
      // shared Section above.
      if type == .exchange {
        ExchangeAccountCreationView(
          provider: $exchangeProvider,
          token: $exchangeToken)
      }
      if let errorMessage {
        Section {
          Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
            .font(.caption)
        }
      }
    }
    .formStyle(.grouped)
    .navigationTitle("Create Account")
    #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
    #endif
    #if os(macOS)
      .defaultFocus($focusedField, .name)
    #endif
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button("Cancel") { dismiss() }
      }
      ToolbarItem(placement: .confirmationAction) {
        Button("Create") { Task { await submit() } }
          .disabled(!isValid || isSubmitting)
      }
    }
  }

  // Shared name + type picker. The crypto branch reuses both, so they
  // live above the type-specific fork.
  @ViewBuilder private var sharedFields: some View {
    TextField("Name", text: $name, prompt: Text(namePrompt))
      .focused($focusedField, equals: .name)
      .onSubmit {
        switch type {
        case .crypto: focusedField = .walletAddress
        case .exchange: focusedField = .exchangeToken
        default: focusedField = .balance
        }
      }
      .accessibilityLabel("Account name")

    Picker("Account Type", selection: $type) {
      ForEach(AccountType.allCases, id: \.self) { type in
        Text(type.displayName).tag(type)
      }
    }
  }

  @ViewBuilder private var standardFields: some View {
    InstrumentPickerField(label: "Currency", kinds: [.fiatCurrency], selection: $currency)

    TextField(
      "Initial Balance",
      value: $balanceDecimal,
      format: .number.precision(.fractionLength(currency.decimals))
    )
    .monospacedDigit()
    .focused($focusedField, equals: .balance)
    #if os(iOS)
      .keyboardType(.decimalPad)
      .multilineTextAlignment(.trailing)
    #endif
    .accessibilityLabel("Initial balance")

    DatePicker("Opening Date", selection: $date, displayedComponents: .date)
  }

  @ViewBuilder private var cryptoFields: some View {
    CryptoAccountCreationView(
      chain: $cryptoChain,
      walletAddressInput: $cryptoWalletAddress)
  }

  private var namePrompt: String {
    switch type {
    case .crypto: return "e.g. Hardware Wallet — Ethereum"
    case .exchange: return "e.g. \(exchangeProvider.displayName)"
    default: return "e.g. MyBank - Savings"
    }
  }

  private var isValid: Bool {
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedName.isEmpty else { return false }
    if type == .crypto {
      return Account.validatedWalletAddress(cryptoWalletAddress) != nil
    }
    if type == .exchange {
      return !exchangeToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    return true
  }

  private func submit() async {
    guard isValid else { return }

    isSubmitting = true
    errorMessage = nil

    if type == .crypto {
      await submitCrypto()
      isSubmitting = false
      return
    }

    if type == .exchange {
      await submitExchange()
      isSubmitting = false
      return
    }

    let selectedInstrument = currency
    let openingBalance = InstrumentAmount(quantity: balanceDecimal, instrument: selectedInstrument)
    let newAccount = Account(
      id: UUID(),
      name: name.trimmingCharacters(in: .whitespaces),
      type: type,
      instrument: selectedInstrument,
      position: 0  // Server will set appropriate position
    )

    do {
      _ = try await accountStore.create(newAccount, openingBalance: openingBalance)
      dismiss()
    } catch {
      errorMessage = error.localizedDescription
      isSubmitting = false
    }
  }

  private func submitCrypto() async {
    let logic = CryptoAccountCreationLogic(
      accountStore: accountStore,
      cryptoSyncStore: cryptoSyncStore,
      accountInstrument: instrument)
    let outcome = await logic.submit(
      name: name, chain: cryptoChain, walletAddressInput: cryptoWalletAddress)
    switch outcome {
    case .created:
      dismiss()
    case .invalidAddress:
      errorMessage = "Enter a valid 0x wallet address."
    case .failure(let error):
      errorMessage = error.localizedDescription
    }
  }

  private func submitExchange() async {
    // No env/session here — construct the production token store the same
    // way `ProfileSession` does (iCloud-synced keychain). The account is
    // denominated in the profile currency (`instrument`), exactly as the
    // crypto path passes `accountInstrument: instrument`. The shared
    // `SyncedAccountStore` (`cryptoSyncStore`) drives the initial sync.
    let logic = ExchangeAccountCreationLogic(
      accountStore: accountStore,
      tokenStore: ExchangeTokenStore(synchronizable: true),
      syncStore: cryptoSyncStore,
      profileInstrument: instrument)
    let outcome = await logic.submit(
      name: name, provider: exchangeProvider, token: exchangeToken)
    switch outcome {
    case .created:
      dismiss()
    case .invalidInput:
      errorMessage = "Enter your read-only API token."
    case .failure(let error):
      errorMessage = error.localizedDescription
    }
  }
}

#Preview {
  let backend = PreviewBackend.create()
  let accountStore = AccountStore(
    repository: backend.accounts,
    conversionService: backend.conversionService,
    targetInstrument: .AUD)

  CreateAccountView(
    instrument: .AUD, accountStore: accountStore)
}
