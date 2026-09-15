//  VaultProviderFactory.swift
//  Turning a saved configuration into a live provider (#008AD).
//
//  A small file with one job, and it is a seam rather than a convenience:
//  `PasswordVaultService` takes this as a closure, so its tests can hand it a
//  stub and never touch the network or the keychain. Nothing else in the app
//  knows the concrete provider types — this is the only place the two
//  backends are named.
//
//  Validation lives here too, for the same reason "Test and Save" tests before
//  it saves: a server URL that will not parse should be a sentence on the
//  set-up sheet, not a request that fails later with a URLSession error code.

import Foundation

enum VaultProviderFactory {

    /// The default wiring.
    @Sendable
    static func make(
        _ configuration: VaultConfiguration, credentials: VaultCredentials
    ) throws -> any PasswordVaultProvider {
        let url = try serverURL(from: configuration.serverURL)

        switch configuration.kind {
        case .onePasswordConnect:
            guard let token = credentials.connectToken, !token.isEmpty else {
                throw VaultError.notConfigured
            }
            return OnePasswordVaultProvider(
                baseURL: url,
                token: token,
                allowsSelfSignedTLS: configuration.allowsSelfSignedTLS)

        case .bitwarden:
            guard let password = credentials.masterPassword, !password.isEmpty else {
                throw VaultError.notConfigured
            }
            guard let email = configuration.accountEmail, !email.isEmpty else {
                throw VaultError.unsupported(
                    "A Bitwarden or Vaultwarden account needs an email address — it is the salt "
                        + "the master key is derived from, not just a login name.")
            }
            var providerConfiguration = BitwardenVaultProvider.Configuration(
                serverURL: url, email: email)
            providerConfiguration.allowsSelfSignedTLS = configuration.allowsSelfSignedTLS
            // Stable across launches; see `VaultConfiguration.deviceIdentifier`
            // for why a fresh one per construction is actively harmful.
            providerConfiguration.deviceIdentifier = configuration.deviceIdentifier
            // The password is captured rather than passed: the provider asks
            // for it when it needs to derive a key, which is once per unlock
            // and not once per request.
            return try BitwardenVaultProvider(
                configuration: providerConfiguration,
                masterPassword: { password })
        }
    }

    /// Parse the server URL the way someone would actually type it.
    ///
    /// `vault.lan` with no scheme is the common case and `URL` treats it as a
    /// path, so https is assumed — and *only* https: a master password or a
    /// bearer token over cleartext is not a thing to make easy, even on a
    /// home network.
    static func serverURL(from string: String) throws -> URL {
        var trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw VaultError.unsupported("The vault server address is empty.")
        }
        if !trimmed.contains("://") { trimmed = "https://" + trimmed }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
            url.host != nil
        else {
            throw VaultError.unsupported("\"\(string)\" is not a server address Zen can use.")
        }
        guard scheme == "https" else {
            throw VaultError.unsupported(
                "Zen will only talk to a vault over https. \"\(string)\" is \(scheme).")
        }
        return url
    }
}
