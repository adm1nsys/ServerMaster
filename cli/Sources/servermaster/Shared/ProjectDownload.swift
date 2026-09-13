//
//  ProjectDownload.swift
//  ServerMaster
//
//  Fetching a CMS into the folder the person just chose, so “I need to run
//  Joomla” does not begin with hunting for a download page, unpacking an
//  archive and finding out afterwards that the wrong edition was taken.
//
//  The archive is checked against the SHA-256 the release lists before anything
//  is unpacked. Be clear about what that buys: it proves the file arrived whole
//  and unaltered in transit, not that the publisher was not compromised. It is
//  the same guarantee anyone downloading by hand gets, made automatic.
//
//  Nothing is ever unpacked over an existing project — a folder with files in it
//  is refused rather than merged.
//

import Foundation
import CryptoKit
import Observation

/// Something the app can fetch and unpack for you.
nonisolated struct DownloadableProject: Sendable {

    var id: String
    var title: String
    /// GitHub repository holding the releases, "owner/repo".
    var repository: String
    /// Only releases whose tag starts with this are considered.
    var majorVersion: String
    /// The asset to take, matched on its name.
    var assetContains: [String]
    /// Where the project's own instructions live.
    var guide: AppLinks.Guide

    static let joomla5 = DownloadableProject(
        id: "joomla5", title: "Joomla 5",
        repository: "joomla/joomla-cms", majorVersion: "5.",
        assetContains: ["Stable-Full_Package", ".zip"], guide: .joomla)

    static let joomla6 = DownloadableProject(
        id: "joomla6", title: "Joomla 6",
        repository: "joomla/joomla-cms", majorVersion: "6.",
        assetContains: ["Stable-Full_Package", ".zip"], guide: .joomla)

    /// What a template can offer to download, if anything.
    static func forTemplate(_ id: String) -> DownloadableProject? {
        switch id {
        case "joomla5": return joomla5
        case "joomla6": return joomla6
        default:        return nil
        }
    }
}

@Observable
final class ProjectDownloader {

    enum Stage: Equatable {
        case idle
        case findingRelease
        case downloading(Double)     // 0…1, or -1 when the size is unknown
        case verifying
        case unpacking
        case done(String)            // the version that landed
        case failed(String)
    }

    private(set) var stage: Stage = .idle

    var isBusy: Bool {
        switch stage {
        case .idle, .done, .failed: return false
        default:                    return true
        }
    }

    // MARK: - The whole job

    /// Downloads the newest release of `project` and unpacks it into `folder`.
    func fetch(_ project: DownloadableProject, into folder: String) async {
        stage = .findingRelease
        do {
            let destination = URL(fileURLWithPath: AppPaths.expand(folder))
            try checkFolderIsUsable(destination)

            let release = try await findRelease(project)
            let archive = try await download(release)
            defer { try? FileManager.default.removeItem(at: archive) }

            stage = .verifying
            try verify(archive, against: release.sha256)

            stage = .unpacking
            try await unpack(archive, into: destination)

            stage = .done(release.version)
        } catch {
            stage = .failed(error.localizedDescription)
        }
    }

    // MARK: - Steps

    nonisolated struct Release: Sendable {
        var version: String
        var url: URL
        var size: Int
        /// Hex digest, without the "sha256:" prefix.
        var sha256: String?
    }

    enum DownloadError: LocalizedError {
        case folderNotEmpty
        case notADirectory
        case noRelease(String)
        case badArchive
        case checksumMismatch
        case unpackFailed(String)

        var errorDescription: String? {
            switch self {
            case .folderNotEmpty:
                return String(localized: "That folder already has files in it. Choose an empty one — nothing is merged into an existing project.")
            case .notADirectory:
                return String(localized: "That is not a folder.")
            case .noRelease(let name):
                return String(localized: "No release of \(name) could be found.")
            case .badArchive:
                return String(localized: "The downloaded file is not a readable archive.")
            case .checksumMismatch:
                return String(localized: "The download does not match its published checksum and was discarded. Try again.")
            case .unpackFailed(let message):
                return String(localized: "Unpacking failed: \(message)")
            }
        }
    }

    private func checkFolderIsUsable(_ url: URL) throws {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw DownloadError.notADirectory }
            let contents = (try? fm.contentsOfDirectory(atPath: url.path)) ?? []
            // .DS_Store alone does not count as “in use”.
            let real = contents.filter { $0 != ".DS_Store" }
            guard real.isEmpty else { throw DownloadError.folderNotEmpty }
        } else {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    private func findRelease(_ project: DownloadableProject) async throws -> Release {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(project.repository)/releases?per_page=40")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("ServerMaster/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30

        let (data, _) = try await URLSession.shared.data(for: request)
        guard let releases = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw DownloadError.noRelease(project.title)
        }

        for release in releases {
            guard let tag = release["tag_name"] as? String,
                  tag.hasPrefix(project.majorVersion),
                  (release["prerelease"] as? Bool) != true,
                  (release["draft"] as? Bool) != true,
                  let assets = release["assets"] as? [[String: Any]]
            else { continue }

            for asset in assets {
                guard let name = asset["name"] as? String,
                      project.assetContains.allSatisfy({ name.contains($0) }),
                      let link = asset["browser_download_url"] as? String,
                      let url = URL(string: link)
                else { continue }

                // GitHub reports the digest as "sha256:<hex>".
                let digest = (asset["digest"] as? String)?
                    .replacingOccurrences(of: "sha256:", with: "")
                return Release(version: tag, url: url,
                               size: asset["size"] as? Int ?? 0,
                               sha256: digest)
            }
        }
        throw DownloadError.noRelease(project.title)
    }

    private func download(_ release: Release) async throws -> URL {
        stage = .downloading(release.size > 0 ? 0 : -1)

        let (bytes, response) = try await URLSession.shared.bytes(from: release.url)
        let expected = response.expectedContentLength > 0
            ? Int(response.expectedContentLength) : release.size

        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("sm-download-\(UUID().uuidString).zip")
        FileManager.default.createFile(atPath: target.path, contents: nil)
        let handle = try FileHandle(forWritingTo: target)
        defer { try? handle.close() }

        var buffer = Data()
        buffer.reserveCapacity(1 << 16)
        var written = 0
        var lastReported = 0.0

        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= (1 << 16) {
                try handle.write(contentsOf: buffer)
                written += buffer.count
                buffer.removeAll(keepingCapacity: true)

                // Reporting every chunk would redraw the sheet hundreds of times.
                if expected > 0 {
                    let fraction = Double(written) / Double(expected)
                    if fraction - lastReported > 0.01 {
                        lastReported = fraction
                        stage = .downloading(fraction)
                    }
                }
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            written += buffer.count
        }
        return target
    }

    /// Internal rather than private on purpose: this is the one step that has to
    /// be provably correct, and a test cannot reach a private method.
    func verify(_ archive: URL, against expected: String?) throws {
        guard let expected, !expected.isEmpty else {
            // No digest published: the download still has to be a real archive.
            guard let handle = try? FileHandle(forReadingFrom: archive),
                  let head = try handle.read(upToCount: 4), head.starts(with: [0x50, 0x4B])
            else { throw DownloadError.badArchive }
            try? handle.close()
            return
        }

        let handle = try FileHandle(forReadingFrom: archive)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual.caseInsensitiveCompare(expected) == .orderedSame else {
            throw DownloadError.checksumMismatch
        }
    }

    private func unpack(_ archive: URL, into folder: URL) async throws {
        // ditto rather than unzip: it keeps macOS metadata straight and refuses
        // paths that would escape the destination.
        let result = await ProcessRunner.run("/usr/bin/ditto",
                                             ["-x", "-k", archive.path, folder.path],
                                             timeout: 600)
        guard result.succeeded else {
            throw DownloadError.unpackFailed(result.combined.isEmpty
                                             ? String(localized: "unknown reason")
                                             : String(result.combined.suffix(200)))
        }
    }
}
