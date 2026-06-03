import AppKit
import AVFoundation
import Foundation

let appDisplayName = "KoalaSwiming Shokz Playlist"
let audioExtensions: Set<String> = ["mp3", "m4a", "wav", "flac", "aac", "wma"]
let imageExtensions = ["jpg", "jpeg", "png", "heic", "tiff", "webp"]
let ignoredDeviceFolders: Set<String> = [
    ".spotlight-v100",
    ".trashes",
    ".fseventsd",
    "system volume information"
]

struct Playlist {
    let name: String
    let url: URL
    let files: [URL]

    var count: Int {
        files.count
    }

    var normalizedNames: Set<String> {
        Set(files.map { normalizedAudioName($0.lastPathComponent) })
    }
}

struct PlaylistMatch {
    let name: String
    let score: Double
    let exact: Bool
}

struct AppModel {
    let projectURL: URL
    let playlistsURL: URL
    let playlistImagesURL: URL
    let playlistAnalysisURL: URL
    let deviceURL: URL
    var playlists: [Playlist]
    var deviceFiles: [URL]
    var currentMatch: PlaylistMatch?
}

struct BPMCacheEntry: Codable {
    let fileSize: Int64
    let modifiedTime: Double
    let bpm: Int
    let source: String
    let analyzedAt: Double
}

struct BPMCache: Codable {
    var version = 1
    var tracks: [String: BPMCacheEntry] = [:]
}

struct PlaylistTempoInfo {
    let tempos: [Int]
    let missingCount: Int

    var totalCount: Int {
        tempos.count + missingCount
    }

    var average: Int? {
        guard !tempos.isEmpty else {
            return nil
        }
        return Int((Double(tempos.reduce(0, +)) / Double(tempos.count)).rounded())
    }

    var minTempo: Int? {
        tempos.min()
    }

    var maxTempo: Int? {
        tempos.max()
    }

    var bins: [TempoBin] {
        tempoBinDefinitions.map { definition in
            TempoBin(
                label: definition.label,
                range: definition.range,
                count: tempos.filter { definition.range.contains($0) }.count
            )
        }
    }
}

let tempoRangeMin = 80
let tempoRangeMax = 190

struct TempoRange: Equatable {
    var min: Int
    var max: Int

    static let full = TempoRange(min: tempoRangeMin, max: tempoRangeMax)

    var label: String {
        "\(min)-\(max) BPM"
    }

    func contains(_ bpm: Int) -> Bool {
        bpm >= min && bpm <= max
    }

    func clamped() -> TempoRange {
        let low = Swift.max(tempoRangeMin, Swift.min(min, tempoRangeMax))
        let high = Swift.max(low, Swift.min(max, tempoRangeMax))
        return TempoRange(min: low, max: high)
    }
}

struct TempoBin {
    let label: String
    let range: ClosedRange<Int>
    let count: Int
}

let tempoBinDefinitions: [(label: String, range: ClosedRange<Int>)] = [
    ("<90", 0...89),
    ("90-99", 90...99),
    ("100-109", 100...109),
    ("110-119", 110...119),
    ("120-129", 120...129),
    ("130-139", 130...139),
    ("140-149", 140...149),
    ("150-159", 150...159),
    ("160-169", 160...169),
    ("170-179", 170...179),
    ("180+", 180...250)
]

func env(_ name: String) -> String? {
    guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else {
        return nil
    }
    return value
}

func argValue(_ name: String) -> String? {
    let args = CommandLine.arguments
    guard let index = args.firstIndex(of: name), args.indices.contains(index + 1) else {
        return nil
    }
    return args[index + 1]
}

func hasArg(_ name: String) -> Bool {
    CommandLine.arguments.contains(name)
}

func defaultProjectURL() -> URL {
    if let project = argValue("--project") {
        return URL(fileURLWithPath: project)
    }

    if let project = env("SWIM_PROJECT_DIR") {
        return URL(fileURLWithPath: project)
    }

    let scriptPath = CommandLine.arguments.first ?? FileManager.default.currentDirectoryPath
    return URL(fileURLWithPath: scriptPath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

func isAudioURL(_ url: URL, includeAppleDouble: Bool = false) -> Bool {
    let name = url.lastPathComponent
    if !includeAppleDouble && (name.hasPrefix(".") || name.hasPrefix("._")) {
        return false
    }

    return audioExtensions.contains(url.pathExtension.lowercased())
}

func normalizedAudioName(_ name: String) -> String {
    var cleaned = name
    if cleaned.hasPrefix("._") {
        cleaned.removeFirst(2)
    }
    return cleaned.precomposedStringWithCanonicalMapping.lowercased()
}

func listAudioFiles(in root: URL, includeAppleDouble: Bool = false) -> [URL] {
    let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey]
    let options: FileManager.DirectoryEnumerationOptions = includeAppleDouble
        ? [.skipsPackageDescendants]
        : [.skipsHiddenFiles, .skipsPackageDescendants]
    guard let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: keys,
        options: options
    ) else {
        return []
    }

    var urls: [URL] = []
    for case let url as URL in enumerator {
        let lowerName = url.lastPathComponent.lowercased()
        if ignoredDeviceFolders.contains(lowerName) {
            enumerator.skipDescendants()
            continue
        }

        guard isAudioURL(url, includeAppleDouble: includeAppleDouble) else {
            continue
        }

        let values = try? url.resourceValues(forKeys: Set(keys))
        if values?.isRegularFile == true {
            urls.append(url)
        }
    }

    return urls.sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
}

func loadPlaylists(from playlistsURL: URL) -> [Playlist] {
    let fileManager = FileManager.default
    let urls = (try? fileManager.contentsOfDirectory(
        at: playlistsURL,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
    )) ?? []

    return urls.compactMap { url in
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
        guard values?.isDirectory == true else {
            return nil
        }
        return Playlist(name: url.lastPathComponent, url: url, files: listAudioFiles(in: url))
    }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
}

func playlistImageURL(for playlistName: String, imagesURL: URL) -> URL? {
    for ext in imageExtensions {
        let url = imagesURL.appendingPathComponent("\(playlistName).\(ext)")
        if FileManager.default.fileExists(atPath: url.path) {
            return url
        }
    }
    return nil
}

func synchsafeInt(_ bytes: [UInt8]) -> Int {
    bytes.reduce(0) { ($0 << 7) | Int($1 & 0x7F) }
}

func bigEndianInt(_ bytes: [UInt8]) -> Int {
    bytes.reduce(0) { ($0 << 8) | Int($1) }
}

func id3Text(from data: Data) -> String? {
    guard let encoding = data.first else {
        return nil
    }

    let payload = data.dropFirst()
    let string: String?
    switch encoding {
    case 0:
        string = String(data: payload, encoding: .isoLatin1)
    case 1, 2:
        string = String(data: payload, encoding: .utf16)
    case 3:
        string = String(data: payload, encoding: .utf8)
    default:
        string = String(data: payload, encoding: .utf8)
            ?? String(data: payload, encoding: .isoLatin1)
    }

    return string?
        .replacingOccurrences(of: "\u{0}", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

func tempoFromText(_ text: String?) -> Int? {
    guard let text = text else {
        return nil
    }

    let pattern = #"([0-9]{2,3})(?:\.[0-9]+)?"#
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          let range = Range(match.range(at: 1), in: text),
          let bpm = Int(text[range]),
          bpm >= 40,
          bpm <= 240 else {
        return nil
    }

    return bpm
}

func tempoFromID3(fileURL: URL) -> Int? {
    guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
        return nil
    }
    defer {
        try? handle.close()
    }

    guard let header = try? handle.read(upToCount: 10), header.count == 10 else {
        return nil
    }

    let headerBytes = [UInt8](header)
    guard headerBytes[0] == 0x49, headerBytes[1] == 0x44, headerBytes[2] == 0x33 else {
        return nil
    }

    let majorVersion = headerBytes[3]
    let tagSize = synchsafeInt(Array(headerBytes[6...9]))
    guard tagSize > 0, tagSize < 2_000_000,
          let tagData = try? handle.read(upToCount: tagSize) else {
        return nil
    }

    let bytes = [UInt8](tagData)
    var offset = 0

    while offset + 10 <= bytes.count {
        let frameIDData = Data(bytes[offset..<(offset + 4)])
        guard let frameID = String(data: frameIDData, encoding: .ascii),
              frameID.range(of: #"^[A-Z0-9]{4}$"#, options: .regularExpression) != nil else {
            break
        }

        let sizeBytes = Array(bytes[(offset + 4)..<(offset + 8)])
        let frameSize = majorVersion == 4 ? synchsafeInt(sizeBytes) : bigEndianInt(sizeBytes)
        let frameStart = offset + 10
        let frameEnd = frameStart + frameSize
        guard frameSize > 0, frameEnd <= bytes.count else {
            break
        }

        let frameData = Data(bytes[frameStart..<frameEnd])
        if frameID == "TBPM", let bpm = tempoFromText(id3Text(from: frameData)) {
            return bpm
        }

        if frameID == "TXXX" {
            let text = id3Text(from: frameData)
            if text?.localizedCaseInsensitiveContains("bpm") == true,
               let bpm = tempoFromText(text) {
                return bpm
            }
        }

        offset = frameEnd
    }

    return nil
}

func firstImageData(in data: Data) -> Data? {
    let bytes = [UInt8](data)
    let signatures: [[UInt8]] = [
        [0xFF, 0xD8, 0xFF],
        [0x89, 0x50, 0x4E, 0x47],
        [0x47, 0x49, 0x46, 0x38]
    ]

    for index in bytes.indices {
        for signature in signatures where index + signature.count <= bytes.count {
            if Array(bytes[index..<(index + signature.count)]) == signature {
                return data.subdata(in: index..<data.count)
            }
        }
    }

    return nil
}

func albumArtworkFromID3(fileURL: URL) -> NSImage? {
    guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
        return nil
    }
    defer {
        try? handle.close()
    }

    guard let header = try? handle.read(upToCount: 10), header.count == 10 else {
        return nil
    }

    let headerBytes = [UInt8](header)
    guard headerBytes[0] == 0x49, headerBytes[1] == 0x44, headerBytes[2] == 0x33 else {
        return nil
    }

    let majorVersion = headerBytes[3]
    let tagSize = synchsafeInt(Array(headerBytes[6...9]))
    guard tagSize > 0, tagSize < 5_000_000,
          let tagData = try? handle.read(upToCount: tagSize) else {
        return nil
    }

    let bytes = [UInt8](tagData)
    var offset = 0
    while offset + 10 <= bytes.count {
        let frameIDData = Data(bytes[offset..<(offset + 4)])
        guard let frameID = String(data: frameIDData, encoding: .ascii),
              frameID.range(of: #"^[A-Z0-9]{4}$"#, options: .regularExpression) != nil else {
            break
        }

        let sizeBytes = Array(bytes[(offset + 4)..<(offset + 8)])
        let frameSize = majorVersion == 4 ? synchsafeInt(sizeBytes) : bigEndianInt(sizeBytes)
        let frameStart = offset + 10
        let frameEnd = frameStart + frameSize
        guard frameSize > 0, frameEnd <= bytes.count else {
            break
        }

        if frameID == "APIC" || frameID == "PIC" {
            let frameData = tagData.subdata(in: frameStart..<frameEnd)
            if let imageData = firstImageData(in: frameData),
               let image = NSImage(data: imageData) {
                return image
            }
        }

        offset = frameEnd
    }

    return nil
}

func bpmCacheKey(for fileURL: URL) -> String {
    fileURL.standardizedFileURL.path
}

func fileSignature(_ fileURL: URL) -> (size: Int64, modified: Double) {
    let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
    return (
        Int64(values?.fileSize ?? 0),
        values?.contentModificationDate?.timeIntervalSince1970 ?? 0
    )
}

func loadBPMCache(from url: URL) -> BPMCache {
    guard let data = try? Data(contentsOf: url),
          let cache = try? JSONDecoder().decode(BPMCache.self, from: data) else {
        return BPMCache()
    }
    return cache
}

func saveBPMCache(_ cache: BPMCache, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(cache)
    try data.write(to: url, options: .atomic)
}

func cachedBPM(for fileURL: URL, cache: BPMCache) -> Int? {
    let signature = fileSignature(fileURL)
    guard let entry = cache.tracks[bpmCacheKey(for: fileURL)],
          entry.fileSize == signature.size,
          abs(entry.modifiedTime - signature.modified) < 1,
          entry.bpm >= 40,
          entry.bpm <= 240 else {
        return nil
    }
    return entry.bpm
}

func knownBPM(for fileURL: URL, cache: BPMCache) -> Int? {
    if let bpm = cachedBPM(for: fileURL, cache: cache) {
        return bpm
    }
    return tempoFromID3(fileURL: fileURL)
}

func cacheBPM(_ bpm: Int, source: String, for fileURL: URL, cache: inout BPMCache) {
    let signature = fileSignature(fileURL)
    cache.tracks[bpmCacheKey(for: fileURL)] = BPMCacheEntry(
        fileSize: signature.size,
        modifiedTime: signature.modified,
        bpm: bpm,
        source: source,
        analyzedAt: Date().timeIntervalSince1970
    )
}

func estimateBPM(fileURL: URL) -> Int? {
    guard let file = try? AVAudioFile(forReading: fileURL),
          let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096),
          let channels = buffer.floatChannelData else {
        return nil
    }

    let sampleRate = file.processingFormat.sampleRate
    let channelCount = Int(file.processingFormat.channelCount)
    let frameSize = max(512, Int(sampleRate * 1024.0 / 11_025.0))
    let maxSamples = Int(sampleRate * 180)
    var energies: [Double] = []
    var currentEnergy = 0.0
    var currentCount = 0
    var samplesRead = 0

    while file.framePosition < file.length, samplesRead < maxSamples {
        do {
            try file.read(into: buffer)
        } catch {
            break
        }

        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else {
            break
        }

        for frame in 0..<frameLength {
            var mono = 0.0
            for channel in 0..<channelCount {
                mono += Double(channels[channel][frame])
            }
            let value = mono / Double(max(channelCount, 1))
            currentEnergy += value * value
            currentCount += 1
            samplesRead += 1

            if currentCount >= frameSize {
                energies.append(sqrt(currentEnergy / Double(currentCount)))
                currentEnergy = 0
                currentCount = 0
            }

            if samplesRead >= maxSamples {
                break
            }
        }
    }

    guard energies.count > 32 else {
        return nil
    }

    var onset: [Double] = []
    var previous = energies.first ?? 0
    for energy in energies.dropFirst() {
        onset.append(max(0, energy - previous))
        previous = energy
    }

    let mean = onset.reduce(0, +) / Double(max(onset.count, 1))
    onset = onset.map { max(0, $0 - mean * 0.45) }
    guard onset.reduce(0, +) > 0 else {
        return nil
    }

    let onsetRate = sampleRate / Double(frameSize)
    var bestBPM = 120
    var bestScore = 0.0

    for bpm in 60...200 {
        let lag = max(1, Int((onsetRate * 60.0 / Double(bpm)).rounded()))
        guard lag < onset.count else {
            continue
        }

        var score = 0.0
        for index in lag..<onset.count {
            score += onset[index] * onset[index - lag]
        }

        // Mildly favor practical swimming/music tempos over unstable extremes.
        if bpm >= 90 && bpm <= 170 {
            score *= 1.08
        }

        if score > bestScore {
            bestScore = score
            bestBPM = bpm
        }
    }

    guard bestScore > 0 else {
        return nil
    }

    var normalizedBPM = bestBPM
    while normalizedBPM < 90 {
        normalizedBPM *= 2
    }
    while normalizedBPM > 180 {
        normalizedBPM /= 2
    }
    return normalizedBPM
}

func tempoInfo(for playlist: Playlist, cache: BPMCache? = nil) -> PlaylistTempoInfo {
    var tempos: [Int] = []
    for file in playlist.files {
        if let cache = cache, let bpm = knownBPM(for: file, cache: cache) {
            tempos.append(bpm)
        } else if cache == nil, let bpm = tempoFromID3(fileURL: file) {
            tempos.append(bpm)
        }
    }

    return PlaylistTempoInfo(tempos: tempos.sorted(), missingCount: playlist.files.count - tempos.count)
}

func volumeCandidates(named exactName: String?) -> [URL] {
    let volumesURL = URL(fileURLWithPath: "/Volumes", isDirectory: true)
    let fileManager = FileManager.default
    let urls = (try? fileManager.contentsOfDirectory(
        at: volumesURL,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
    )) ?? []

    if let exactName = exactName {
        let exactURL = volumesURL.appendingPathComponent(exactName, isDirectory: true)
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: exactURL.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return [exactURL]
        }
        return []
    }

    let swimLike = urls.filter { url in
        let name = url.lastPathComponent.lowercased()
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
        guard values?.isDirectory == true else {
            return false
        }
        return name.contains("swim") || name.contains("shokz") || name.contains("openswim")
    }

    if !swimLike.isEmpty {
        return swimLike
    }

    return urls.filter {
        let values = try? $0.resourceValues(forKeys: [.isDirectoryKey])
        return values?.isDirectory == true
    }
}

func findCurrentPlaylist(deviceFiles: [URL], playlists: [Playlist]) -> PlaylistMatch? {
    let deviceNames = Set(deviceFiles.map { normalizedAudioName($0.lastPathComponent) })
    guard !deviceNames.isEmpty else {
        return nil
    }

    var best: PlaylistMatch?
    for playlist in playlists where !playlist.normalizedNames.isEmpty {
        let overlap = deviceNames.intersection(playlist.normalizedNames).count
        let denominator = max(deviceNames.count, playlist.normalizedNames.count)
        let score = denominator == 0 ? 0 : Double(overlap) / Double(denominator)
        let exact = score == 1.0 && deviceNames.count == playlist.normalizedNames.count

        let candidate = PlaylistMatch(name: playlist.name, score: score, exact: exact)
        if exact {
            return candidate
        }
        if best == nil || candidate.score > best!.score {
            best = candidate
        }
    }

    if let best = best, best.score >= 0.8 {
        return best
    }

    return nil
}

func loadModel() throws -> AppModel {
    let projectURL = defaultProjectURL()
    let playlistsURL = argValue("--playlists").map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? env("SWIM_PLAYLISTS_DIR").map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? projectURL.appendingPathComponent("playlists", isDirectory: true)
    let playlistImagesURL = argValue("--images").map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? env("SWIM_PLAYLIST_IMAGES_DIR").map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? projectURL.appendingPathComponent("playlist_images", isDirectory: true)
    let playlistAnalysisURL = argValue("--analysis").map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? env("SWIM_PLAYLIST_ANALYSIS_DIR").map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? projectURL.appendingPathComponent("playlist_analysis", isDirectory: true)

    try FileManager.default.createDirectory(at: playlistsURL, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: playlistImagesURL, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: playlistAnalysisURL, withIntermediateDirectories: true)

    let exactVolumeName = argValue("--device-name") ?? env("SWIM_DEVICE_NAME")
    let candidates = volumeCandidates(named: exactVolumeName)
    guard let deviceURL = candidates.first else {
        throw NSError(
            domain: "SwimPlaylistGUI",
            code: 10,
            userInfo: [NSLocalizedDescriptionKey: "No writable Shokz/OpenSwim drive was found."]
        )
    }

    let playlists = loadPlaylists(from: playlistsURL)
    let deviceFiles = listAudioFiles(in: deviceURL)
    let current = findCurrentPlaylist(deviceFiles: deviceFiles, playlists: playlists)
    return AppModel(projectURL: projectURL, playlistsURL: playlistsURL, playlistImagesURL: playlistImagesURL, playlistAnalysisURL: playlistAnalysisURL, deviceURL: deviceURL, playlists: playlists, deviceFiles: deviceFiles, currentMatch: current)
}

func writeData(_ data: Data, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
}

func writeClickTrackBPMTest(to url: URL, bpm: Int) throws {
    let sampleRate = 44_100.0
    let duration = 20.0
    let totalFrames = AVAudioFrameCount(sampleRate * duration)
    let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: totalFrames)!
    buffer.frameLength = totalFrames

    guard let channel = buffer.floatChannelData?[0] else {
        return
    }

    for index in 0..<Int(totalFrames) {
        channel[index] = 0
    }

    let interval = Int(sampleRate * 60.0 / Double(bpm))
    for beat in stride(from: 0, to: Int(totalFrames), by: interval) {
        for offset in 0..<360 where beat + offset < Int(totalFrames) {
            let decay = Float(1.0 - (Double(offset) / 360.0))
            channel[beat + offset] = max(channel[beat + offset], decay)
        }
    }

    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    try file.write(from: buffer)
}

func runSelfTest() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("swim-playlist-selftest-\(UUID().uuidString)", isDirectory: true)
    defer {
        try? FileManager.default.removeItem(at: root)
    }

    let playlistURL = root.appendingPathComponent("playlists/hard", isDirectory: true)
    let deviceURL = root.appendingPathComponent("device", isDirectory: true)
    try FileManager.default.createDirectory(at: playlistURL, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: deviceURL, withIntermediateDirectories: true)

    try writeData(Data(repeating: 1, count: 16_384), to: playlistURL.appendingPathComponent("same.mp3"))
    try writeData(Data(repeating: 2, count: 32_768), to: playlistURL.appendingPathComponent("new.mp3"))
    try writeData(Data(repeating: 3, count: 24_576), to: playlistURL.appendingPathComponent("changed.mp3"))

    try writeData(Data(repeating: 1, count: 16_384), to: deviceURL.appendingPathComponent("same.mp3"))
    try writeData(Data(repeating: 4, count: 12_288), to: deviceURL.appendingPathComponent("changed.mp3"))
    try writeData(Data(repeating: 5, count: 8_192), to: deviceURL.appendingPathComponent("old.mp3"))

    let playlist = Playlist(name: "hard", url: playlistURL, files: listAudioFiles(in: playlistURL))
    let plan = syncPlan(for: playlist, deviceURL: deviceURL)
    guard plan.keepCount == 1, plan.copyCount == 1, plan.replaceCount == 1, plan.removeCount == 1 else {
        throw NSError(domain: "SwimPlaylistGUI", code: 20, userInfo: [NSLocalizedDescriptionKey: "Unexpected sync plan: \(plan.shortSummary)"])
    }

    var progressEvents = 0
    try syncPlaylistDelta(playlist, to: deviceURL, plan: plan) { progress in
        progressEvents += 1
        guard progress.fraction >= 0, progress.fraction <= 1 else {
            fatalError("Invalid progress fraction")
        }
    }

    let finalFiles = Set(listAudioFiles(in: deviceURL).map { $0.lastPathComponent })
    guard finalFiles == ["same.mp3", "new.mp3", "changed.mp3"], progressEvents > 0 else {
        throw NSError(domain: "SwimPlaylistGUI", code: 21, userInfo: [NSLocalizedDescriptionKey: "Self-test sync result was wrong."])
    }

    let pausePlaylistURL = root.appendingPathComponent("playlists/pause", isDirectory: true)
    let pauseDeviceURL = root.appendingPathComponent("pause-device", isDirectory: true)
    try FileManager.default.createDirectory(at: pausePlaylistURL, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: pauseDeviceURL, withIntermediateDirectories: true)
    try writeData(Data(repeating: 7, count: 2_000_000), to: pausePlaylistURL.appendingPathComponent("big.mp3"))

    let pausePlaylist = Playlist(name: "pause", url: pausePlaylistURL, files: listAudioFiles(in: pausePlaylistURL))
    let pausePlan = syncPlan(for: pausePlaylist, deviceURL: pauseDeviceURL)
    let control = TransferControl()
    var didPause = false

    do {
        try syncPlaylistDelta(pausePlaylist, to: pauseDeviceURL, plan: pausePlan, control: control) { _ in
            control.requestPause()
        }
    } catch SyncStopped.paused {
        didPause = true
    }

    let pauseFiles = (try? FileManager.default.contentsOfDirectory(atPath: pauseDeviceURL.path)) ?? []
    guard didPause, !pauseFiles.contains("big.mp3"), pauseFiles.allSatisfy({ !$0.hasPrefix(".swim-sync-") }) else {
        throw NSError(domain: "SwimPlaylistGUI", code: 22, userInfo: [NSLocalizedDescriptionKey: "Pause self-test left an unsafe partial file."])
    }

    let clickURL = root.appendingPathComponent("click-120.wav")
    try writeClickTrackBPMTest(to: clickURL, bpm: 120)
    let detectedBPM = estimateBPM(fileURL: clickURL)
    guard let detectedBPM = detectedBPM, abs(detectedBPM - 120) <= 3 else {
        throw NSError(domain: "SwimPlaylistGUI", code: 23, userInfo: [NSLocalizedDescriptionKey: "BPM estimator self-test failed: \(detectedBPM.map(String.init) ?? "nil")."])
    }
}

func relativePath(of fileURL: URL, under rootURL: URL) -> String {
    let rootPath = rootURL.standardizedFileURL.path
    let filePath = fileURL.standardizedFileURL.path
    guard filePath.hasPrefix(rootPath + "/") else {
        return fileURL.lastPathComponent
    }
    return String(filePath.dropFirst(rootPath.count + 1))
}

func fileSize(_ url: URL) -> Int64 {
    let values = try? url.resourceValues(forKeys: [.fileSizeKey])
    return Int64(values?.fileSize ?? 0)
}

func formatBytes(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useMB, .useGB]
    formatter.countStyle = .file
    return formatter.string(fromByteCount: bytes)
}

func formatDuration(_ seconds: TimeInterval) -> String {
    guard seconds.isFinite, seconds >= 0 else {
        return "--:--"
    }

    let wholeSeconds = Int(seconds.rounded())
    if wholeSeconds < 3600 {
        return String(format: "%02d:%02d", wholeSeconds / 60, wholeSeconds % 60)
    }

    return String(format: "%d:%02d:%02d", wholeSeconds / 3600, (wholeSeconds % 3600) / 60, wholeSeconds % 60)
}

struct SyncCopy {
    let source: URL
    let destination: URL
    let replacing: Bool
    let bytes: Int64
}

struct SyncPlan {
    let keepCount: Int
    let removeFiles: [URL]
    let cleanHiddenFiles: [URL]
    let copies: [SyncCopy]

    var copyCount: Int {
        copies.filter { !$0.replacing }.count
    }

    var replaceCount: Int {
        copies.filter { $0.replacing }.count
    }

    var removeCount: Int {
        removeFiles.count
    }

    var totalBytes: Int64 {
        copies.reduce(0) { $0 + $1.bytes }
    }

    var hasChanges: Bool {
        removeCount > 0 || !cleanHiddenFiles.isEmpty || !copies.isEmpty
    }

    var totalUnitCount: Double {
        Double(removeFiles.count + cleanHiddenFiles.count) + Double(max(totalBytes, 1))
    }

    var shortSummary: String {
        if !hasChanges {
            return "Already synced. No transfer needed."
        }

        var parts: [String] = []
        if keepCount > 0 {
            parts.append("keep \(keepCount)")
        }
        if copyCount > 0 {
            parts.append("copy \(copyCount)")
        }
        if replaceCount > 0 {
            parts.append("refresh \(replaceCount)")
        }
        if removeCount > 0 {
            parts.append("remove \(removeCount)")
        }
        if !cleanHiddenFiles.isEmpty {
            parts.append("clean \(cleanHiddenFiles.count)")
        }

        return parts.joined(separator: " / ")
    }
}

struct SyncProgress {
    let fraction: Double
    let copiedBytes: Int64
    let totalBytes: Int64
    let completedItems: Int
    let totalItems: Int
    let phase: String
    let detail: String
}

enum SyncStopped: Error {
    case paused
}

final class TransferControl {
    private let lock = NSLock()
    private var pauseRequested = false

    func requestPause() {
        lock.lock()
        pauseRequested = true
        lock.unlock()
    }

    var shouldPause: Bool {
        lock.lock()
        defer { lock.unlock() }
        return pauseRequested
    }
}

func audioGroupsByName(_ files: [URL]) -> [String: [URL]] {
    Dictionary(grouping: files) { normalizedAudioName($0.lastPathComponent) }
}

func firstPlaylistFileByName(_ files: [URL]) -> [String: URL] {
    var result: [String: URL] = [:]
    for file in files {
        let name = normalizedAudioName(file.lastPathComponent)
        if result[name] == nil {
            result[name] = file
        }
    }
    return result
}

func syncPlan(for playlist: Playlist, deviceURL: URL, deviceFiles: [URL]? = nil) -> SyncPlan {
    let currentFiles = deviceFiles ?? listAudioFiles(in: deviceURL)
    let hiddenAudio = listAudioFiles(in: deviceURL, includeAppleDouble: true)
        .filter { $0.lastPathComponent.hasPrefix("._") }
    let deviceGroups = audioGroupsByName(currentFiles)
    let desiredByName = firstPlaylistFileByName(playlist.files)

    var keepCount = 0
    var removeFiles: [URL] = []
    var copies: [SyncCopy] = []

    for (name, files) in deviceGroups {
        guard let source = desiredByName[name] else {
            removeFiles.append(contentsOf: files)
            continue
        }

        guard let keeper = files.first else {
            continue
        }

        if fileSize(keeper) == fileSize(source) {
            keepCount += 1
        } else {
            copies.append(SyncCopy(source: source, destination: keeper, replacing: true, bytes: fileSize(source)))
        }

        if files.count > 1 {
            removeFiles.append(contentsOf: files.dropFirst())
        }
    }

    for (name, source) in desiredByName where deviceGroups[name] == nil {
        let destination = deviceURL.appendingPathComponent(source.lastPathComponent)
        copies.append(SyncCopy(source: source, destination: destination, replacing: false, bytes: fileSize(source)))
    }

    return SyncPlan(
        keepCount: keepCount,
        removeFiles: removeFiles.sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending },
        cleanHiddenFiles: hiddenAudio.sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending },
        copies: copies.sorted { $0.source.lastPathComponent.localizedCaseInsensitiveCompare($1.source.lastPathComponent) == .orderedAscending }
    )
}

func copyFileWithProgress(_ copy: SyncCopy, alreadyCopiedBytes: Int64, control: TransferControl?, progress: (Int64, String) -> Void) throws -> Int64 {
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: copy.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    let temporaryDestination = copy.destination.deletingLastPathComponent()
        .appendingPathComponent(".swim-sync-\(UUID().uuidString).tmp")

    fileManager.createFile(atPath: temporaryDestination.path, contents: nil)
    let input = try FileHandle(forReadingFrom: copy.source)
    let output = try FileHandle(forWritingTo: temporaryDestination)
    defer {
        try? input.close()
        try? output.close()
        if fileManager.fileExists(atPath: temporaryDestination.path) {
            try? fileManager.removeItem(at: temporaryDestination)
        }
    }

    var totalCopiedBytes = alreadyCopiedBytes
    while true {
        let data = try input.read(upToCount: 512 * 1024) ?? Data()
        if data.isEmpty {
            break
        }
        try output.write(contentsOf: data)
        totalCopiedBytes += Int64(data.count)
        progress(totalCopiedBytes, copy.source.lastPathComponent)

        if control?.shouldPause == true {
            throw SyncStopped.paused
        }
    }

    try output.synchronize()
    if fileManager.fileExists(atPath: copy.destination.path) {
        try fileManager.removeItem(at: copy.destination)
    }
    try fileManager.moveItem(at: temporaryDestination, to: copy.destination)
    return totalCopiedBytes
}

func syncPlaylistDelta(_ playlist: Playlist, to deviceURL: URL, plan: SyncPlan, control: TransferControl? = nil, progress: @escaping (SyncProgress) -> Void) throws {
    let fileManager = FileManager.default
    let totalItems = plan.removeFiles.count + plan.cleanHiddenFiles.count + plan.copies.count
    let totalUnits = plan.totalUnitCount
    var copiedBytes: Int64 = 0
    var completedItems = 0
    var completedNonCopyUnits = 0

    func emit(_ phase: String, _ detail: String, copiedBytesValue: Int64? = nil) {
        let visibleCopiedBytes = copiedBytesValue ?? copiedBytes
        let fraction = min(1, (Double(completedNonCopyUnits) + Double(visibleCopiedBytes)) / totalUnits)
        progress(SyncProgress(
            fraction: fraction,
            copiedBytes: visibleCopiedBytes,
            totalBytes: plan.totalBytes,
            completedItems: completedItems,
            totalItems: totalItems,
            phase: phase,
            detail: detail
        ))
    }

    emit("Preparing delta transfer", plan.shortSummary)

    for file in plan.cleanHiddenFiles {
        if control?.shouldPause == true {
            throw SyncStopped.paused
        }
        try? fileManager.removeItem(at: file)
        completedItems += 1
        completedNonCopyUnits += 1
        emit("Cleaning device metadata", file.lastPathComponent)
    }

    for file in plan.removeFiles {
        if control?.shouldPause == true {
            throw SyncStopped.paused
        }
        try fileManager.removeItem(at: file)
        completedItems += 1
        completedNonCopyUnits += 1
        emit("Removing old track", file.lastPathComponent)
    }

    for copy in plan.copies {
        if control?.shouldPause == true {
            throw SyncStopped.paused
        }
        emit(copy.replacing ? "Refreshing changed track" : "Copying new track", copy.source.lastPathComponent)
        copiedBytes = try copyFileWithProgress(copy, alreadyCopiedBytes: copiedBytes, control: control) { bytes, detail in
            emit(copy.replacing ? "Refreshing changed track" : "Copying new track", detail, copiedBytesValue: bytes)
        }
        completedItems += 1
        emit("Finished track", copy.source.lastPathComponent)
    }

    sync()
    progress(SyncProgress(
        fraction: 1,
        copiedBytes: copiedBytes,
        totalBytes: plan.totalBytes,
        completedItems: totalItems,
        totalItems: totalItems,
        phase: "Transfer complete",
        detail: "\(playlist.name) is ready on \(deviceURL.lastPathComponent)."
    ))
}

func log(_ model: AppModel, _ message: String) {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let line = "[\(formatter.string(from: Date()))] \(message)\n"
    let logURL = model.projectURL.appendingPathComponent("swim-sync.log")
    if let data = line.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: logURL.path),
           let handle = try? FileHandle(forWritingTo: logURL) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? data.write(to: logURL)
        }
    }
}

func alertAndExit(_ message: String) -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    app.activate(ignoringOtherApps: true)

    let alert = NSAlert()
    alert.alertStyle = .informational
    alert.messageText = appDisplayName
    alert.informativeText = message
    alert.addButton(withTitle: "OK")
    alert.runModal()
    exit(1)
}

func percentText(_ score: Double) -> String {
    "\(Int((score * 100).rounded()))%"
}

final class SwimBackgroundView: NSView {
    private var wavePhase: CGFloat = 0
    private var animationTimer: Timer?

    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        animationTimer?.invalidate()

        guard window != nil else {
            return
        }

        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.wavePhase += 0.055
            self.needsDisplay = true
        }
    }

    deinit {
        animationTimer?.invalidate()
    }

    override func draw(_ dirtyRect: NSRect) {
        let gradient = NSGradient(colors: [
            NSColor(calibratedRed: 0.015, green: 0.034, blue: 0.052, alpha: 1),
            NSColor(calibratedRed: 0.020, green: 0.125, blue: 0.160, alpha: 1),
            NSColor(calibratedRed: 0.065, green: 0.092, blue: 0.105, alpha: 1)
        ])
        gradient?.draw(in: bounds, angle: -24)

        let glow = NSBezierPath(ovalIn: NSRect(x: -120, y: -170, width: 430, height: 330))
        NSColor(calibratedRed: 0.00, green: 0.70, blue: 0.92, alpha: 0.22).setFill()
        glow.fill()

        let warmCut = NSBezierPath(roundedRect: NSRect(x: bounds.width - 270, y: bounds.height - 230, width: 210, height: 170), xRadius: 34, yRadius: 34)
        NSColor(calibratedRed: 1.00, green: 0.55, blue: 0.17, alpha: 0.055).setFill()
        warmCut.fill()

        for index in 0..<5 {
            let y = 112 + CGFloat(index) * 76
            let path = NSBezierPath()
            path.lineWidth = index == 0 ? 1.6 : 1.1

            var started = false
            var x: CGFloat = -20
            while x <= bounds.width + 20 {
                let bob = sin((x * 0.020) + wavePhase + CGFloat(index) * 0.78) * (6 + CGFloat(index % 2) * 2)
                let point = NSPoint(x: x, y: y + bob)
                if started {
                    path.line(to: point)
                } else {
                    path.move(to: point)
                    started = true
                }
                x += 10
            }

            NSColor(calibratedRed: 0.30, green: 0.92, blue: 1.0, alpha: 0.11 + CGFloat(index) * 0.018).setStroke()
            path.stroke()
        }

        for index in 0..<18 {
            let x = CGFloat(index) * 52 + 20
            let phase = CGFloat(index) * 0.65 + wavePhase
            let y = 450 + sin(phase) * 12
            let dot = NSBezierPath(ovalIn: NSRect(x: x.truncatingRemainder(dividingBy: bounds.width), y: y, width: 3, height: 3))
            NSColor(calibratedWhite: 1, alpha: 0.10).setFill()
            dot.fill()
        }
    }
}

final class RoundedPanel: NSView {
    var fillColor = NSColor(calibratedWhite: 1, alpha: 0.08)
    var strokeColor = NSColor(calibratedWhite: 1, alpha: 0.13)
    var radius: CGFloat = 14

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        fillColor.setFill()
        path.fill()
        strokeColor.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

final class PlaylistCoverView: NSView {
    var image: NSImage? {
        didSet {
            needsDisplay = true
        }
    }
    var playlistName = "" {
        didSet {
            needsDisplay = true
        }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 16, yRadius: 16)
        path.addClip()

        if let image = image {
            let imageSize = image.size
            let scale = max(bounds.width / max(imageSize.width, 1), bounds.height / max(imageSize.height, 1))
            let drawSize = NSSize(width: imageSize.width * scale, height: imageSize.height * scale)
            let drawRect = NSRect(
                x: (bounds.width - drawSize.width) / 2,
                y: (bounds.height - drawSize.height) / 2,
                width: drawSize.width,
                height: drawSize.height
            )
            image.draw(in: drawRect)

            NSColor(calibratedWhite: 0, alpha: 0.18).setFill()
            bounds.fill(using: .sourceAtop)
        } else {
            NSGradient(colors: [
                NSColor(calibratedRed: 0.02, green: 0.45, blue: 0.62, alpha: 1),
                NSColor(calibratedRed: 0.95, green: 0.49, blue: 0.18, alpha: 1)
            ])?.draw(in: bounds, angle: -30)

            let letters = playlistName
                .split(separator: "_")
                .prefix(2)
                .compactMap { $0.first }
                .map { String($0).uppercased() }
                .joined()
            let label = letters.isEmpty ? "SW" : letters
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 42, weight: .black),
                .foregroundColor: NSColor.white.withAlphaComponent(0.92)
            ]
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attributes)
        }

        NSColor(calibratedWhite: 1, alpha: 0.18).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

struct TrackPreviewItem {
    let title: String
    let image: NSImage?
}

final class TrackPreviewStripView: NSView {
    var items: [TrackPreviewItem] = [] {
        didSet {
            needsDisplay = true
        }
    }
    var emptyMessage = "Drop MP3 files into this playlist." {
        didSet {
            needsDisplay = true
        }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 10, dy: 8)
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .bold),
            .foregroundColor: NSColor(calibratedWhite: 1, alpha: 0.42)
        ]
        "TRACK PREVIEW".draw(at: NSPoint(x: rect.minX, y: rect.minY), withAttributes: titleAttrs)

        guard !items.isEmpty else {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor(calibratedWhite: 1, alpha: 0.68)
            ]
            emptyMessage.draw(at: NSPoint(x: rect.minX, y: rect.minY + 42), withAttributes: attrs)
            return
        }

        let tileCount = min(items.count, 6)
        let tileWidth = rect.width / CGFloat(tileCount)
        let artSize = min(CGFloat(72), tileWidth - 12)

        for index in 0..<tileCount {
            let item = items[index]
            let x = rect.minX + CGFloat(index) * tileWidth
            let artRect = NSRect(x: x + (tileWidth - artSize) / 2, y: rect.minY + 26, width: artSize, height: artSize)
            let artPath = NSBezierPath(roundedRect: artRect, xRadius: 8, yRadius: 8)
            NSGraphicsContext.saveGraphicsState()
            artPath.addClip()

            if let image = item.image {
                let imageSize = image.size
                let scale = max(artRect.width / max(imageSize.width, 1), artRect.height / max(imageSize.height, 1))
                let drawSize = NSSize(width: imageSize.width * scale, height: imageSize.height * scale)
                let drawRect = NSRect(
                    x: artRect.midX - drawSize.width / 2,
                    y: artRect.midY - drawSize.height / 2,
                    width: drawSize.width,
                    height: drawSize.height
                )
                image.draw(in: drawRect)
            } else {
                NSGradient(colors: [
                    NSColor(calibratedRed: 0.04, green: 0.36, blue: 0.48, alpha: 1),
                    NSColor(calibratedRed: 0.96, green: 0.55, blue: 0.23, alpha: 1)
                ])?.draw(in: artRect, angle: -35)

                let glyph = "♪"
                let glyphAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 26, weight: .bold),
                    .foregroundColor: NSColor.white.withAlphaComponent(0.86)
                ]
                let glyphSize = glyph.size(withAttributes: glyphAttrs)
                glyph.draw(at: NSPoint(x: artRect.midX - glyphSize.width / 2, y: artRect.midY - glyphSize.height / 2), withAttributes: glyphAttrs)
            }
            NSGraphicsContext.restoreGraphicsState()

            let overlayRect = NSRect(x: artRect.minX, y: artRect.maxY - 20, width: artRect.width, height: 20)
            let overlayPath = NSBezierPath(roundedRect: overlayRect, xRadius: 0, yRadius: 0)
            NSGraphicsContext.saveGraphicsState()
            artPath.addClip()
            NSColor(calibratedWhite: 0, alpha: 0.44).setFill()
            overlayPath.fill()
            NSGraphicsContext.restoreGraphicsState()

            NSColor(calibratedWhite: 1, alpha: 0.18).setStroke()
            artPath.lineWidth = 1
            artPath.stroke()

            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.lineBreakMode = .byTruncatingTail
            let textAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 9, weight: .medium),
                .foregroundColor: NSColor(calibratedWhite: 1, alpha: 0.92),
                .paragraphStyle: paragraph
            ]
            let titleRect = NSRect(x: artRect.minX + 5, y: artRect.maxY - 17, width: artRect.width - 10, height: 13)
            item.title.draw(in: titleRect, withAttributes: textAttrs)
        }
    }
}

final class TempoDistributionView: NSView {
    var info = PlaylistTempoInfo(tempos: [], missingCount: 0) {
        didSet {
            needsDisplay = true
        }
    }
    var filterRange = TempoRange.full {
        didSet {
            filterRange = filterRange.clamped()
            needsDisplay = true
        }
    }
    var filterEnabled = false {
        didSet {
            needsDisplay = true
        }
    }
    var onRangeChange: ((TempoRange, Bool) -> Void)?

    private enum DragHandle {
        case low
        case high
    }

    private var activeHandle: DragHandle?

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 14, dy: 12)
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .bold),
            .foregroundColor: NSColor(calibratedWhite: 1, alpha: 0.42)
        ]
        "TEMPO RANGE".draw(at: NSPoint(x: rect.minX, y: rect.minY), withAttributes: titleAttrs)

        let rangeTitle = filterEnabled ? filterRange.label : "ALL BPM"
        let pillAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .bold),
            .foregroundColor: NSColor(calibratedRed: 0.82, green: 1.0, blue: 0.94, alpha: 1)
        ]
        let pillSize = rangeTitle.size(withAttributes: pillAttrs)
        let pillRect = NSRect(x: rect.maxX - pillSize.width - 18, y: rect.minY - 1, width: pillSize.width + 18, height: 20)
        let pillPath = NSBezierPath(roundedRect: pillRect, xRadius: 10, yRadius: 10)
        NSColor(calibratedWhite: 1, alpha: filterEnabled ? 0.13 : 0.08).setFill()
        pillPath.fill()
        rangeTitle.draw(at: NSPoint(x: pillRect.minX + 9, y: pillRect.minY + 3), withAttributes: pillAttrs)

        guard !info.tempos.isEmpty else {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor(calibratedWhite: 1, alpha: 0.70)
            ]
            "Click Analyze BPM to build the tempo map.".draw(at: NSPoint(x: rect.minX, y: rect.minY + 56), withAttributes: attrs)
            return
        }

        let bins = info.bins
        let maxCount = max(bins.map { $0.count }.max() ?? 1, 1)
        let chartRect = NSRect(x: rect.minX, y: rect.minY + 34, width: rect.width, height: max(82, rect.height - 70))
        let baselineY = chartRect.maxY
        let gridAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .medium),
            .foregroundColor: NSColor(calibratedWhite: 1, alpha: 0.34)
        ]

        for step in 0...3 {
            let y = chartRect.minY + CGFloat(step) * chartRect.height / 3
            let path = NSBezierPath()
            path.move(to: NSPoint(x: chartRect.minX, y: y))
            path.line(to: NSPoint(x: chartRect.maxX, y: y))
            NSColor(calibratedWhite: 1, alpha: step == 3 ? 0.17 : 0.08).setStroke()
            path.lineWidth = 1
            path.stroke()
        }

        let selectedMinX = bpmX(filterRange.min, in: chartRect)
        let selectedMaxX = bpmX(filterRange.max, in: chartRect)
        if filterEnabled {
            let selectionRect = NSRect(x: selectedMinX, y: chartRect.minY, width: max(2, selectedMaxX - selectedMinX), height: chartRect.height)
            let selectionPath = NSBezierPath(roundedRect: selectionRect, xRadius: 12, yRadius: 12)
            NSGradient(colors: [
                NSColor(calibratedRed: 0.01, green: 0.82, blue: 1.0, alpha: 0.16),
                NSColor(calibratedRed: 0.83, green: 1.0, blue: 0.38, alpha: 0.14)
            ])?.draw(in: selectionPath, angle: 0)
        }

        let gap: CGFloat = 4
        let barWidth = max(7, (chartRect.width - CGFloat(bins.count - 1) * gap) / CGFloat(bins.count))
        for (index, bin) in bins.enumerated() {
            let x = chartRect.minX + CGFloat(index) * (barWidth + gap)
            let rawHeight = chartRect.height * CGFloat(bin.count) / CGFloat(maxCount)
            let barHeight = max(bin.count == 0 ? 2 : 8, rawHeight)
            let barRect = NSRect(x: x, y: baselineY - barHeight, width: barWidth, height: barHeight)
            let barPath = NSBezierPath(roundedRect: barRect, xRadius: min(5, barWidth / 2), yRadius: min(5, barWidth / 2))
            let selected = filterEnabled && bin.range.overlaps(filterRange.min...filterRange.max)
            if selected {
                NSGradient(colors: [
                    NSColor(calibratedRed: 0.02, green: 0.86, blue: 1.0, alpha: 0.98),
                    NSColor(calibratedRed: 0.84, green: 1.0, blue: 0.44, alpha: 0.96)
                ])?.draw(in: barPath, angle: 90)
            } else {
                NSColor(calibratedWhite: 1, alpha: filterEnabled ? 0.16 : 0.34).setFill()
                barPath.fill()
            }

            if index % 2 == 1 || index == 0 || index == bins.count - 1 {
                let label = bin.label
                let labelSize = label.size(withAttributes: gridAttrs)
                label.draw(at: NSPoint(x: x + (barWidth - labelSize.width) / 2, y: chartRect.maxY + 8), withAttributes: gridAttrs)
            }
        }

        drawHandle(at: selectedMinX, label: "\(filterRange.min)", chartRect: chartRect, active: activeHandle == .low)
        drawHandle(at: selectedMaxX, label: "\(filterRange.max)", chartRect: chartRect, active: activeHandle == .high)
    }

    private func chartRect() -> NSRect {
        let rect = bounds.insetBy(dx: 14, dy: 12)
        return NSRect(x: rect.minX, y: rect.minY + 34, width: rect.width, height: max(82, rect.height - 70))
    }

    private func bpmX(_ bpm: Int, in chartRect: NSRect) -> CGFloat {
        let clamped = CGFloat(max(tempoRangeMin, min(bpm, tempoRangeMax)) - tempoRangeMin)
        let span = CGFloat(tempoRangeMax - tempoRangeMin)
        return chartRect.minX + chartRect.width * clamped / span
    }

    private func bpmFromX(_ x: CGFloat, in chartRect: NSRect) -> Int {
        let fraction = max(0, min(1, (x - chartRect.minX) / max(chartRect.width, 1)))
        let raw = Double(tempoRangeMin) + Double(fraction) * Double(tempoRangeMax - tempoRangeMin)
        return Int((raw / 5.0).rounded() * 5.0)
    }

    private func drawHandle(at x: CGFloat, label: String, chartRect: NSRect, active: Bool) {
        let line = NSBezierPath()
        line.move(to: NSPoint(x: x, y: chartRect.minY - 4))
        line.line(to: NSPoint(x: x, y: chartRect.maxY + 2))
        (active
            ? NSColor(calibratedRed: 0.91, green: 1.0, blue: 0.50, alpha: 0.94)
            : NSColor(calibratedRed: 0.78, green: 1.0, blue: 0.96, alpha: 0.74)).setStroke()
        line.lineWidth = active ? 2.2 : 1.5
        line.stroke()

        let knobRect = NSRect(x: x - 9, y: chartRect.minY - 12, width: 18, height: 18)
        let knob = NSBezierPath(ovalIn: knobRect)
        NSGradient(colors: [
            NSColor(calibratedRed: 0.08, green: 0.85, blue: 1.0, alpha: 1),
            NSColor(calibratedRed: 0.87, green: 1.0, blue: 0.45, alpha: 1)
        ])?.draw(in: knob, angle: active ? 20 : 0)
        NSColor(calibratedWhite: 0.0, alpha: 0.28).setStroke()
        knob.lineWidth = 1
        knob.stroke()

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .bold),
            .foregroundColor: NSColor(calibratedWhite: 1, alpha: 0.88)
        ]
        let size = label.size(withAttributes: attrs)
        label.draw(at: NSPoint(x: x - size.width / 2, y: chartRect.minY - 28), withAttributes: attrs)
    }

    override func mouseDown(with event: NSEvent) {
        guard !info.tempos.isEmpty else {
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        let chart = chartRect()
        let lowX = bpmX(filterRange.min, in: chart)
        let highX = bpmX(filterRange.max, in: chart)
        activeHandle = abs(point.x - lowX) <= abs(point.x - highX) ? .low : .high
        updateRange(with: point)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        updateRange(with: point)
    }

    override func mouseUp(with event: NSEvent) {
        activeHandle = nil
        needsDisplay = true
    }

    private func updateRange(with point: NSPoint) {
        guard let activeHandle = activeHandle else {
            return
        }

        let bpm = bpmFromX(point.x, in: chartRect())
        switch activeHandle {
        case .low:
            filterRange = TempoRange(min: min(bpm, filterRange.max), max: filterRange.max).clamped()
        case .high:
            filterRange = TempoRange(min: filterRange.min, max: max(bpm, filterRange.min)).clamped()
        }
        filterEnabled = true
        onRangeChange?(filterRange, true)
    }
}

final class ProgressMeterView: NSView {
    var fraction: Double = 0 {
        didSet {
            fraction = min(1, max(0, fraction))
            needsDisplay = true
        }
    }
    var active = false {
        didSet {
            updateTimer()
            needsDisplay = true
        }
    }

    private var shimmer: CGFloat = 0
    private var timer: Timer?

    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTimer()
    }

    deinit {
        timer?.invalidate()
    }

    private func updateTimer() {
        timer?.invalidate()
        timer = nil

        guard active, window != nil else {
            return
        }

        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.shimmer += 0.045
            self.needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let base = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        NSColor(calibratedWhite: 1, alpha: 0.10).setFill()
        base.fill()

        let width = max(rect.height, rect.width * CGFloat(fraction))
        let fillRect = NSRect(x: rect.minX, y: rect.minY, width: width, height: rect.height)
        let fill = NSBezierPath(roundedRect: fillRect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        NSGradient(colors: [
            NSColor(calibratedRed: 0.02, green: 0.80, blue: 1.00, alpha: 0.98),
            NSColor(calibratedRed: 0.64, green: 1.00, blue: 0.76, alpha: 0.98),
            NSColor(calibratedRed: 1.00, green: 0.68, blue: 0.25, alpha: 0.96)
        ])?.draw(in: fill, angle: 0)

        if active {
            let stripeWidth: CGFloat = 34
            var x = -stripeWidth + (shimmer * 70).truncatingRemainder(dividingBy: stripeWidth * 2)
            while x < fillRect.maxX {
                let stripe = NSBezierPath()
                stripe.move(to: NSPoint(x: x, y: fillRect.maxY))
                stripe.line(to: NSPoint(x: x + stripeWidth, y: fillRect.minY))
                stripe.line(to: NSPoint(x: x + stripeWidth + 10, y: fillRect.minY))
                stripe.line(to: NSPoint(x: x + 10, y: fillRect.maxY))
                stripe.close()
                NSColor(calibratedWhite: 1, alpha: 0.20).setFill()
                stripe.fill()
                x += stripeWidth * 2
            }
        }

        NSColor(calibratedWhite: 1, alpha: active ? 0.36 : 0.16).setStroke()
        base.lineWidth = 1
        base.stroke()
    }
}

final class PlaylistRowView: NSView {
    let nameLabel = NSTextField(labelWithString: "")
    let countLabel = NSTextField(labelWithString: "")
    let badgeLabel = NSTextField(labelWithString: "")
    var onClick: (() -> Void)?
    private var trackingAreaRef: NSTrackingArea?
    private var hovered = false {
        didSet {
            needsDisplay = true
        }
    }
    var selected = false {
        didSet {
            updateColors()
            needsDisplay = true
        }
    }
    var badge = "" {
        didSet {
            badgeLabel.stringValue = badge
            badgeLabel.isHidden = badge.isEmpty
        }
    }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        nameLabel.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.frame = NSRect(x: 16, y: 12, width: frameRect.width - 116, height: 22)

        countLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        countLabel.frame = NSRect(x: 16, y: 35, width: frameRect.width - 32, height: 18)

        badgeLabel.alignment = .center
        badgeLabel.font = NSFont.systemFont(ofSize: 11, weight: .bold)
        badgeLabel.frame = NSRect(x: frameRect.width - 88, y: 15, width: 70, height: 24)
        badgeLabel.isHidden = true
        badgeLabel.wantsLayer = true
        badgeLabel.layer?.cornerRadius = 9
        badgeLabel.layer?.masksToBounds = true

        addSubview(nameLabel)
        addSubview(countLabel)
        addSubview(badgeLabel)
        updateColors()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12)

        if selected {
            NSGradient(colors: [
                NSColor(calibratedRed: 0.02, green: 0.58, blue: 0.78, alpha: 0.98),
                NSColor(calibratedRed: 0.10, green: 0.77, blue: 0.74, alpha: 0.96)
            ])?.draw(in: path, angle: 0)
        } else {
            NSColor(calibratedWhite: 1, alpha: hovered ? 0.135 : 0.08).setFill()
            path.fill()
        }

        let stroke = selected
            ? NSColor(calibratedRed: 0.66, green: 0.96, blue: 1.0, alpha: 0.72)
            : NSColor(calibratedWhite: 1, alpha: hovered ? 0.26 : 0.12)
        stroke.setStroke()
        path.lineWidth = selected ? 1.5 : 1
        path.stroke()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef = trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        trackingAreaRef = area
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    func updateColors() {
        nameLabel.textColor = selected ? .white : NSColor(calibratedWhite: 0.96, alpha: 1)
        countLabel.textColor = selected ? NSColor(calibratedWhite: 1, alpha: 0.78) : NSColor(calibratedWhite: 1, alpha: 0.55)
        badgeLabel.textColor = selected ? NSColor(calibratedRed: 0.02, green: 0.13, blue: 0.17, alpha: 1) : NSColor(calibratedRed: 0.88, green: 0.98, blue: 1, alpha: 1)
        badgeLabel.layer?.backgroundColor = (selected
            ? NSColor(calibratedRed: 0.72, green: 0.98, blue: 1, alpha: 1)
            : NSColor(calibratedWhite: 1, alpha: 0.15)).cgColor
    }
}

final class SwimPlaylistController: NSObject {
    var model: AppModel
    var window: NSWindow!
    var selectedIndex = 0
    var rowViews: [PlaylistRowView] = []
    var currentPlan: SyncPlan?
    var isTransferring = false
    var transferControl: TransferControl?
    var transferStartDate: Date?
    var isAnalyzingBPM = false
    var tempoCache: [String: PlaylistTempoInfo] = [:]
    var albumArtCache: [String: NSImage] = [:]
    var knownTempoCache: [String: Int] = [:]
    var missingTempoCache: Set<String> = []
    var tempoFilterRange = TempoRange.full
    var tempoFilterEnabled = false
    var bpmCache: BPMCache

    let currentLabel = NSTextField(labelWithString: "")
    let deviceLabel = NSTextField(labelWithString: "")
    let statusLabel = NSTextField(labelWithString: "")
    let selectedTitleLabel = NSTextField(labelWithString: "")
    let selectedDetailLabel = NSTextField(labelWithString: "")
    let coverView = PlaylistCoverView(frame: .zero)
    let tempoView = TempoDistributionView(frame: .zero)
    let tempoStatsLabel = NSTextField(labelWithString: "")
    let tempoRangeLabel = NSTextField(labelWithString: "")
    let resetTempoRangeButton = NSButton(title: "All BPM", target: nil, action: nil)
    let analyzeBPMButton = NSButton(title: "Analyze BPM", target: nil, action: nil)
    let deltaLabel = NSTextField(labelWithString: "")
    let trackPreviewView = TrackPreviewStripView(frame: .zero)
    let transferDetailLabel = NSTextField(labelWithString: "")
    let progressPercentLabel = NSTextField(labelWithString: "")
    let progressBar = ProgressMeterView(frame: .zero)
    let changeButton = NSButton(title: "Change Playlist", target: nil, action: nil)
    let refreshButton = NSButton(title: "Refresh", target: nil, action: nil)
    let pauseButton = NSButton(title: "Pause", target: nil, action: nil)
    let ejectButton = NSButton(title: "Eject", target: nil, action: nil)
    let listContainer = NSView(frame: .zero)
    let scrollView = NSScrollView(frame: .zero)

    init(model: AppModel) {
        self.model = model
        self.bpmCache = loadBPMCache(from: model.playlistAnalysisURL.appendingPathComponent("bpm_cache.json"))
        if let currentName = model.currentMatch?.name,
           let index = model.playlists.firstIndex(where: { $0.name == currentName }) {
            selectedIndex = index
        }
        super.init()
        buildWindow()
        rebuildPlaylistRows()
        updateSelection()
    }

    func show() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func buildWindow() {
        let size = NSSize(width: 1040, height: 760)
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.title = appDisplayName
        window.isReleasedWhenClosed = false

        let root = SwimBackgroundView(frame: NSRect(origin: .zero, size: size))
        root.autoresizingMask = [.width, .height]
        window.contentView = root

        let title = NSTextField(labelWithString: appDisplayName)
        title.font = NSFont.systemFont(ofSize: 26, weight: .black)
        title.textColor = .white
        title.frame = NSRect(x: 34, y: 30, width: 560, height: 36)
        root.addSubview(title)

        let subtitle = NSTextField(labelWithString: "Pick the set you want before the next swim.")
        subtitle.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        subtitle.textColor = NSColor(calibratedWhite: 1, alpha: 0.72)
        subtitle.frame = NSRect(x: 36, y: 72, width: 380, height: 22)
        root.addSubview(subtitle)

        deviceLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        deviceLabel.textColor = NSColor(calibratedRed: 0.74, green: 0.98, blue: 1, alpha: 1)
        deviceLabel.alignment = .right
        deviceLabel.frame = NSRect(x: 630, y: 36, width: 370, height: 22)
        root.addSubview(deviceLabel)

        currentLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        currentLabel.textColor = NSColor(calibratedWhite: 1, alpha: 0.82)
        currentLabel.alignment = .right
        currentLabel.frame = NSRect(x: 600, y: 64, width: 400, height: 24)
        root.addSubview(currentLabel)

        let leftPanel = RoundedPanel(frame: NSRect(x: 28, y: 122, width: 340, height: 600))
        leftPanel.fillColor = NSColor(calibratedWhite: 1, alpha: 0.075)
        root.addSubview(leftPanel)

        let leftHeader = NSTextField(labelWithString: "PLAYLISTS")
        leftHeader.font = NSFont.systemFont(ofSize: 11, weight: .bold)
        leftHeader.textColor = NSColor(calibratedWhite: 1, alpha: 0.46)
        leftHeader.frame = NSRect(x: 18, y: 14, width: 120, height: 16)
        leftPanel.addSubview(leftHeader)

        scrollView.frame = NSRect(x: 10, y: 42, width: 320, height: 546)
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        leftPanel.addSubview(scrollView)

        let rightPanel = RoundedPanel(frame: NSRect(x: 388, y: 122, width: 624, height: 600))
        rightPanel.fillColor = NSColor(calibratedWhite: 1, alpha: 0.090)
        root.addSubview(rightPanel)

        selectedTitleLabel.font = NSFont.systemFont(ofSize: 22, weight: .bold)
        selectedTitleLabel.textColor = .white
        selectedTitleLabel.frame = NSRect(x: 24, y: 22, width: 570, height: 32)
        rightPanel.addSubview(selectedTitleLabel)

        selectedDetailLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        selectedDetailLabel.textColor = NSColor(calibratedWhite: 1, alpha: 0.66)
        selectedDetailLabel.frame = NSRect(x: 26, y: 58, width: 570, height: 24)
        rightPanel.addSubview(selectedDetailLabel)

        coverView.frame = NSRect(x: 24, y: 96, width: 164, height: 164)
        rightPanel.addSubview(coverView)

        let tempoPanel = RoundedPanel(frame: NSRect(x: 210, y: 92, width: 390, height: 226))
        tempoPanel.fillColor = NSColor(calibratedWhite: 0, alpha: 0.18)
        tempoPanel.strokeColor = NSColor(calibratedRed: 0.45, green: 0.94, blue: 1.0, alpha: 0.14)
        rightPanel.addSubview(tempoPanel)

        tempoView.frame = NSRect(x: 10, y: 8, width: 370, height: 170)
        tempoPanel.addSubview(tempoView)
        tempoView.onRangeChange = { [weak self] range, enabled in
            guard let self = self else { return }
            self.tempoFilterRange = range
            self.tempoFilterEnabled = enabled
            self.updateSelection()
        }

        tempoStatsLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        tempoStatsLabel.textColor = NSColor(calibratedWhite: 1, alpha: 0.56)
        tempoStatsLabel.frame = NSRect(x: 14, y: 180, width: 205, height: 16)
        tempoPanel.addSubview(tempoStatsLabel)

        tempoRangeLabel.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        tempoRangeLabel.textColor = NSColor(calibratedRed: 0.78, green: 1.0, blue: 0.88, alpha: 0.86)
        tempoRangeLabel.lineBreakMode = .byTruncatingTail
        tempoRangeLabel.frame = NSRect(x: 14, y: 202, width: 205, height: 16)
        tempoPanel.addSubview(tempoRangeLabel)

        resetTempoRangeButton.target = self
        resetTempoRangeButton.action = #selector(resetTempoRange)
        resetTempoRangeButton.bezelStyle = .rounded
        resetTempoRangeButton.frame = NSRect(x: 226, y: 194, width: 72, height: 26)
        tempoPanel.addSubview(resetTempoRangeButton)

        analyzeBPMButton.target = self
        analyzeBPMButton.action = #selector(analyzeSelectedPlaylistBPM)
        analyzeBPMButton.bezelStyle = .rounded
        analyzeBPMButton.title = "Analyze"
        analyzeBPMButton.frame = NSRect(x: 304, y: 194, width: 74, height: 26)
        tempoPanel.addSubview(analyzeBPMButton)

        let previewPanel = RoundedPanel(frame: NSRect(x: 24, y: 336, width: 576, height: 112))
        previewPanel.fillColor = NSColor(calibratedWhite: 0, alpha: 0.18)
        previewPanel.strokeColor = NSColor(calibratedRed: 0.45, green: 0.94, blue: 1.0, alpha: 0.14)
        rightPanel.addSubview(previewPanel)

        trackPreviewView.frame = NSRect(x: 0, y: 0, width: 576, height: 112)
        previewPanel.addSubview(trackPreviewView)

        deltaLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        deltaLabel.textColor = NSColor(calibratedRed: 0.77, green: 1.00, blue: 0.86, alpha: 0.94)
        deltaLabel.frame = NSRect(x: 26, y: 462, width: 570, height: 20)
        rightPanel.addSubview(deltaLabel)

        progressBar.frame = NSRect(x: 26, y: 494, width: 464, height: 18)
        progressBar.fraction = 0
        progressBar.active = false
        rightPanel.addSubview(progressBar)

        progressPercentLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .bold)
        progressPercentLabel.textColor = NSColor(calibratedWhite: 1, alpha: 0.80)
        progressPercentLabel.alignment = .right
        progressPercentLabel.frame = NSRect(x: 502, y: 490, width: 94, height: 24)
        progressPercentLabel.stringValue = "0%"
        rightPanel.addSubview(progressPercentLabel)

        transferDetailLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        transferDetailLabel.textColor = NSColor(calibratedWhite: 1, alpha: 0.52)
        transferDetailLabel.lineBreakMode = .byTruncatingMiddle
        transferDetailLabel.frame = NSRect(x: 26, y: 520, width: 570, height: 20)
        rightPanel.addSubview(transferDetailLabel)

        statusLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        statusLabel.textColor = NSColor(calibratedWhite: 1, alpha: 0.66)
        statusLabel.frame = NSRect(x: 26, y: 542, width: 570, height: 20)
        rightPanel.addSubview(statusLabel)

        changeButton.target = self
        changeButton.action = #selector(changePlaylist)
        changeButton.bezelStyle = .rounded
        changeButton.keyEquivalent = "\r"
        changeButton.frame = NSRect(x: 474, y: 562, width: 122, height: 32)
        rightPanel.addSubview(changeButton)

        refreshButton.target = self
        refreshButton.action = #selector(refresh)
        refreshButton.bezelStyle = .rounded
        refreshButton.frame = NSRect(x: 26, y: 562, width: 76, height: 32)
        rightPanel.addSubview(refreshButton)

        pauseButton.target = self
        pauseButton.action = #selector(pauseTransfer)
        pauseButton.bezelStyle = .rounded
        pauseButton.frame = NSRect(x: 112, y: 562, width: 78, height: 32)
        pauseButton.isHidden = true
        pauseButton.isEnabled = false
        rightPanel.addSubview(pauseButton)

        ejectButton.target = self
        ejectButton.action = #selector(ejectDevice)
        ejectButton.bezelStyle = .rounded
        ejectButton.frame = NSRect(x: 200, y: 562, width: 74, height: 32)
        rightPanel.addSubview(ejectButton)
    }

    func rebuildPlaylistRows() {
        rowViews.removeAll()
        listContainer.subviews.forEach { $0.removeFromSuperview() }

        let rowHeight: CGFloat = 68
        let totalHeight = max(CGFloat(model.playlists.count) * rowHeight + 8, scrollView.frame.height)
        listContainer.frame = NSRect(x: 0, y: 0, width: scrollView.frame.width - 16, height: totalHeight)

        for (index, playlist) in model.playlists.enumerated() {
            let row = PlaylistRowView(frame: NSRect(x: 2, y: CGFloat(index) * rowHeight + 2, width: listContainer.frame.width - 8, height: 58))
            row.nameLabel.stringValue = playlist.name
            row.countLabel.stringValue = "\(playlist.count) audio file\(playlist.count == 1 ? "" : "s")"
            if let match = model.currentMatch, match.name == playlist.name {
                row.badge = match.exact ? "CURRENT" : percentText(match.score)
            }
            row.onClick = { [weak self] in
                self?.selectedIndex = index
                self?.updateSelection()
            }
            listContainer.addSubview(row)
            rowViews.append(row)
        }

        scrollView.documentView = listContainer
    }

    func updateSelection() {
        deviceLabel.stringValue = "Device: \(model.deviceURL.lastPathComponent)  |  \(model.deviceFiles.count) songs"

        if let match = model.currentMatch {
            if match.exact {
                currentLabel.stringValue = "Current playlist: \(match.name)"
            } else {
                currentLabel.stringValue = "Current playlist: probably \(match.name) (\(percentText(match.score)) match)"
            }
        } else if model.deviceFiles.isEmpty {
            currentLabel.stringValue = "Current playlist: empty"
        } else {
            currentLabel.stringValue = "Current playlist: unknown (\(model.deviceFiles.count) songs)"
        }

        guard !model.playlists.isEmpty else {
            selectedTitleLabel.stringValue = "No playlist folders"
            selectedDetailLabel.stringValue = "Create folders inside \(model.playlistsURL.path)."
            deltaLabel.stringValue = ""
            trackPreviewView.items = []
            transferDetailLabel.stringValue = ""
            progressPercentLabel.stringValue = "0%"
            progressBar.fraction = 0
            progressBar.active = false
            currentPlan = nil
            statusLabel.stringValue = "Waiting for local playlists."
            changeButton.isEnabled = false
            analyzeBPMButton.isEnabled = false
            resetTempoRangeButton.isEnabled = false
            pauseButton.isHidden = true
            pauseButton.isEnabled = false
            ejectButton.isEnabled = !isTransferring
            return
        }

        selectedIndex = max(0, min(selectedIndex, model.playlists.count - 1))
        for (index, row) in rowViews.enumerated() {
            row.selected = index == selectedIndex
        }

        let playlist = model.playlists[selectedIndex]
        let tempo = cachedTempoInfo(for: playlist)
        let filtered = tempoFilteredPlaylist(for: playlist)
        let syncPlaylist = filtered.playlist
        let plan = syncPlan(for: syncPlaylist, deviceURL: model.deviceURL, deviceFiles: model.deviceFiles)
        currentPlan = plan
        selectedTitleLabel.stringValue = playlist.name
        if tempoFilterEnabled {
            selectedDetailLabel.stringValue = "\(syncPlaylist.count) of \(playlist.count) tracks in \(tempoFilterRange.label)  |  \(formatBytes(plan.totalBytes)) to transfer"
            deltaLabel.stringValue = "Delta (\(tempoFilterRange.label)): \(plan.shortSummary)"
        } else {
            selectedDetailLabel.stringValue = "\(playlist.count) track\(playlist.count == 1 ? "" : "s")  |  \(formatBytes(plan.totalBytes)) to transfer"
            deltaLabel.stringValue = "Delta: \(plan.shortSummary)"
        }
        coverView.playlistName = playlist.name
        if let imageURL = playlistImageURL(for: playlist.name, imagesURL: model.playlistImagesURL) {
            coverView.image = NSImage(contentsOf: imageURL)
        } else {
            coverView.image = nil
        }
        tempoView.info = tempo
        tempoView.filterRange = tempoFilterRange
        tempoView.filterEnabled = tempoFilterEnabled
        if let avg = tempo.average, let minTempo = tempo.minTempo, let maxTempo = tempo.maxTempo {
            tempoStatsLabel.stringValue = "avg \(avg) BPM  |  range \(minTempo)-\(maxTempo)  |  known \(tempo.tempos.count)/\(tempo.totalCount)"
        } else {
            tempoStatsLabel.stringValue = "click Analyze BPM"
        }
        if tempoFilterEnabled {
            tempoRangeLabel.stringValue = "load \(syncPlaylist.count)  |  missing BPM \(filtered.missingCount)"
        } else {
            tempoRangeLabel.stringValue = "drag handles to choose a BPM slice"
        }
        analyzeBPMButton.isEnabled = !isTransferring && !isAnalyzingBPM && !playlist.files.isEmpty
        resetTempoRangeButton.isEnabled = !isTransferring && tempoFilterEnabled

        if !isTransferring {
            progressBar.active = false
            progressBar.fraction = plan.hasChanges ? 0 : 1
            progressPercentLabel.stringValue = plan.hasChanges ? "0%" : "100%"
            if tempoFilterEnabled {
                transferDetailLabel.stringValue = plan.hasChanges ? "Only known tracks in range will load." : "This tempo range is already loaded."
            } else {
                transferDetailLabel.stringValue = plan.hasChanges ? "Shared songs stay on the headphones." : "Nothing to move."
            }
        }

        changeButton.title = plan.hasChanges ? "Change Playlist" : "Already Current"
        changeButton.isEnabled = syncPlaylist.count > 0 && plan.hasChanges && !isTransferring
        pauseButton.isHidden = !isTransferring
        pauseButton.isEnabled = isTransferring
        ejectButton.isEnabled = !isTransferring
        refreshButton.isEnabled = !isTransferring
        analyzeBPMButton.isEnabled = !isTransferring && !isAnalyzingBPM && !playlist.files.isEmpty

        if playlist.files.isEmpty {
            trackPreviewView.emptyMessage = "Drop MP3 files into this playlist."
            trackPreviewView.items = []
            statusLabel.stringValue = "This playlist is empty."
        } else if tempoFilterEnabled && syncPlaylist.files.isEmpty {
            trackPreviewView.emptyMessage = "No known tracks inside this BPM range."
            trackPreviewView.items = []
            statusLabel.stringValue = "No known tracks in range. Widen it or click Analyze."
        } else {
            trackPreviewView.emptyMessage = "No preview tracks."
            trackPreviewView.items = previewItems(for: syncPlaylist)
            if !plan.hasChanges {
                statusLabel.stringValue = tempoFilterEnabled
                    ? "This tempo range already matches the headphones."
                    : "This playlist already matches the headphones."
            } else if let match = model.currentMatch, match.name == playlist.name, match.exact {
                statusLabel.stringValue = "This is already on the headphones."
            } else {
                statusLabel.stringValue = "Ready for delta sync."
            }
        }
    }

    func cachedKnownTempo(for fileURL: URL) -> Int? {
        let key = fileURL.standardizedFileURL.path
        if let bpm = knownTempoCache[key] {
            return bpm
        }
        if missingTempoCache.contains(key) {
            return nil
        }
        guard let bpm = knownBPM(for: fileURL, cache: bpmCache) else {
            missingTempoCache.insert(key)
            return nil
        }
        knownTempoCache[key] = bpm
        return bpm
    }

    func tempoFilteredPlaylist(for playlist: Playlist) -> (playlist: Playlist, knownCount: Int, missingCount: Int) {
        guard tempoFilterEnabled else {
            let tempo = cachedTempoInfo(for: playlist)
            return (playlist, tempo.tempos.count, tempo.missingCount)
        }

        var files: [URL] = []
        var knownCount = 0
        var missingCount = 0
        let range = tempoFilterRange.clamped()

        for file in playlist.files {
            guard let bpm = cachedKnownTempo(for: file) else {
                missingCount += 1
                continue
            }
            knownCount += 1
            if range.contains(bpm) {
                files.append(file)
            }
        }

        return (Playlist(name: playlist.name, url: playlist.url, files: files), knownCount, missingCount)
    }

    func cachedAlbumArt(for fileURL: URL) -> NSImage? {
        let key = fileURL.standardizedFileURL.path
        if let cached = albumArtCache[key] {
            return cached
        }
        guard let image = albumArtworkFromID3(fileURL: fileURL) else {
            return nil
        }
        albumArtCache[key] = image
        return image
    }

    func previewItems(for playlist: Playlist) -> [TrackPreviewItem] {
        playlist.files.prefix(6).map { fileURL in
            TrackPreviewItem(
                title: fileURL.deletingPathExtension().lastPathComponent,
                image: cachedAlbumArt(for: fileURL)
            )
        }
    }

    func cachedTempoInfo(for playlist: Playlist) -> PlaylistTempoInfo {
        if let cached = tempoCache[playlist.name] {
            return cached
        }
        let info = tempoInfo(for: playlist, cache: bpmCache)
        tempoCache[playlist.name] = info
        return info
    }

    func applyProgress(_ progress: SyncProgress) {
        progressBar.active = progress.fraction < 1
        progressBar.fraction = progress.fraction
        let percent = Int((progress.fraction * 100).rounded())
        if let start = transferStartDate, progress.fraction > 0.01, progress.fraction < 1 {
            let elapsed = Date().timeIntervalSince(start)
            let totalEstimate = elapsed / progress.fraction
            progressPercentLabel.stringValue = "\(percent)% | \(formatDuration(totalEstimate - elapsed))"
        } else if progress.fraction >= 1 {
            progressPercentLabel.stringValue = "100% | 00:00"
        } else {
            progressPercentLabel.stringValue = "\(percent)% | --:--"
        }
        statusLabel.stringValue = progress.phase

        let byteText = progress.totalBytes > 0
            ? "\(formatBytes(progress.copiedBytes)) / \(formatBytes(progress.totalBytes))"
            : "\(progress.completedItems) / \(progress.totalItems) items"
        transferDetailLabel.stringValue = "\(byteText)  |  \(progress.detail)"
    }

    func setTransferControls(active: Bool) {
        isTransferring = active
        changeButton.isEnabled = !active
        refreshButton.isEnabled = !active
        ejectButton.isEnabled = !active
        analyzeBPMButton.isEnabled = !active && !isAnalyzingBPM
        resetTempoRangeButton.isEnabled = !active && tempoFilterEnabled
        pauseButton.isHidden = !active
        pauseButton.isEnabled = active
        pauseButton.title = "Pause"
    }

    @objc func resetTempoRange() {
        guard !isTransferring else {
            return
        }
        tempoFilterRange = .full
        tempoFilterEnabled = false
        tempoView.filterRange = tempoFilterRange
        tempoView.filterEnabled = false
        updateSelection()
    }

    @objc func refresh() {
        guard !isTransferring else {
            return
        }

        do {
            var refreshed = try loadModel()
            refreshed.playlists = loadPlaylists(from: refreshed.playlistsURL)
            model = refreshed
            bpmCache = loadBPMCache(from: model.playlistAnalysisURL.appendingPathComponent("bpm_cache.json"))
            tempoCache.removeAll()
            albumArtCache.removeAll()
            knownTempoCache.removeAll()
            missingTempoCache.removeAll()
            if let currentName = model.currentMatch?.name,
               let index = model.playlists.firstIndex(where: { $0.name == currentName }) {
                selectedIndex = index
            }
            rebuildPlaylistRows()
            updateSelection()
        } catch {
            statusLabel.stringValue = error.localizedDescription
        }
    }

    @objc func changePlaylist() {
        guard model.playlists.indices.contains(selectedIndex) else {
            return
        }

        let basePlaylist = model.playlists[selectedIndex]
        let filtered = tempoFilteredPlaylist(for: basePlaylist)
        let playlist = filtered.playlist
        guard !playlist.files.isEmpty else {
            statusLabel.stringValue = tempoFilterEnabled
                ? "No tracks in the selected BPM range."
                : "This playlist is empty."
            return
        }
        let plan = currentPlan ?? syncPlan(for: playlist, deviceURL: model.deviceURL, deviceFiles: model.deviceFiles)
        guard plan.hasChanges else {
            statusLabel.stringValue = tempoFilterEnabled
                ? "This tempo range already matches the headphones."
                : "This playlist already matches the headphones."
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = tempoFilterEnabled
            ? "Load \(playlist.files.count) tracks from \(basePlaylist.name)?"
            : "Change playlist to \(basePlaylist.name)?"
        let filterText = tempoFilterEnabled
            ? "Only known-BPM tracks in \(tempoFilterRange.label) will be loaded. \(filtered.missingCount) tracks are missing BPM data."
            : "Shared songs will stay on \(model.deviceURL.lastPathComponent)."
        alert.informativeText = "Delta sync will \(plan.shortSummary). \(filterText)"
        alert.addButton(withTitle: "Change")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        isTransferring = true
        transferControl = TransferControl()
        transferStartDate = Date()
        changeButton.isEnabled = false
        refreshButton.isEnabled = false
        ejectButton.isEnabled = false
        resetTempoRangeButton.isEnabled = false
        pauseButton.isHidden = false
        pauseButton.isEnabled = true
        pauseButton.title = "Pause"
        progressBar.fraction = 0
        progressBar.active = true
        progressPercentLabel.stringValue = "0% | --:--"
        transferDetailLabel.stringValue = "Starting..."
        statusLabel.stringValue = "Preparing delta transfer..."
        log(model, "GUI delta sync started: playlist='\(basePlaylist.name)' filter='\(tempoFilterEnabled ? tempoFilterRange.label : "all")' target='\(model.deviceURL.path)' summary='\(plan.shortSummary)' bytes=\(plan.totalBytes)")
        let control = transferControl

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                try syncPlaylistDelta(playlist, to: self.model.deviceURL, plan: plan, control: control) { progress in
                    DispatchQueue.main.async { [weak self] in
                        self?.applyProgress(progress)
                    }
                }
                DispatchQueue.main.async {
                    self.setTransferControls(active: false)
                    self.transferControl = nil
                    self.transferStartDate = nil
                    self.progressBar.active = false
                    self.progressBar.fraction = 1
                    self.progressPercentLabel.stringValue = "100% | 00:00"
                    log(self.model, "GUI delta sync finished: playlist='\(basePlaylist.name)' filter='\(self.tempoFilterEnabled ? self.tempoFilterRange.label : "all")' target='\(self.model.deviceURL.path)'")
                    self.refreshButton.isEnabled = true
                    self.refresh()
                    self.statusLabel.stringValue = self.tempoFilterEnabled
                        ? "Done. \(self.tempoFilterRange.label) from \(basePlaylist.name) is on the headphones."
                        : "Done. \(basePlaylist.name) is now on the headphones."
                    self.transferDetailLabel.stringValue = "Ready to eject."
                    NSSound(named: "Glass")?.play()
                }
            } catch {
                DispatchQueue.main.async {
                    self.setTransferControls(active: false)
                    self.transferControl = nil
                    self.transferStartDate = nil
                    self.progressBar.active = false
                    if case SyncStopped.paused = error {
                        log(self.model, "GUI delta sync paused: playlist='\(basePlaylist.name)' target='\(self.model.deviceURL.path)'")
                        self.refresh()
                        self.statusLabel.stringValue = "Paused. Current device state was kept."
                        self.transferDetailLabel.stringValue = "You can resume later by choosing a playlist again, or eject now."
                    } else {
                        log(self.model, "GUI delta sync failed: \(error.localizedDescription)")
                        self.updateSelection()
                        self.statusLabel.stringValue = "Sync failed: \(error.localizedDescription)"
                    }
                }
            }
        }
    }

    @objc func analyzeSelectedPlaylistBPM() {
        guard !isTransferring, !isAnalyzingBPM, model.playlists.indices.contains(selectedIndex) else {
            return
        }

        let playlist = model.playlists[selectedIndex]
        guard !playlist.files.isEmpty else {
            return
        }

        isAnalyzingBPM = true
        analyzeBPMButton.isEnabled = false
        analyzeBPMButton.title = "Analyzing"
        changeButton.isEnabled = false
        refreshButton.isEnabled = false
        ejectButton.isEnabled = false
        progressBar.active = true
        progressBar.fraction = 0
        progressPercentLabel.stringValue = "0% | --:--"
        statusLabel.stringValue = "Analyzing BPM..."
        transferDetailLabel.stringValue = "Reading audio rhythm for \(playlist.name)."

        let files = playlist.files
        let cacheURL = model.playlistAnalysisURL.appendingPathComponent("bpm_cache.json")
        let startDate = Date()
        var workingCache = bpmCache

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var foundCount = 0
            var estimatedCount = 0
            var tagCount = 0
            var cachedCount = 0

            for (index, file) in files.enumerated() {
                let bpm: Int?
                let source: String

                if let cached = cachedBPM(for: file, cache: workingCache) {
                    bpm = cached
                    source = "cache"
                    cachedCount += 1
                } else if let tagBPM = tempoFromID3(fileURL: file) {
                    bpm = tagBPM
                    source = "tag"
                    tagCount += 1
                    cacheBPM(tagBPM, source: source, for: file, cache: &workingCache)
                } else if let estimated = estimateBPM(fileURL: file) {
                    bpm = estimated
                    source = "estimated"
                    estimatedCount += 1
                    cacheBPM(estimated, source: source, for: file, cache: &workingCache)
                } else {
                    bpm = nil
                    source = "missing"
                }

                if bpm != nil {
                    foundCount += 1
                }

                if index % 8 == 0 {
                    try? saveBPMCache(workingCache, to: cacheURL)
                }

                let completed = index + 1
                let fraction = Double(completed) / Double(files.count)
                let elapsed = Date().timeIntervalSince(startDate)
                let eta = fraction > 0.02 ? formatDuration((elapsed / fraction) - elapsed) : "--:--"
                let detail = "\(file.deletingPathExtension().lastPathComponent)  |  \(source)"

                DispatchQueue.main.async {
                    self?.progressBar.fraction = fraction
                    self?.progressBar.active = fraction < 1
                    self?.progressPercentLabel.stringValue = "\(Int((fraction * 100).rounded()))% | \(eta)"
                    self?.statusLabel.stringValue = "Analyzing BPM \(completed)/\(files.count)"
                    self?.transferDetailLabel.stringValue = detail
                }
            }

            do {
                try saveBPMCache(workingCache, to: cacheURL)
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.bpmCache = workingCache
                    self.tempoCache.removeValue(forKey: playlist.name)
                    self.knownTempoCache.removeAll()
                    self.missingTempoCache.removeAll()
                    self.isAnalyzingBPM = false
                    self.progressBar.active = false
                    self.progressBar.fraction = 1
                    self.progressPercentLabel.stringValue = "100% | 00:00"
                    self.analyzeBPMButton.title = "Analyze"
                    self.updateSelection()
                    self.statusLabel.stringValue = "BPM analysis saved."
                    self.transferDetailLabel.stringValue = "found \(foundCount)/\(files.count)  |  cache \(cachedCount), tags \(tagCount), estimated \(estimatedCount)"
                    NSSound(named: "Glass")?.play()
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.isAnalyzingBPM = false
                    self.progressBar.active = false
                    self.analyzeBPMButton.title = "Analyze"
                    self.updateSelection()
                    self.statusLabel.stringValue = "BPM cache save failed."
                    self.transferDetailLabel.stringValue = error.localizedDescription
                }
            }
        }
    }

    @objc func pauseTransfer() {
        guard isTransferring else {
            return
        }

        transferControl?.requestPause()
        pauseButton.isEnabled = false
        pauseButton.title = "Pausing"
        statusLabel.stringValue = "Pausing after the current safe point..."
    }

    @objc func ejectDevice() {
        guard !isTransferring else {
            return
        }

        ejectButton.isEnabled = false
        statusLabel.stringValue = "Ejecting \(model.deviceURL.lastPathComponent)..."

        let devicePath = model.deviceURL.path
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
            process.arguments = ["eject", devicePath]

            do {
                try process.run()
                process.waitUntilExit()
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    if process.terminationStatus == 0 {
                        self.statusLabel.stringValue = "Ejected \(self.model.deviceURL.lastPathComponent)."
                        self.transferDetailLabel.stringValue = "Safe to unplug."
                        self.changeButton.isEnabled = false
                        self.refreshButton.isEnabled = false
                    } else {
                        self.statusLabel.stringValue = "Eject failed. Try Finder eject."
                        self.ejectButton.isEnabled = true
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self?.statusLabel.stringValue = "Eject failed: \(error.localizedDescription)"
                    self?.ejectButton.isEnabled = true
                }
            }
        }
    }
}

let autoMode = hasArg("--auto") || env("SWIM_AUTO_MODE") == "1"
if hasArg("--self-test") {
    do {
        try runSelfTest()
        print("self_test=ok")
        exit(0)
    } catch {
        print("self_test=failed: \(error.localizedDescription)")
        exit(1)
    }
}

if hasArg("--check") {
    do {
        let model = try loadModel()
        let current = model.currentMatch.map { match in
            match.exact ? match.name : "probably \(match.name) (\(percentText(match.score)))"
        } ?? (model.deviceFiles.isEmpty ? "empty" : "unknown")
        print("device=\(model.deviceURL.lastPathComponent)")
        print("device_files=\(model.deviceFiles.count)")
        print("playlists=\(model.playlists.count)")
        print("current=\(current)")
        exit(0)
    } catch {
        print("error=\(error.localizedDescription)")
        exit(1)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
var activeController: SwimPlaylistController?

do {
    let model = try loadModel()
    activeController = SwimPlaylistController(model: model)
    activeController?.show()
    app.run()
} catch {
    if autoMode {
        exit(0)
    }
    alertAndExit(error.localizedDescription)
}
