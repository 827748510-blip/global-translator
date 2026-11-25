import AppKit
import Foundation
import Testing
@testable import GlobalTranslatorApp
import GlobalTranslatorCore

struct ScreenshotImageIOTests {
    @Test
    func saveWritesPngToDirectoryAndReturnsURL() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gt-shot-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = try #require(makeSolidTestImage(width: 16, height: 8))
        let url = try ScreenshotImageIO.save(image, to: directory, filename: "shot.png")
        #expect(url.lastPathComponent == "shot.png")
        #expect(url.deletingLastPathComponent() == directory.standardizedFileURL)
        let data = try Data(contentsOf: url)
        // PNG magic bytes
        #expect(Array(data.prefix(8)) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    }

    @Test
    func saveCreatesMissingDirectory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gt-shot-nested-\(UUID().uuidString)/inner", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let image = try #require(makeSolidTestImage(width: 8, height: 8))
        let url = try ScreenshotImageIO.save(image, to: directory)
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(url.pathExtension == "png")
    }

    @Test
    func defaultFilenamesAreUniqueAndPng() {
        let first = ScreenshotImageIO.defaultFilename()
        let second = ScreenshotImageIO.defaultFilename()
        #expect(first.hasSuffix(".png"))
        #expect(first != second)
    }

    @Test
    func saveEnforcesRestrictedPosixPermissionsAndRejectsTraversalOrSymlink() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gt-shot-perm-\(UUID().uuidString)", isDirectory: true)
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("gt-shot-outside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let image = try #require(makeSolidTestImage(width: 8, height: 8))
        let saveDir = root.appendingPathComponent("shots", isDirectory: true)
        let saved = try ScreenshotImageIO.save(image, to: saveDir, filename: "private.png")
        let dirAttrs = try FileManager.default.attributesOfItem(atPath: saveDir.path)
        let fileAttrs = try FileManager.default.attributesOfItem(atPath: saved.path)
        #expect((dirAttrs[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect((fileAttrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)

        #expect(throws: ScreenshotImageIO.SaveError.unsafePath) {
            _ = try ScreenshotImageIO.save(image, to: saveDir, filename: "../escape.png")
        }

        let symlinkDir = root.appendingPathComponent("symlink-dir", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: symlinkDir, withDestinationURL: outside)
        #expect(throws: ScreenshotImageIO.SaveError.unsafePath) {
            _ = try ScreenshotImageIO.save(image, to: symlinkDir, filename: "escaped.png")
        }
    }
}

struct ScreenshotConfigurationTests {
    @Test
    func newFieldsDefaultToOffAndDefaultDirectory() {
        let configuration = AppConfiguration()
        #expect(configuration.saveScreenshotImage == false)
        #expect(configuration.copyScreenshotImage == false)
        #expect(configuration.screenshotSaveDirectory == AppConfiguration.defaultScreenshotSaveDirectory)
        #expect(configuration.screenshotSaveDirectory.contains("Pictures"))
    }

    @Test
    func legacyConfigWithoutNewKeysDecodesWithDefaults() throws {
        let json = """
        {"backend":"local","localBaseURL":"http://127.0.0.1:11434/v1","localModel":"m"}
        """
        let configuration = try JSONDecoder().decode(AppConfiguration.self, from: Data(json.utf8))
        #expect(configuration.saveScreenshotImage == false)
        #expect(configuration.copyScreenshotImage == false)
        #expect(configuration.screenshotSaveDirectory == AppConfiguration.defaultScreenshotSaveDirectory)
    }

    @Test
    func screenshotFieldsRoundTrip() throws {
        var configuration = AppConfiguration()
        configuration.saveScreenshotImage = true
        configuration.copyScreenshotImage = true
        configuration.screenshotSaveDirectory = "/tmp/gt-shots"
        let decoded = try JSONDecoder().decode(AppConfiguration.self, from: JSONEncoder().encode(configuration))
        #expect(decoded.saveScreenshotImage == true)
        #expect(decoded.copyScreenshotImage == true)
        #expect(decoded.screenshotSaveDirectory == "/tmp/gt-shots")
    }

    @Test
    func displayPathAbbreviatesHome() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(SelectionTranslateSupport.displayPath(home + "/Pictures/x") == "~/Pictures/x")
        #expect(SelectionTranslateSupport.displayPath("/tmp/x") == "/tmp/x")
    }
}
