import Foundation

/// Data a malware scan must never offer for removal, whatever matched it:
/// crypto wallets (apps and browser extension storage), browser profiles
/// (passwords, cookies, extension data), Keychains, Telegram, Notes and
/// password managers. Losing it is worse than leaving a false positive in
/// place: a wallet folder in the Trash can be emptied with the only copy of
/// the keys. `MalwareModule.makeReport` turns hits here into informational
/// advisories instead.
public enum ProtectedUserData {
    /// Chromium extension ids of crypto wallets. Their `Local Extension
    /// Settings/<id>` / `IndexedDB` folders hold the encrypted vault, and
    /// stealers target exactly these ids.
    public static let walletExtensionIDs: [String: String] = [
        "nkbihfbeogaeaoehlefnkodbefgpgknn": "MetaMask",
        "bfnaelmomeimhlpmgjnjophhpkkoljpa": "Phantom",
        "bhhhlbepdkbapadjdnnojkbgioiodbic": "Solflare",
        "hnfanknocfeofbddgcijnmhnfnkdnaad": "Coinbase Wallet",
        "egjidjbpglichdcondbcbdnbeeppgdph": "Trust Wallet",
        "ibnejdfjmmkpcnlpebklmnkoeoihofec": "TronLink",
        "acmacodkjbdgmoleebolmdjonilkdbch": "Rabby",
        "dmkamcknogkgcdfhhbddcghachkejeap": "Keplr",
        "aholpfdialjgjfhomihkjbmgjidlcdno": "Exodus Web3",
        "mcohilncbfahbmgdjkbpemcciiolgcge": "OKX Wallet",
        "fnjhmkhhmkbjkkabndcnnogagogbneec": "Ronin",
        "fhbohimaelbohpjbbldcngcnapndodjp": "Binance Wallet",
        "aflkmfhebedbjioipglgcbcmnbpgliof": "Backpack",
        "jiidiaalihmmhddjgbnbgdfflelocpak": "Bitget Wallet",
        "ejjladinnckdgjemekebdpeokbikhfci": "Petra",
        "ffnbelfdoeiohenkjibnmadjiehjhajb": "Yoroi",
        "lpfcbjknijpeeillifnkikgncikgfhdo": "Nami",
        "dlcobpjiigpikoobohmabehhmhfoodbb": "Argent X",
    ]

    /// Browser data folders, relative to home. Everything inside is
    /// protected except the code of individual extensions
    /// (`…/Extensions/<id>/…`), so a malicious extension can still go.
    static let browserRoots: [String] = [
        "Library/Application Support/Google/Chrome",
        "Library/Application Support/Google/Chrome Beta",
        "Library/Application Support/Google/Chrome Dev",
        "Library/Application Support/Google/Chrome Canary",
        "Library/Application Support/Chromium",
        "Library/Application Support/BraveSoftware",
        "Library/Application Support/Microsoft Edge",
        "Library/Application Support/Microsoft Edge Beta",
        "Library/Application Support/Microsoft Edge Dev",
        "Library/Application Support/Arc",
        "Library/Application Support/Vivaldi",
        "Library/Application Support/com.operasoftware.Opera",
        "Library/Application Support/com.operasoftware.OperaGX",
        "Library/Application Support/Yandex",
        "Library/Application Support/Firefox",
        "Library/Application Support/zen",
        "Library/Application Support/Orion",
        "Library/Safari",
        "Library/Containers/com.apple.Safari",
        "Library/Cookies",
    ]

    /// Wallets, secrets and messaging data, relative to home.
    static let dataRoots: [String] = [
        // Wallet apps
        "Library/Application Support/atomic",
        "Library/Application Support/Exodus",
        "Library/Application Support/Electrum",
        ".electrum",
        "Library/Application Support/MyMonero",
        "Library/Application Support/Trezor Suite",
        "Library/Application Support/@trezor",
        "Library/Application Support/Ledger Live",
        "Library/Application Support/Guarda",
        "Library/Application Support/Coinomi",
        "Library/Application Support/Bitcoin",
        "Library/Application Support/Litecoin",
        "Library/Application Support/DashCore",
        "Library/Application Support/Ethereum",
        "Library/Application Support/Electron Cash",
        "Library/Application Support/monero-project",
        "Library/Application Support/Daedalus Mainnet",
        "Library/Application Support/Sparrow",
        ".sparrow",
        ".walletwasabi",
        "Library/Application Support/WalletWasabi",
        "Library/Application Support/com.liberty.jaxx",
        "Library/Application Support/Binance",
        "Library/Application Support/Tonkeeper",
        // Secrets
        "Library/Keychains",
        "Library/Group Containers/2BUA8C4S2C.com.1password",
        "Library/Containers/com.1password.1password",
        "Library/Application Support/Bitwarden",
        "Library/Containers/com.bitwarden.desktop",
        // Messaging and notes
        "Library/Application Support/Telegram Desktop",
        "Library/Group Containers/6N38VWS5BX.ru.keepcoder.Telegram",
        "Library/Containers/ru.keepcoder.Telegram",
        "Library/Containers/org.telegram.desktop",
        "Library/Group Containers/group.com.apple.notes",
        "Library/Containers/com.apple.Notes",
    ]

    /// Absolute system-wide roots.
    static let systemRoots: [String] = ["/Library/Keychains"]

    public static func isProtected(_ url: URL, home: URL = MCConstants.home) -> Bool {
        isProtected(path: url.path(percentEncoded: false), home: home.path(percentEncoded: false))
    }

    /// True when `path` is inside protected data, *or contains it* (removing
    /// `~/Library/Application Support` would take every wallet with it).
    /// Case-insensitive, like the default APFS volume.
    public static func isProtected(path: String, home: String) -> Bool {
        let lower = canonical(path)
        let components = lower.split(separator: "/")
        if components.contains(where: { walletExtensionIDs[String($0)] != nil }) { return true }
        let homeRoot = canonical(home)

        for relative in browserRoots {
            let root = homeRoot + "/" + relative.lowercased()
            if root.hasPrefix(lower + "/") || lower == root { return true }
            if lower.hasPrefix(root + "/") {
                // Inside a browser: only extension code may be offered.
                let inner = lower.dropFirst(root.count + 1).split(separator: "/")
                if let index = inner.firstIndex(of: "extensions"), inner.count > index + 1 { continue }
                return true
            }
        }
        let roots = dataRoots.map { homeRoot + "/" + $0.lowercased() } + systemRoots.map { $0.lowercased() }
        return roots.contains { root in
            lower == root || lower.hasPrefix(root + "/") || root.hasPrefix(lower + "/")
        }
    }

    static func canonical(_ path: String) -> String {
        var p = (path as NSString).standardizingPath.lowercased()
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        return p
    }
}
