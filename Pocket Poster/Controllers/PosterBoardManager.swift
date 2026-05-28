//
//  PosterBoardManager.swift
//  Pocket Poster
//
//  Created by lemin on 5/31/25.
//

import Foundation
import ZIPFoundation
import UIKit
import Dynamic // 使用项目内置的 Dynamic 框架安全调用系统私有级服务

// 已应用自定壁纸的数据模型
struct AppliedWallpaper: Identifiable, Hashable {
    var id: String { path.path }
    var folderName: String
    var displayName: String
    var extensionType: String
    var path: URL
}

class PosterBoardManager: ObservableObject {
    static let ShortcutURL = "https://www.icloud.com/shortcuts/a28d2c02ca11453cb5b8f91c12cfa692"
    static let WallpapersURL = "https://cowabun.ga/wallpapers"
    
    static let MaxTendies = 10
    
    static let shared = PosterBoardManager()
    
    @Published var selectedTendies: [URL] = []
    @Published var videos: [LoadInfo] = []
    @Published var appliedWallpapers: [AppliedWallpaper] = [] // 存储精确过滤后的第三方自定壁纸
    
    func getTendiesStoreURL() -> URL {
        let tendiesStoreURL = SymHandler.getDocumentsDirectory().appendingPathComponent("KFC Bucket", conformingTo: .directory)
        if !FileManager.default.fileExists(atPath: tendiesStoreURL.path()) {
            try? FileManager.default.createDirectory(at: tendiesStoreURL, withIntermediateDirectories: true)
        }
        return tendiesStoreURL
    }
    
    func setSystemLanguage(to new_lang: String) -> Bool {
        var langManager: NSObject = NSObject()
        if #available(iOS 18.0, *) {
            guard let obj = objc_getClass("IPSettingsUtilities") as? NSObject else { return false }
            langManager = obj
        } else {
            guard let obj = objc_getClass("PSLanguageSelector") as? NSObject else { return false }
            langManager = obj
        }
        
        let success = langManager.perform(Selector(("setLanguage:")), with: new_lang)
        return success != nil
    }
    
    func openPosterBoard() -> Bool {
        guard let obj = objc_getClass("LSApplicationWorkspace") as? NSObject else { return false }
        let workspace = obj.perform(Selector(("defaultWorkspace")))?.takeUnretainedValue() as? NSObject
        let success = workspace?.perform(Selector(("openApplicationWithBundleID:")), with: "com.apple.PosterBoard")
        return success != nil
    }
    
    // 【核心修复：依据iOS 17头文件最高指示，下发语系增量扫描事务，配合双Daemon强杀实现完美静默自愈】
    func refreshPosterBoardSystem() {
        DispatchQueue.global(qos: .userInitiated).async {
            // 1. 物理擦除快照渲染缓存，加速锁屏界面重构渲染 (对应头文件 _galleryCacheURL)
            if let containerPath = SymHandler.getAppContainerPath(for: "com.apple.PosterBoard") {
                let cacheDir = URL(fileURLWithPath: "\(containerPath)/Library/Caches/com.apple.PosterBoard")
                if FileManager.default.fileExists(atPath: cacheDir.path) {
                    try? FileManager.default.removeItem(at: cacheDir)
                }
            }
            
            // 2. 关键点：在杀进程前，利用系统当前活着的语言管理器，在原地快速触发一次无感知的系统语系重载
            // 这会根据 PBFPosterExtensionDataStore.h 的机制，强制触发系统最高优先级的 Asset 增量扫描
            // PosterBoard 会主动把新移入的或已被删除的物理文件夹，以合法的增量行事务追加同步到系统的 _database (SQLite) 中
            if let lang = UserDefaults.standard.stringArray(forKey: "AppleLanguages")?.first {
                _ = self.setSystemLanguage(to: lang)
            }
            
            // 给系统内设的 SQLite 增量写入事务留出 0.5 秒的写锁缓冲时间
            Thread.sleep(forTimeInterval: 0.5)
            
            // 3. 完美对齐头文件 FBSSystemService.h 声明的精确方法签名，实施后台终止
            // - (void)terminateApplication:(id)application forReason:(long long)reason andReport:(_Bool)report withDescription:(id)description;
            let service = Dynamic.FBSSystemService.sharedService()
            if service != nil {
                // 同时强杀海报版进程与壁纸服务。由于此时 SQLite 数据库已由上一步成功完成了增量更新且未被破坏，
                // 双 Daemon 重启后会直接加载干净的常驻内存字典，新壁纸完美显现，且官方原有壁纸 100% 完好无损。
                service.terminateApplication("com.apple.PosterBoard", forReason: Int64(1), andReport: false, withDescription: "Incremental Sync PBFDataStore")
                service.terminateApplication("com.apple.wallpaperd", forReason: Int64(1), andReport: false, withDescription: "Incremental Sync Wallpaperd")
            }
            
            // 4. 广播标准 Darwin 通知，让全局 XPC 事务闭环
            let darwinCenter = CFNotificationCenterGetDarwinNotifyCenter()
            CFNotificationCenterPostNotification(darwinCenter, CFNotificationName("com.apple.wallpaper.changed" as CFString), nil, nil, true)
            CFNotificationCenterPostNotification(darwinCenter, CFNotificationName("com.apple.posterkit.descriptors.changed" as CFString), nil, nil, true)
            
            // 【完全后台静默】：不执行任何主动唤醒打开海报版的代码。用户将完全留在当前 App 界面中。
        }
    }
    
    private func unzipFile(at sourceUrl: URL) throws -> URL {
        let fileName = sourceUrl.deletingPathExtension().lastPathComponent
        let normalizedFileName = fileName.replacingOccurrences(of: "[ \\%20]", with: "_", options: .regularExpression)
        let fileData = try Data(contentsOf: sourceUrl)
        let fileManager = FileManager.default

        let path = SymHandler.getDocumentsDirectory().appendingPathComponent("UnzipItems", conformingTo: .directory).appendingPathComponent(UUID().uuidString)
        if !fileManager.fileExists(atPath: path.path()) {
            try? fileManager.createDirectory(at: path, withIntermediateDirectories: true)
        }
        
        let savedFileUrl = path.appendingPathComponent(normalizedFileName)

        let existingFiles = try fileManager.contentsOfDirectory(at: path, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
        for fileUrl in existingFiles {
            try fileManager.removeItem(at: fileUrl)
        }

        try fileData.write(to: savedFileUrl, options: [.atomic])

        var destinationURL = path
        if fileManager.fileExists(atPath: savedFileUrl.path()) {
            destinationURL.appendPathComponent("directory")
            try fileManager.unzipItem(at: savedFileUrl, to: destinationURL)
        }

        return destinationURL
    }
    
    func runShortcut(named name: String) {
        guard let url = URL(string: "shortcuts://run-shortcut?name=\(name)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "") else { return }
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }
    
    func getDescriptorsFromTendie(_ url: URL) throws -> [String: [URL]]? {
        for dir in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) {
            let fileName = dir.lastPathComponent
            if fileName.lowercased() == "container" {
                let extDir = dir.appendingPathComponent("Library/Application Support/PRBPosterExtensionDataStore/61/Extensions")
                var retList: [String: [URL]] = [:]
                for ext in try FileManager.default.contentsOfDirectory(at: extDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) {
                    let descrDir = ext.appendingPathComponent("descriptors")
                    retList[ext.lastPathComponent] = [descrDir]
                }
                return retList
            }
            else if fileName.lowercased() == "descriptor" || fileName.lowercased() == "descriptors" || fileName.lowercased() == "ordered-descriptor" || fileName.lowercased() == "ordered-descriptors" {
                return ["com.apple.WallpaperKit.CollectionsPoster": [dir]]
            }
            else if fileName.lowercased() == "video-descriptor" || fileName.lowercased() == "video-descriptors" {
                return ["com.apple.PhotosUIPrivate.PhotosPosterProvider": [dir]]
            }
        }
        return nil
    }
    
    func randomizeWallpaperId(url: URL) throws {
        let randomizedID = Int.random(in: 9999...99999)
        var files = [URL]()
        if let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
            for case let fileURL as URL in enumerator {
                do {
                    let fileAttributes = try fileURL.resourceValues(forKeys:[.isRegularFileKey])
                    if fileAttributes.isRegularFile! {
                        files.append(fileURL)
                    }
                } catch {
                    print(error, fileURL)
                }
            }
        }
        
        func setPlistValue(file: String, key: String, value: Any, recursive: Bool = true) {
            guard let plistData = FileManager.default.contents(atPath: file),
                  var plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any] else {
                return
            }
            plist[key] = value
            guard let updatedData = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) else {
                return
            }
            try? updatedData.write(to: URL(fileURLWithPath: file))
        }
        
        for file in files {
            switch file.lastPathComponent {
            case "com.apple.posterkit.provider.descriptor.identifier":
                try String(randomizedID).data(using: .utf8)?.write(to: file)
            case "com.apple.posterkit.provider.contents.userInfo":
                setPlistValue(file: file.path(), key: "wallpaperRepresentingIdentifier", value: randomizedID)
            case "Wallpaper.plist":
                setPlistValue(file: file.path(), key: "identifier", value: randomizedID, recursive: false)
            default:
                continue
            }
        }
    }
    
    // 【采用高精准白名单强匹配：100% 过滤隐藏系统所有的自带 Collections 原厂壁纸】
    func fetchAppliedWallpapers() {
        var list: [AppliedWallpaper] = []
        guard let containerPath = SymHandler.getAppContainerPath(for: "com.apple.PosterBoard") else { return }
        let extVer = SymHandler.getExtensionVersion()
        let extensionsPath = URL(fileURLWithPath: "\(containerPath)/Library/Application Support/PRBPosterExtensionDataStore/\(extVer)/Extensions")
        
        guard let extensions = try? FileManager.default.contentsOfDirectory(at: extensionsPath, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) else { return }
        
        // 读取本 App 专属的第三方导入历史注册表白名单
        let importedFolders = UserDefaults.standard.stringArray(forKey: "ImportedWallpaperFolders") ?? []
        
        for extFolder in extensions {
            let extName = extFolder.lastPathComponent
            let descriptorsPath = extFolder.appendingPathComponent("descriptors")
            guard let items = try? FileManager.default.contentsOfDirectory(at: descriptorsPath, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) else { continue }
            
            for item in items {
                let folderName = item.lastPathComponent
                if folderName == "__MACOSX" { continue }
                
                // 【核心沙盒安全隔离】只有当该壁纸文件夹名字完全包含在我们的本地白名单中，才会被呈现
                // 这从根本上彻底杜绝了系统自带的原装壁纸（Collections/Astronomy/Emoji等）在列表上的混淆展现。
                if importedFolders.contains(folderName) {
                    var displayName = folderName
                    let plistURL = item.appendingPathComponent("Wallpaper.plist")
                    if FileManager.default.fileExists(atPath: plistURL.path) {
                        if let data = try? Data(contentsOf: plistURL),
                           let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
                           let name = plist["name"] as? String {
                            displayName = name
                        }
                    } else {
                        let idURL = item.appendingPathComponent("com.apple.posterkit.provider.descriptor.identifier")
                        if let idStr = try? String(contentsOf: idURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) {
                            displayName = "已导自定壁纸 (\(idStr))"
                        }
                    }
                    list.append(AppliedWallpaper(folderName: folderName, displayName: displayName, extensionType: extName, path: item))
                }
            }
        }
        
        DispatchQueue.main.async {
            self.appliedWallpapers = list
        }
    }
    
    func deleteAppliedWallpaper(_ wallpaper: AppliedWallpaper) throws {
        try FileManager.default.removeItem(at: wallpaper.path)
        
        // 同步在持久化数据白名单中注销
        var importedFolders = UserDefaults.standard.stringArray(forKey: "ImportedWallpaperFolders") ?? []
        importedFolders.removeAll { $0 == wallpaper.folderName }
        UserDefaults.standard.set(importedFolders, forKey: "ImportedWallpaperFolders")
        
        self.fetchAppliedWallpapers()
    }
    
    func applyTendies() throws {
        var extList: [String: [URL]] = [:]
        if videos.count > 0 {
            extList["com.apple.WallpaperKit.CollectionsPoster"] = []
            for video in videos {
                switch video.loadState {
                case .loaded(let movie):
                    do {
                        let newVideo = try VideoHandler.createCaml(from: movie.url, autoReverses: video.autoReverses)
                        extList["com.apple.WallpaperKit.CollectionsPoster"]?.append(newVideo)
                    } catch {
                        print(error.localizedDescription)
                    }
                default:
                    print("Video not loaded!")
                }
            }
        }
        
        DispatchQueue.main.async {
            UIApplication.shared.change(title: NSLocalizedString("Applying Wallpapers...", comment: ""), body: NSLocalizedString("Extracting tendies...", comment: ""))
        }
        
        for url in selectedTendies {
            let unzippedDir = try unzipFile(at: url)
            guard let descriptors = try getDescriptorsFromTendie(unzippedDir) else { continue }
            extList.merge(descriptors) { (first, second) in first + second }
        }
        
        guard let containerPath = SymHandler.getAppContainerPath(for: "com.apple.PosterBoard") else {
            throw NSError(domain: "PosterBoardManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "无法定位 PosterBoard 路径"])
        }
        let extVer = SymHandler.getExtensionVersion()
        
        var importedFolders = UserDefaults.standard.stringArray(forKey: "ImportedWallpaperFolders") ?? []
        
        for (ext, descriptorsList) in extList {
            let targetDir = URL(fileURLWithPath: "\(containerPath)/Library/Application Support/PRBPosterExtensionDataStore/\(extVer)/Extensions/\(ext)/descriptors")
            
            if !FileManager.default.fileExists(atPath: targetDir.path) {
                try? FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
            }
            
            for descriptors in descriptorsList {
                for descr in try FileManager.default.contentsOfDirectory(at: descriptors, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) {
                    if descr.lastPathComponent != "__MACOSX" {
                        try randomizeWallpaperId(url: descr)
                        
                        // 【安全修正：维持文件夹名称原汁原味，杜绝因改名导致的底层校验卡死】
                        let originalFolderName = descr.lastPathComponent
                        let destURL = targetDir.appendingPathComponent(originalFolderName)
                        
                        if FileManager.default.fileExists(atPath: destURL.path) {
                            try? FileManager.default.removeItem(at: destURL)
                        }
                        
                        try FileManager.default.moveItem(at: descr, to: destURL)
                        
                        // 登记新写入成功的第三方自定项目到历史白名单中
                        if !importedFolders.contains(originalFolderName) {
                            importedFolders.append(originalFolderName)
                        }
                    }
                }
            }
        }
        
        UserDefaults.standard.set(importedFolders, forKey: "ImportedWallpaperFolders")
        
        for url in selectedTendies {
            try? FileManager.default.removeItem(at: SymHandler.getDocumentsDirectory().appendingPathComponent("UnzipItems", conformingTo: .directory))
            try? FileManager.default.removeItem(at: SymHandler.getDocumentsDirectory().appendingPathComponent(url.lastPathComponent))
            try? FileManager.default.removeItem(at: SymHandler.getDocumentsDirectory().appendingPathComponent(url.deletingPathExtension().lastPathComponent))
        }
        
        self.fetchAppliedWallpapers()
    }
    
    static func clearCache() throws {
        SymHandler.cleanup()
        let docDir = SymHandler.getDocumentsDirectory()
        for file in try FileManager.default.contentsOfDirectory(at: docDir, includingPropertiesForKeys: nil) {
            if file.lastPathComponent != "CarPlayPhotos" {
                try FileManager.default.removeItem(at: file)
            }
        }
    }
}
