//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the container project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//   https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

import ContainerAPIClient
import ContainerizationArchive
import ContainerizationError
import Foundation
import Logging

enum ClusterDefaults {
    static let clusterName = "kubernetes"
    static let image = "docker.io/kindest/node:v1.34.0@sha256:7416a61b42b1662ca6ca89f02028ac133a309a2a30ba309614e8ec94d976dc5a"
    static let memory = "16G"
    static let cpus: Int64 = 6
    static let podCIDR = "10.244.0.0/16"
    static let apiPort: UInt16 = 6443
}

enum ClusterKernel {
    private static let kernelArchiveURL = URL(
        string:
            "https://github.com/willswire/kernel/releases/download/containerization-c3fe889a2f739ee4a9b0faccedd9f36f3862dc29/kernel-c3fe889a2f739ee4a9b0faccedd9f36f3862dc29.tar.zst"
    )!
    private static let kernelArchivePath = "vmlinux"

    static func resolveKernelPath(explicitPath: String?, log: Logger, debug: Bool) async throws -> String? {
        if let explicitPath {
            return expandTilde(explicitPath).path
        }
        return try await ensureKernelCached(log: log, debug: debug)
    }

    private static func ensureKernelCached(log: Logger, debug: Bool) async throws -> String {
        let cacheDir = try kernelCacheDirectory()
        let archiveDir = cacheDir.appendingPathComponent(kernelArchiveURL.lastPathComponent, isDirectory: true)
        let cachedKernel = archiveDir.appendingPathComponent(kernelArchivePath)

        if let existing = try? FileManager.default.attributesOfItem(atPath: cachedKernel.path),
            let size = existing[.size] as? NSNumber,
            size.intValue > 0
        {
            if debug {
                log.debug("Cluster kernel cached: \(cachedKernel.path)")
            }
            return cachedKernel.path
        }

        try FileManager.default.createDirectory(at: archiveDir, withIntermediateDirectories: true, attributes: nil)
        if !debug {
            print("Fetching cluster kernel...")
        }

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true, attributes: nil)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let tempArchive = tempDir.appendingPathComponent(kernelArchiveURL.lastPathComponent)
        try await downloadFileFollowingRedirects(from: kernelArchiveURL, to: tempArchive)
        let extracted = try extractKernel(from: tempArchive, kernelPath: kernelArchivePath, to: tempDir)

        try? FileManager.default.removeItem(at: cachedKernel)
        try FileManager.default.moveItem(at: extracted, to: cachedKernel)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: cachedKernel.path)
        if debug {
            log.debug("Cluster kernel cached: \(cachedKernel.path)")
        }
        return cachedKernel.path
    }

    private static func kernelCacheDirectory() throws -> URL {
        let base =
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches", isDirectory: true)
        let cacheDir = base.appendingPathComponent("cluster", isDirectory: true)
            .appendingPathComponent("kernels", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true, attributes: nil)
        return cacheDir
    }

    private static func downloadFileFollowingRedirects(from url: URL, to destination: URL) async throws {
        let (tempURL, response) = try await URLSession.shared.download(from: url)
        if let httpResponse = response as? HTTPURLResponse {
            guard (200...299).contains(httpResponse.statusCode) else {
                throw ContainerizationError(.internalError, message: "failed to download kernel archive: HTTP \(httpResponse.statusCode)")
            }
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: tempURL, to: destination)
    }

    private static func extractKernel(from tarFile: URL, kernelPath: String, to directory: URL) throws -> URL {
        let archiveReader = try ArchiveReader(file: tarFile)
        let (entry, data) = try archiveReader.extractFile(path: kernelPath)
        guard entry.fileType == .regular else {
            throw ContainerizationError(.internalError, message: "kernel \(kernelPath) is not a regular file in archive")
        }
        let outputURL = directory.appendingPathComponent(URL(fileURLWithPath: kernelPath).lastPathComponent)
        try data.write(to: outputURL, options: .atomic)
        return outputURL
    }
}

struct ClusterSpec: Sendable {
    let name: String
    let image: String
    let cpus: Int64
    let memory: String
    let podCIDR: String
    let apiPort: UInt16
    let kernelPath: String?
    let kubeconfigPath: URL

    var nodeName: String { "\(name)-control-plane" }

    init(
        name: String,
        image: String,
        cpus: Int64,
        memory: String,
        podCIDR: String,
        apiPort: UInt16,
        kernelPath: String?,
        kubeconfigPath: String?
    ) throws {
        self.name = name
        self.image = image
        self.cpus = cpus
        self.memory = memory
        self.podCIDR = podCIDR
        self.apiPort = apiPort
        self.kernelPath = kernelPath
        self.kubeconfigPath = KubeconfigManager.resolvePath(
            path: kubeconfigPath,
            clusterName: name
        )
    }
}

enum KubeconfigManager {
    static func resolvePath(path: String?, clusterName: String) -> URL {
        if let path {
            return expandTilde(path)
        }
        let kubeDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".kube")
            .appendingPathComponent("cluster", isDirectory: true)
        return kubeDir.appendingPathComponent("\(clusterName).config")
    }

    static func patch(raw: String, clusterName: String, apiPort: UInt16) -> String {
        var output = raw
        output = output.replacingOccurrences(
            of: #"server: https://.*:6443"#,
            with: "server: https://127.0.0.1:\(apiPort)",
            options: .regularExpression
        )
        output = output.replacingOccurrences(of: "name: kubernetes-admin@kubernetes", with: "name: \(clusterName)")
        output = output.replacingOccurrences(of: "name: kubernetes-admin", with: "name: admin")
        output = output.replacingOccurrences(of: "name: kubernetes", with: "name: \(clusterName)")
        output = output.replacingOccurrences(of: "cluster: kubernetes", with: "cluster: \(clusterName)")
        output = output.replacingOccurrences(of: "user: kubernetes-admin", with: "user: admin")
        output = output.replacingOccurrences(
            of: #"current-context:.*"#,
            with: "current-context: \(clusterName)",
            options: .regularExpression
        )
        return output
    }

    static func write(config: String, to path: URL) throws {
        let dir = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
        let data = Data(config.utf8)
        try data.write(to: path, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: path.path
        )
    }

    static func read(at path: URL) throws -> String {
        let data = try Data(contentsOf: path)
        guard let content = String(data: data, encoding: .utf8) else {
            throw ContainerizationError(.invalidArgument, message: "kubeconfig at \(path.path) is not valid utf8")
        }
        return content
    }
}

struct ExecResult: Sendable {
    let stdout: String
    let stderr: String
    let exitCode: Int32
}

enum ClusterExecutor {
    static func run(
        container: ClientContainer,
        command: [String],
        log: Logger,
        captureOutput: Bool,
        allowFailure: Bool = false
    ) async throws -> ExecResult {
        guard let executable = command.first else {
            throw ContainerizationError(.invalidArgument, message: "command is empty")
        }

        var config = container.configuration.initProcess
        config.executable = executable
        config.arguments = Array(command.dropFirst())
        config.terminal = false

        if captureOutput {
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            let process = try await container.createProcess(
                id: UUID().uuidString.lowercased(),
                configuration: config,
                stdio: [
                    nil,
                    stdoutPipe.fileHandleForWriting,
                    stderrPipe.fileHandleForWriting,
                ]
            )
            try await process.start()
            let exitCode = try await process.wait()
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()
            let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
            let stderr = String(data: stderrData, encoding: .utf8) ?? ""
            if exitCode != 0 && !allowFailure {
                throw ContainerizationError(
                    .internalError,
                    message: "command failed with exit code \(exitCode): \(command.joined(separator: " "))\n\(stderr)"
                )
            }
            return ExecResult(stdout: stdout, stderr: stderr, exitCode: exitCode)
        }

        let io = try ProcessIO.create(tty: false, interactive: false, detach: false)
        defer { try? io.close() }
        let process = try await container.createProcess(
            id: UUID().uuidString.lowercased(),
            configuration: config,
            stdio: io.stdio
        )
        let exitCode = try await io.handleProcess(process: process, log: log)
        if exitCode != 0 && !allowFailure {
            throw ContainerizationError(
                .internalError,
                message: "command failed with exit code \(exitCode): \(command.joined(separator: " "))"
            )
        }
        return ExecResult(stdout: "", stderr: "", exitCode: exitCode)
    }
}

enum ClusterContainer {
    static func ensureRunning(_ container: ClientContainer) throws {
        if container.status != .running {
            throw ContainerizationError(.invalidState, message: "container \(container.id) is not running")
        }
    }

    static func bootstrapAndStart(container: ClientContainer) async throws {
        let io = try ProcessIO.create(tty: false, interactive: false, detach: true)
        defer { try? io.close() }
        let process = try await container.bootstrap(stdio: io.stdio)
        try await process.start()
        try io.closeAfterStart()
    }
}

private func expandTilde(_ path: String) -> URL {
    if path.hasPrefix("~") {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let expanded = path.replacingOccurrences(of: "~", with: home)
        return URL(fileURLWithPath: expanded)
    }
    return URL(fileURLWithPath: path)
}
