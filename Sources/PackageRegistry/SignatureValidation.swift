//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2023 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import _Concurrency
import Dispatch
import struct Foundation.Data

import Basics
import PackageModel
import PackageSigning

import TSCBasic
import struct TSCUtility.Version

protocol SignatureValidationDelegate {
    func onUnsigned(registry: Registry, package: PackageIdentity, version: Version, completion: (Bool) -> Void)
    func onUntrusted(registry: Registry, package: PackageIdentity, version: Version, completion: (Bool) -> Void)
}

struct SignatureValidation {
    typealias Delegate = SignatureValidationDelegate

    private let signingEntityTOFU: PackageSigningEntityTOFU
    private let versionMetadataProvider: (PackageIdentity.RegistryIdentity, Version) throws -> RegistryClient
        .PackageVersionMetadata
    private let delegate: Delegate

    init(
        signingEntityStorage: PackageSigningEntityStorage?,
        signingEntityCheckingMode: SigningEntityCheckingMode,
        versionMetadataProvider: @escaping (PackageIdentity.RegistryIdentity, Version) throws -> RegistryClient
            .PackageVersionMetadata,
        delegate: Delegate
    ) {
        self.signingEntityTOFU = PackageSigningEntityTOFU(
            signingEntityStorage: signingEntityStorage,
            signingEntityCheckingMode: signingEntityCheckingMode
        )
        self.versionMetadataProvider = versionMetadataProvider
        self.delegate = delegate
    }

    func validate(
        registry: Registry,
        package: PackageIdentity.RegistryIdentity,
        version: Version,
        content: Data,
        configuration: RegistryConfiguration.Security.Signing,
        timeout: DispatchTimeInterval?,
        fileSystem: FileSystem,
        observabilityScope: ObservabilityScope,
        callbackQueue: DispatchQueue,
        completion: @escaping (Result<SigningEntity?, Error>) -> Void
    ) {
        self.getAndValidateSignature(
            registry: registry,
            package: package,
            version: version,
            content: content,
            configuration: configuration,
            timeout: timeout,
            fileSystem: fileSystem,
            observabilityScope: observabilityScope,
            callbackQueue: callbackQueue
        ) { result in
            switch result {
            case .success(let signingEntity):
                // Always do signing entity TOFU check at the end,
                // whether the package is signed or not.
                self.signingEntityTOFU.validate(
                    registry: registry,
                    package: package,
                    version: version,
                    signingEntity: signingEntity,
                    observabilityScope: observabilityScope,
                    callbackQueue: callbackQueue
                ) { _ in
                    completion(.success(signingEntity))
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    private func getAndValidateSignature(
        registry: Registry,
        package: PackageIdentity.RegistryIdentity,
        version: Version,
        content: Data,
        configuration: RegistryConfiguration.Security.Signing,
        timeout: DispatchTimeInterval?,
        fileSystem: FileSystem,
        observabilityScope: ObservabilityScope,
        callbackQueue: DispatchQueue,
        completion: @escaping (Result<SigningEntity?, Error>) -> Void
    ) {
        do {
            let versionMetadata = try self.versionMetadataProvider(package, version)

            guard let sourceArchiveResource = versionMetadata.sourceArchive else {
                throw RegistryError.missingSourceArchive
            }
            guard let signatureBase64Encoded = sourceArchiveResource.signing?.signatureBase64Encoded else {
                throw RegistryError.sourceArchiveNotSigned(
                    registry: registry,
                    package: package.underlying,
                    version: version
                )
            }
            guard let signatureData = Data(base64Encoded: signatureBase64Encoded) else {
                throw RegistryError.failedLoadingSignature
            }
            guard let signatureFormatString = sourceArchiveResource.signing?.signatureFormat else {
                throw RegistryError.missingSignatureFormat
            }
            guard let signatureFormat = SignatureFormat(rawValue: signatureFormatString) else {
                throw RegistryError.unknownSignatureFormat(signatureFormatString)
            }

            self.validateSignature(
                registry: registry,
                package: package,
                version: version,
                signature: signatureData,
                signatureFormat: signatureFormat,
                content: content,
                configuration: configuration,
                fileSystem: fileSystem,
                observabilityScope: observabilityScope,
                completion: completion
            )
        } catch RegistryError.sourceArchiveNotSigned(let registry, let package, let version) {
            observabilityScope.emit(info: "\(package) \(version) from \(registry) is unsigned")
            guard let onUnsigned = configuration.onUnsigned else {
                return completion(.failure(RegistryError.missingConfiguration(details: "security.signing.onUnsigned")))
            }

            let sourceArchiveNotSignedError = RegistryError.sourceArchiveNotSigned(
                registry: registry,
                package: package,
                version: version
            )

            switch onUnsigned {
            case .prompt:
                self.delegate.onUnsigned(registry: registry, package: package, version: version) { `continue` in
                    if `continue` {
                        completion(.success(.none))
                    } else {
                        completion(.failure(sourceArchiveNotSignedError))
                    }
                }
            case .error:
                completion(.failure(sourceArchiveNotSignedError))
            case .warn:
                observabilityScope.emit(warning: "\(sourceArchiveNotSignedError)")
                completion(.success(.none))
            case .silentAllow:
                // Continue without logging
                completion(.success(.none))
            }
        } catch RegistryError.failedRetrievingReleaseInfo(_, _, _, let error) {
            completion(.failure(RegistryError.failedRetrievingSourceArchiveSignature(
                registry: registry,
                package: package.underlying,
                version: version,
                error: error
            )))
        } catch {
            completion(.failure(RegistryError.failedRetrievingSourceArchiveSignature(
                registry: registry,
                package: package.underlying,
                version: version,
                error: error
            )))
        }
    }

    private func validateSignature(
        registry: Registry,
        package: PackageIdentity.RegistryIdentity,
        version: Version,
        signature: Data,
        signatureFormat: SignatureFormat,
        content: Data,
        configuration: RegistryConfiguration.Security.Signing,
        fileSystem: FileSystem,
        observabilityScope: ObservabilityScope,
        completion: @escaping (Result<SigningEntity?, Error>) -> Void
    ) {
        Task {
            do {
                let signatureStatus = try await SignatureProvider.status(
                    signature: Array(signature),
                    content: Array(content),
                    format: signatureFormat,
                    verifierConfiguration: try VerifierConfiguration.from(configuration, fileSystem: fileSystem),
                    observabilityScope: observabilityScope
                )

                switch signatureStatus {
                case .valid(let signingEntity):
                    observabilityScope
                        .emit(
                            info: "\(package) \(version) from \(registry) is signed with a valid entity '\(signingEntity)'"
                        )
                    completion(.success(signingEntity))
                case .invalid(let reason):
                    completion(.failure(RegistryError.invalidSignature(reason: reason)))
                case .certificateInvalid(let reason):
                    completion(.failure(RegistryError.invalidSigningCertificate(reason: reason)))
                case .certificateNotTrusted(let signingEntity):
                    observabilityScope
                        .emit(
                            info: "\(package) \(version) from \(registry) signing entity '\(signingEntity)' is untrusted"
                        )

                    guard let onUntrusted = configuration.onUntrustedCertificate else {
                        return completion(.failure(
                            RegistryError.missingConfiguration(details: "security.signing.onUntrustedCertificate")
                        ))
                    }

                    let signerNotTrustedError = RegistryError.signerNotTrusted(signingEntity)

                    switch onUntrusted {
                    case .prompt:
                        self.delegate
                            .onUntrusted(
                                registry: registry,
                                package: package.underlying,
                                version: version
                            ) { `continue` in
                                if `continue` {
                                    completion(.success(.none))
                                } else {
                                    completion(.failure(signerNotTrustedError))
                                }
                            }
                    case .error:
                        completion(.failure(signerNotTrustedError))
                    case .warn:
                        observabilityScope.emit(warning: "\(signerNotTrustedError)")
                        completion(.success(.none))
                    case .silentAllow:
                        // Continue without logging
                        completion(.success(.none))
                    }
                }
            } catch {
                completion(.failure(RegistryError.failedToValidateSignature(error)))
            }
        }
    }
}

extension VerifierConfiguration {
    fileprivate static func from(
        _ configuration: RegistryConfiguration.Security.Signing,
        fileSystem: FileSystem
    ) throws -> VerifierConfiguration {
        var verifierConfiguration = VerifierConfiguration()

        // Load trusted roots from configured directory
        if let trustedRootsDirectoryPath = configuration.trustedRootCertificatesPath {
            let trustedRootsDirectory: AbsolutePath
            do {
                trustedRootsDirectory = try AbsolutePath(validating: trustedRootsDirectoryPath)
            } catch {
                throw RegistryError.badConfiguration(details: "\(trustedRootsDirectoryPath) is invalid: \(error)")
            }

            guard fileSystem.isDirectory(trustedRootsDirectory) else {
                throw RegistryError.badConfiguration(details: "\(trustedRootsDirectoryPath) is not a directory")
            }

            do {
                let trustedRoots = try fileSystem.getDirectoryContents(trustedRootsDirectory).map {
                    let trustRootPath = trustedRootsDirectory.appending(component: $0)
                    return try fileSystem.readFileContents(trustRootPath).contents
                }
                verifierConfiguration.trustedRoots = trustedRoots
            } catch {
                throw RegistryError.badConfiguration(details: "failed to load trust roots: \(error)")
            }
        }

        // Should default trust store be included?
        if let includeDefaultTrustedRoots = configuration.includeDefaultTrustedRootCertificates {
            verifierConfiguration.includeDefaultTrustStore = includeDefaultTrustedRoots
        }

        if let validationChecks = configuration.validationChecks {
            // Check certificate expiry
            if let certificateExpiration = validationChecks.certificateExpiration {
                switch certificateExpiration {
                case .enabled:
                    verifierConfiguration.certificateExpiration = .enabled(validationTime: nil)
                case .disabled:
                    verifierConfiguration.certificateExpiration = .disabled
                }
            }
            // Check certificate revocation status
            if let certificateRevocation = validationChecks.certificateRevocation {
                switch certificateRevocation {
                case .strict:
                    verifierConfiguration.certificateRevocation = .strict
                case .allowSoftFail:
                    verifierConfiguration.certificateRevocation = .allowSoftFail
                case .disabled:
                    verifierConfiguration.certificateRevocation = .disabled
                }
            }
        }

        return verifierConfiguration
    }
}