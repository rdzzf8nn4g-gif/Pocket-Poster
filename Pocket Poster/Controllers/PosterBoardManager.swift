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
import Darwin // 【核心引入】用于底层 BSD UNIX 进程操作 (sysctl / kill)

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
    
    // 按顺序单线程安全写入数据库
    private func injectIntoDatabase(uuid: String, providerId: String, isDelete: Bool) {
        guard let dbPath = findDatabasePath() else { return }
        
        var db: OpaquePointer?
        if sqlite3_open(dbPath, &db) == SQLITE_OK {
            // 设置 2000ms 的超时等待，防止偶尔的库锁定
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
    
    // 【底层系统级暴击：根据进程名查找 PID 并发送 SIGKILL】
    private func forceKillProcessByName(_ targetName: String) {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size: Int = 0
        sysctl(&mib, 4, nil, &size, nil, 0)
        
        let count = size / MemoryLayout<kinfo_proc>.stride
        var processList = Array<kinfo_proc>(repeating: kinfo_proc(), count: count)
        
        if sysctl(&mib, 4, &processList, &size, nil, 0) == 0 {
            for i in 0..<count {
                let proc = processList[i]
                let pid = proc.kp_proc.p_pid
                let commTuple = proc.kp_proc.p_comm
                
                let procName = withUnsafeBytes(of: commTuple) { rawPtr -> String in
                    let ptr = rawPtr.baseAddress!.assumingMemoryBound(to: CChar.self)
                    return String(cString: ptr)
                }
                
                if procName == targetName {
                    kill(pid, SIGKILL) 
                }
            }
        }
    }
    
    // 【三守护进程联合击杀名单】
    private func killDaemons() {
        forceKillProcessByName("PosterBoard")
        forceKillProcessByName("wallpaperd")
        forceKillProcessByName("CollectionsPoster") // 你的新要求
    }
    
    // 【高频轮询绝对压制，漏头就秒】
    private func enforceSuppression(for seconds: TimeInterval) {
        print("🛡️ 开始执行 \(seconds) 秒的绝对压制，漏头就秒...")
        let endTime = Date().addingTimeInterval(seconds)
        
        // 循环持续到时间结束，每 0.1 秒进行一次全盘扫荡
        while Date() < endTime {
            killDaemons()
            Thread.sleep(forTimeInterval: 0.1) 
        }
        print("🛡️ 压制期结束。")
    }
    
    private func broadcastDarwinNotifications() {
        let darwinCenter = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(darwinCenter, CFNotificationName("com.apple.wallpaper.changed" as CFString), nil, nil, true)
        CFNotificationCenterPostNotification(darwinCenter, CFNotificationName("com.apple.posterkit.descriptors.changed" as CFString), nil, nil, true)
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
                    var foundName = false
                    
                    // 【关键修复】：深度遍历文件夹，寻找隐藏在内部的 Wallpaper.plist
                    if let enumerator = FileManager.default.enumerator(at: item, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                        for case let fileURL as URL in enumerator {
                            if fileURL.lastPathComponent == "Wallpaper.plist" {
                                if let data = try? Data(contentsOf: fileURL),
                                   let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
                                   let name = plist["name"] as? String {
                                    displayName = name
                                    foundName = true
                                    break
                                }
                            }
                        }
                    }
                    
                    // 如果找不到 Wallpaper.plist 里的 name，退而求其次读取 ID
                    if !foundName {
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
    
    // ============================================
    // 全部删除流程 (删数据 -> 3秒绝对压制)
    // ============================================
    func deleteAllAppliedWallpapers() throws {
        killDaemons()
        Thread.sleep(forTimeInterval: 0.5)
        
        for wallpaper in appliedWallpapers {
            try? FileManager.default.removeItem(at: wallpaper.path)
            injectIntoDatabase(uuid: wallpaper.folderName, providerId: wallpaper.extensionType, isDelete: true)
        }
        
        UserDefaults.standard.set([], forKey: "ImportedWallpaperFolders")
        
        enforceSuppression(for: 3.0)
        broadcastDarwinNotifications()
        
        DispatchQueue.main.async {
            self.fetchAppliedWallpapers()
        }
    }
    
    // ============================================
    // 单个删除流程 (删数据 -> 3秒绝对压制)
    // ============================================
    func deleteAppliedWallpaper(_ wallpaper: AppliedWallpaper) throws {
        killDaemons()
        Thread.sleep(forTimeInterval: 0.5) 
        
        try FileManager.default.removeItem(at: wallpaper.path)
        injectIntoDatabase(uuid: wallpaper.folderName, providerId: wallpaper.extensionType, isDelete: true)
        
        var importedFolders = UserDefaults.standard.stringArray(forKey: "ImportedWallpaperFolders") ?? []
        importedFolders.removeAll { $0 == wallpaper.folderName }
        UserDefaults.standard.set(importedFolders, forKey: "ImportedWallpaperFolders")
        
        enforceSuppression(for: 3.0)
        broadcastDarwinNotifications()
        
        DispatchQueue.main.async {
            self.fetchAppliedWallpapers()
        }
    }
    
    // ============================================
    // 应用流程 (顺序写入多壁纸 -> 6秒绝对压制 -> 无跳转)
    // ============================================
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
        
        killDaemons()
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
        
        // 3. 所有壁纸数据完美写入后，开启 6 秒“漏头就秒”绝对压制期
        enforceSuppression(for: 6.0)
        
        // 4. 彻底压制完毕后，释放系统广播通知
        broadcastDarwinNotifications()
        
        // 5. 【取消跳转】，仅静默刷新内部列表
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
