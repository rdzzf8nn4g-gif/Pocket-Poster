//
//  PosterBoardManager.swift
//  Pocket Poster
//
//  Created by lemin on 5/31/25.
//

import Foundation
import ZIPFoundation
import UIKit
import Dynamic
import SQLite3 // 【核心依赖】使用原生 SQLite3 库对系统壁纸数据库进行微创注入

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
    @Published var appliedWallpapers: [AppliedWallpaper] = []
    
    func getTendiesStoreURL() -> URL {
        let tendiesStoreURL = SymHandler.getDocumentsDirectory().appendingPathComponent("KFC Bucket", conformingTo: .directory)
        if !FileManager.default.fileExists(atPath: tendiesStoreURL.path()) {
            try? FileManager.default.createDirectory(at: tendiesStoreURL, withIntermediateDirectories: true)
        }
        return tendiesStoreURL
    }
    
    // 【系统语系无感变更钩子】
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
    
    // 【精准定位系统沙盒中的海报版 SQLite 数据库】
    private func findDatabasePath() -> String? {
        guard let containerPath = SymHandler.getAppContainerPath(for: "com.apple.PosterBoard") else { return nil }
        let dataStoreURL = URL(fileURLWithPath: "\(containerPath)/Library/Application Support/PRBPosterExtensionDataStore")
        
        if let enumerator = FileManager.default.enumerator(at: dataStoreURL, includingPropertiesForKeys: nil) {
            for case let fileURL as URL in enumerator {
                if fileURL.lastPathComponent == "PBFPosterExtensionDataStoreSQLiteDatabase.sqlite3" {
                    return fileURL.path
                }
            }
        }
        return nil
    }
    
    // 【三表微创注入/剔除：严格满足 iOS 17 的外键 CASCADE 级联约束】
    private func injectIntoDatabase(uuid: String, providerId: String, isDelete: Bool) {
        guard let dbPath = findDatabasePath() else { return }
        
        var db: OpaquePointer?
        if sqlite3_open(dbPath, &db) == SQLITE_OK {
            // 设定写锁超时，防止与残留系统服务撞车
            sqlite3_exec(db, "PRAGMA busy_timeout = 2000;", nil, nil, nil)
            var stmt: OpaquePointer?
            
            if isDelete {
                // 删除时：基于系统的 ON DELETE CASCADE 约束，只需删主表即可
                let deleteQuery = "DELETE FROM poster WHERE UUID = ?;"
                if sqlite3_prepare_v2(db, deleteQuery, -1, &stmt, nil) == SQLITE_OK {
                    sqlite3_bind_text(stmt, 1, (uuid as NSString).utf8String, -1, nil)
                    sqlite3_step(stmt)
                }
                sqlite3_finalize(stmt)
            } else {
                // 写入时：必须三表联动注入，彻底满足系统底层校验！
                
                // 1. 注入 poster 主表
                let insertPoster = "INSERT OR IGNORE INTO poster (UUID, providerId) VALUES (?, ?);"
                if sqlite3_prepare_v2(db, insertPoster, -1, &stmt, nil) == SQLITE_OK {
                    sqlite3_bind_text(stmt, 1, (uuid as NSString).utf8String, -1, nil)
                    sqlite3_bind_text(stmt, 2, (providerId as NSString).utf8String, -1, nil)
                    sqlite3_step(stmt)
                }
                sqlite3_finalize(stmt)
                
                // 2. 注入 posterRoleMembership 映射表
                let insertRole = "INSERT OR IGNORE INTO posterRoleMembership (posterUUID, roleId, roleSortKey) VALUES (?, 'PRPosterRoleLockScreen', 0);"
                if sqlite3_prepare_v2(db, insertRole, -1, &stmt, nil) == SQLITE_OK {
                    sqlite3_bind_text(stmt, 1, (uuid as NSString).utf8String, -1, nil)
                    sqlite3_step(stmt)
                }
                sqlite3_finalize(stmt)
                
                // 3. 注入 posterAttributes 核心属性表
                let payload = "{\"attributeType\":\"PRPosterRoleAttributeTypeUsageMetadata\",\"creationDate\":\(Date().timeIntervalSince1970),\"lastModifiedDate\":\(Date().timeIntervalSince1970)}"
                let insertAttr = "INSERT OR IGNORE INTO posterAttributes (posterUUID, roleId, attributeIdentifier, attributePayload) VALUES (?, 'PRPosterRoleLockScreen', 'PRPosterRoleAttributeTypeUsageMetadata', ?);"
                if sqlite3_prepare_v2(db, insertAttr, -1, &stmt, nil) == SQLITE_OK {
                    sqlite3_bind_text(stmt, 1, (uuid as NSString).utf8String, -1, nil)
                    sqlite3_bind_text(stmt, 2, (payload as NSString).utf8String, -1, nil)
                    sqlite3_step(stmt)
                }
                sqlite3_finalize(stmt)
            }
            sqlite3_close(db)
        }
    }
    
    func openPosterBoard() -> Bool {
        guard let obj = objc_getClass("LSApplicationWorkspace") as? NSObject else { return false }
        let workspace = obj.perform(Selector(("defaultWorkspace")))?.takeUnretainedValue() as? NSObject
        let success = workspace?.perform(Selector(("openApplicationWithBundleID:")), with: "com.apple.PosterBoard")
        return success != nil
    }
    
    // 【全新加入的双杀机制：杀一次 -> 等2秒 -> 如果还在继续杀 -> 结束】
    func refreshPosterBoardSystem() {
        DispatchQueue.global(qos: .userInitiated).async {
            // 1. 清空残余图片快照
            if let containerPath = SymHandler.getAppContainerPath(for: "com.apple.PosterBoard") {
                let cacheDir = URL(fileURLWithPath: "\(containerPath)/Library/Caches/com.apple.PosterBoard")
                if FileManager.default.fileExists(atPath: cacheDir.path) {
                    try? FileManager.default.removeItem(at: cacheDir)
                }
            }
            
            // 2. 核心击杀协议：两秒双杀机制 (Double-Tap Kill)
            // 第一次：常规执行杀掉海报版进程及其关联渲染进程
            Dynamic.FBSSystemService.sharedService().terminateApplication("com.apple.PosterBoard", forReason: Int64(1), andReport: false, withDescription: "First Kill PosterBoard")
            Dynamic.FBSSystemService.sharedService().terminateApplication("com.apple.wallpaperd", forReason: Int64(1), andReport: false, withDescription: "First Kill Wallpaperd")
            
            // 等待两秒
            Thread.sleep(forTimeInterval: 2.0)
            
            // 第二次：补枪绝杀，防止守护进程在极速重启时加载了不完整的旧缓存
            // (系统级强杀，如果进程已死会自动忽略无副作用；如果依然存在或刚重启，直接二次爆破)
            Dynamic.FBSSystemService.sharedService().terminateApplication("com.apple.PosterBoard", forReason: Int64(1), andReport: false, withDescription: "Double Tap Kill PosterBoard")
            Dynamic.FBSSystemService.sharedService().terminateApplication("com.apple.wallpaperd", forReason: Int64(1), andReport: false, withDescription: "Double Tap Kill Wallpaperd")
            
            // 3. 发送全局广播，通知系统刷新结束
            let darwinCenter = CFNotificationCenterGetDarwinNotifyCenter()
            CFNotificationCenterPostNotification(darwinCenter, CFNotificationName("com.apple.wallpaper.changed" as CFString), nil, nil, true)
            CFNotificationCenterPostNotification(darwinCenter, CFNotificationName("com.apple.posterkit.descriptors.changed" as CFString), nil, nil, true)
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
    
    // 【白名单过滤：100% 隔离隐藏系统官方自带壁纸】
    func fetchAppliedWallpapers() {
        var list: [AppliedWallpaper] = []
        guard let containerPath = SymHandler.getAppContainerPath(for: "com.apple.PosterBoard") else { return }
        let extVer = SymHandler.getExtensionVersion()
        let extensionsPath = URL(fileURLWithPath: "\(containerPath)/Library/Application Support/PRBPosterExtensionDataStore/\(extVer)/Extensions")
        
        guard let extensions = try? FileManager.default.contentsOfDirectory(at: extensionsPath, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) else { return }
        
        let importedFolders = UserDefaults.standard.stringArray(forKey: "ImportedWallpaperFolders") ?? []
        
        for extFolder in extensions {
            let extName = extFolder.lastPathComponent
            let descriptorsPath = extFolder.appendingPathComponent("descriptors")
            guard let items = try? FileManager.default.contentsOfDirectory(at: descriptorsPath, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) else { continue }
            
            for item in items {
                let folderName = item.lastPathComponent
                if folderName == "__MACOSX" { continue }
                
                // 仅允许白名单内包含的自定壁纸展现
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
                            displayName = "自定壁纸 (\(idStr))"
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
    
    // 【删除操作流程】
    func deleteAppliedWallpaper(_ wallpaper: AppliedWallpaper) throws {
        // 1. 强杀系统守护进程断开 SQLite 锁
        Dynamic.FBSSystemService.sharedService().terminateApplication("com.apple.PosterBoard", forReason: Int64(1), andReport: false, withDescription: "Unlock SQLite")
        Dynamic.FBSSystemService.sharedService().terminateApplication("com.apple.wallpaperd", forReason: Int64(1), andReport: false, withDescription: "Unlock SQLite")
        
        // 2. 线程休眠 0.8 秒，确保 WAL 文件句柄彻底释放
        Thread.sleep(forTimeInterval: 0.8)
        
        // 3. 擦除物理文件，执行微创 DELETE 注入数据库
        try FileManager.default.removeItem(at: wallpaper.path)
        injectIntoDatabase(uuid: wallpaper.folderName, providerId: wallpaper.extensionType, isDelete: true)
        
        var importedFolders = UserDefaults.standard.stringArray(forKey: "ImportedWallpaperFolders") ?? []
        importedFolders.removeAll { $0 == wallpaper.folderName }
        UserDefaults.standard.set(importedFolders, forKey: "ImportedWallpaperFolders")
        
        // 4. 更新前端列表并执行双杀自愈刷新
        DispatchQueue.main.async {
            self.fetchAppliedWallpapers()
            self.refreshPosterBoardSystem()
        }
    }
    
    // 【写入操作流程】
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
                default: break
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
        
        // 1. 强杀系统守护进程断开 SQLite 锁
        Dynamic.FBSSystemService.sharedService().terminateApplication("com.apple.PosterBoard", forReason: Int64(1), andReport: false, withDescription: "Unlock SQLite")
        Dynamic.FBSSystemService.sharedService().terminateApplication("com.apple.wallpaperd", forReason: Int64(1), andReport: false, withDescription: "Unlock SQLite")
        
        // 2. 线程休眠 0.8 秒
        Thread.sleep(forTimeInterval: 0.8)
        
        var importedFolders = UserDefaults.standard.stringArray(forKey: "ImportedWallpaperFolders") ?? []
        
        // 3. 物理直写 + SQLite 三表联动强行注入
        for (ext, descriptorsList) in extList {
            let targetDir = URL(fileURLWithPath: "\(containerPath)/Library/Application Support/PRBPosterExtensionDataStore/\(extVer)/Extensions/\(ext)/descriptors")
            
            if !FileManager.default.fileExists(atPath: targetDir.path) {
                try? FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
            }
            
            for descriptors in descriptorsList {
                for descr in try FileManager.default.contentsOfDirectory(at: descriptors, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) {
                    if descr.lastPathComponent != "__MACOSX" {
                        try randomizeWallpaperId(url: descr)
                        
                        // 生成苹果原生标准的 UUID 大写字符串
                        let uniqueFolderUUID = UUID().uuidString.uppercased()
                        let destURL = targetDir.appendingPathComponent(uniqueFolderUUID)
                        
                        if FileManager.default.fileExists(atPath: destURL.path) {
                            try? FileManager.default.removeItem(at: destURL)
                        }
                        
                        // 写入物理文件
                        try FileManager.default.moveItem(at: descr, to: destURL)
                        
                        if !importedFolders.contains(uniqueFolderUUID) {
                            importedFolders.append(uniqueFolderUUID)
                        }
                        
                        // 微创注入 SQLite 三表核心逻辑
                        injectIntoDatabase(uuid: uniqueFolderUUID, providerId: ext, isDelete: false)
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
        
        // 4. 更新前端列表并执行双杀自愈刷新
        DispatchQueue.main.async {
            self.fetchAppliedWallpapers()
            self.refreshPosterBoardSystem()
        }
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
