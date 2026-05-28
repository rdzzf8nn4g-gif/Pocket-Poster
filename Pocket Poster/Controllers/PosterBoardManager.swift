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
import SQLite3
import Darwin // 【核心引入】：用于执行底层的 dlopen 和 posix_spawn 强制爆破命令

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
    
    private func injectIntoDatabase(uuid: String, providerId: String, isDelete: Bool) {
        guard let dbPath = findDatabasePath() else { return }
        
        var db: OpaquePointer?
        if sqlite3_open(dbPath, &db) == SQLITE_OK {
            sqlite3_exec(db, "PRAGMA busy_timeout = 2000;", nil, nil, nil)
            var stmt: OpaquePointer?
            
            if isDelete {
                let deleteQuery = "DELETE FROM poster WHERE UUID = ?;"
                if sqlite3_prepare_v2(db, deleteQuery, -1, &stmt, nil) == SQLITE_OK {
                    sqlite3_bind_text(stmt, 1, (uuid as NSString).utf8String, -1, nil)
                    sqlite3_step(stmt)
                }
                sqlite3_finalize(stmt)
            } else {
                let insertPoster = "INSERT OR IGNORE INTO poster (UUID, providerId) VALUES (?, ?);"
                if sqlite3_prepare_v2(db, insertPoster, -1, &stmt, nil) == SQLITE_OK {
                    sqlite3_bind_text(stmt, 1, (uuid as NSString).utf8String, -1, nil)
                    sqlite3_bind_text(stmt, 2, (providerId as NSString).utf8String, -1, nil)
                    sqlite3_step(stmt)
                }
                sqlite3_finalize(stmt)
                
                let insertRole = "INSERT OR IGNORE INTO posterRoleMembership (posterUUID, roleId, roleSortKey) VALUES (?, 'PRPosterRoleLockScreen', 0);"
                if sqlite3_prepare_v2(db, insertRole, -1, &stmt, nil) == SQLITE_OK {
                    sqlite3_bind_text(stmt, 1, (uuid as NSString).utf8String, -1, nil)
                    sqlite3_step(stmt)
                }
                sqlite3_finalize(stmt)
                
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
    
    // 【终极武器：巨魔底层 POSIX 爆破，无视任何系统锁死】
    private func forceKillProcess(_ name: String) {
        var pid: pid_t = 0
        let args = ["/usr/bin/killall", "-9", name]
        var cArgs = args.map { strdup($0) }
        cArgs.append(nil)
        
        posix_spawn(&pid, "/usr/bin/killall", nil, nil, &cArgs, nil)
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        
        for ptr in cArgs {
            if let ptr = ptr { free(ptr) }
        }
    }
    
    // 【系统级双保险击杀协议】
    private func killDaemons(reason: String) {
        // 1. Apple 官方私有框架强杀（必须先 dlopen 加载到内存，否则直接静默失败）
        let handle = dlopen("/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices", RTLD_LAZY)
        if handle != nil {
            let service = Dynamic.FBSSystemService.sharedService()
            service.terminateApplication("com.apple.PosterBoard", forReason: Int64(1), andReport: false, withDescription: reason)
            service.terminateApplication("com.apple.wallpaperd", forReason: Int64(1), andReport: false, withDescription: reason)
            dlclose(handle)
        }
        
        // 2. 巨魔专属 C 语言底层爆破（作为双保险，无论如何进程必死）
        forceKillProcess("PosterBoard")
        forceKillProcess("wallpaperd")
    }
    
    private func broadcastDarwinNotifications() {
        let darwinCenter = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(darwinCenter, CFNotificationName("com.apple.wallpaper.changed" as CFString), nil, nil, true)
        CFNotificationCenterPostNotification(darwinCenter, CFNotificationName("com.apple.posterkit.descriptors.changed" as CFString), nil, nil, true)
    }
    
    func openPosterBoard() -> Bool {
        guard let obj = objc_getClass("LSApplicationWorkspace") as? NSObject else { return false }
        let workspace = obj.perform(Selector(("defaultWorkspace")))?.takeUnretainedValue() as? NSObject
        let success = workspace?.perform(Selector(("openApplicationWithBundleID:")), with: "com.apple.PosterBoard")
        return success != nil
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
    
    // 【全新架构：删除流水线】
    // 流程：点击直接前置首杀 -> 清数据 -> 挂起6秒 -> 后置补杀
    func deleteAppliedWallpaper(_ wallpaper: AppliedWallpaper) throws {
        // 1. 点击立刻清场释放 SQLite 写锁
        killDaemons(reason: "Pre-Delete Kill")
        Thread.sleep(forTimeInterval: 0.5)
        
        // 2. 擦除物理文件并清理数据库
        try FileManager.default.removeItem(at: wallpaper.path)
        injectIntoDatabase(uuid: wallpaper.folderName, providerId: wallpaper.extensionType, isDelete: true)
        
        var importedFolders = UserDefaults.standard.stringArray(forKey: "ImportedWallpaperFolders") ?? []
        importedFolders.removeAll { $0 == wallpaper.folderName }
        UserDefaults.standard.set(importedFolders, forKey: "ImportedWallpaperFolders")
        
        // 3. 阻塞等待 6 秒（前端的弹窗将遮罩在此期间）
        Thread.sleep(forTimeInterval: 6.0)
        
        // 4. 6 秒后执行最后一次清扫，确保自愈完毕
        killDaemons(reason: "Post-Delete 6s Safety Kill")
        broadcastDarwinNotifications()
        
        DispatchQueue.main.async {
            self.fetchAppliedWallpapers()
        }
    }
    
    // 【全新架构：应用流水线】
    // 流程：前置首杀 -> 写入数据 -> 后置二杀 -> 挂起5秒 -> 补枪三杀
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
        
        for url in selectedTendies {
            let unzippedDir = try unzipFile(at: url)
            guard let descriptors = try getDescriptorsFromTendie(unzippedDir) else { continue }
            extList.merge(descriptors) { (first, second) in first + second }
        }
        
        guard let containerPath = SymHandler.getAppContainerPath(for: "com.apple.PosterBoard") else {
            throw NSError(domain: "PosterBoardManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "无法定位 PosterBoard 路径"])
        }
        let extVer = SymHandler.getExtensionVersion()
        
        // 1. 设置前杀一次：剥夺数据库独占权
        killDaemons(reason: "Pre-Apply Kill")
        Thread.sleep(forTimeInterval: 0.5)
        
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
                        
                        let uniqueFolderUUID = UUID().uuidString.uppercased()
                        let destURL = targetDir.appendingPathComponent(uniqueFolderUUID)
                        
                        if FileManager.default.fileExists(atPath: destURL.path) {
                            try? FileManager.default.removeItem(at: destURL)
                        }
                        
                        try FileManager.default.moveItem(at: descr, to: destURL)
                        
                        if !importedFolders.contains(uniqueFolderUUID) {
                            importedFolders.append(uniqueFolderUUID)
                        }
                        
                        // 强制微创注入 SQLite
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
        
        // 2. 写入成功后杀二次：迫使守护进程以包含新数据的状态冷启动
        killDaemons(reason: "Post-Apply Kill")
        
        // 3. 进入强行阻滞期：等待 5 秒
        Thread.sleep(forTimeInterval: 5.0)
        
        // 4. 等待 5 秒后，进行第三次安全校验击杀（无痕补刀）
        killDaemons(reason: "Safety 5s Final Kill")
        broadcastDarwinNotifications()
        
        DispatchQueue.main.async {
            self.fetchAppliedWallpapers()
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
