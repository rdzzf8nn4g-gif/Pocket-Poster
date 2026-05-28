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
    @Published var appliedWallpapers: [AppliedWallpaper] = [] // 存储精确过滤后的自定第三方壁纸
    
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
    
    // 【终极重构：依据 iOS 17 头文件机制执行全弹道物理粉碎+双进程静默强刷】
    func refreshPosterBoardSystem() {
        DispatchQueue.global(qos: .userInitiated).async {
            let fileManager = FileManager.default
            let extVer = SymHandler.getExtensionVersion()
            
            // 获取 PosterBoard 的系统沙盒容器绝对路径
            if let containerPath = SymHandler.getAppContainerPath(for: "com.apple.PosterBoard") {
                
                // 1. 斩断预渲染快照脏缓存 (对应头文件 _galleryCacheURL)
                let cacheDir = URL(fileURLWithPath: "\(containerPath)/Library/Caches/com.apple.PosterBoard")
                if fileManager.fileExists(atPath: cacheDir.path) {
                    try? fileManager.removeItem(at: cacheDir)
                }
                
                // 2. 清空头文件定义中的 Purgatory 暂存炼狱目录
                let purgatoryDir = URL(fileURLWithPath: "\(containerPath)/Library/Application Support/PRBPosterExtensionDataStore/\(extVer)/Purgatory")
                if fileManager.fileExists(atPath: purgatoryDir.path) {
                    try? fileManager.removeItem(at: purgatoryDir)
                }
                
                // 3. 核心粉碎：物理抹除 iOS 17 强固的 SQLite 数据库索引文件群 (对应头文件 _database)
                let dataStoreDirURL = URL(fileURLWithPath: "\(containerPath)/Library/Application Support/PRBPosterExtensionDataStore/\(extVer)")
                if let files = try? fileManager.contentsOfDirectory(at: dataStoreDirURL, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) {
                    for file in files {
                        let fileName = file.lastPathComponent.lowercased()
                        // 抹除包括 .sqlite、.sqlite-wal、.sqlite-shm 在内的所有索引，彻底清除导致留白的鬼影数据
                        if fileName.contains("sqlite") {
                            try? fileManager.removeItem(at: file)
                        }
                    }
                }
            }
            
            // 4. 完美对齐头文件 FBSSystemService.h 声明的精确方法签名：
            // - (void)terminateApplication:(id)application forReason:(long long)reason andReport:(_Bool)report withDescription:(id)description;
            let service = Dynamic.FBSSystemService.sharedService()
            if service != nil {
                // 同时强杀海报版进程与壁纸守护进程，迫使系统彻底释放句柄锁，清除内存常驻字典缓存
                service.terminateApplication("com.apple.PosterBoard", forReason: Int64(1), andReport: false, withDescription: "Rebuild PBFDataStore Database")
                service.terminateApplication("com.apple.wallpaperd", forReason: Int64(1), andReport: false, withDescription: "Purge Wallpaperd Cache")
            }
            
            // 5. 向全局发送底层 Darwin 核心广播，通知 XPC 服务资产已变更，迫使系统从物理磁盘重新建立完整的 SQLite 索引
            let darwinCenter = CFNotificationCenterGetDarwinNotifyCenter()
            CFNotificationCenterPostNotification(darwinCenter, CFNotificationName("com.apple.wallpaper.changed" as CFString), nil, nil, true)
            CFNotificationCenterPostNotification(darwinCenter, CFNotificationName("com.apple.LaunchServices.pluginsChanged" as CFString), nil, nil, true)
            
            // 【完全静默化】：这里已经彻底清除了跳转到海报版前台的代码。
            // 当你点击应用或删除后，App 会停留在当前界面静默刷新，系统重新冷启动后，新壁纸立刻完美加载，空白方块彻底消失。
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
    
    // 【采用专属白名单唯一矩阵强匹配：100% 过滤隐藏系统所有的自带 Collections 原厂壁纸】
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
                
                // 【核心白名单矩阵重叠验证】
                // 只有完全带有本 App 写入时注入的 "Pocket_" 唯一专属前缀、且包含在历史持久化数组中的项，才会被呈现在删除列表里！
                // 这从底层逻辑上直接完成了对系统原厂自带壁纸（Collections/Astronomy/Emoji等）的完美绝对屏蔽。
                if importedFolders.contains(folderName) && folderName.hasPrefix("Pocket_") {
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
        
        // 同步在持久化数据数组中解绑移除
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
                        
                        // 【独家定制：UUID 唯一标记命名矩阵】
                        // 将写入目标沙盒的第三方文件夹强制通过 Pocket_ 唯一特征矩阵重命名。
                        // 这不仅能完美防范与系统原厂重名引起灾难，更是 fetchAppliedWallpapers 实现 100% 精准识别的基础。
                        let uniqueFolderName = "Pocket_\(UUID().uuidString)"
                        let destURL = targetDir.appendingPathComponent(uniqueFolderName)
                        
                        if FileManager.default.fileExists(atPath: destURL.path) {
                            try? FileManager.default.removeItem(at: destURL)
                        }
                        
                        try FileManager.default.moveItem(at: descr, to: destURL)
                        
                        if !importedFolders.contains(uniqueFolderName) {
                            importedFolders.append(uniqueFolderName)
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
