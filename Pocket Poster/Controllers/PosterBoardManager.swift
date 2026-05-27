//
//  PosterBoardManager.swift
//  Pocket Poster
//
//  Created by lemin on 5/31/25.
//

import Foundation
import ZIPFoundation
import UIKit
import Dynamic // 使用项目内置的 Dynamic 框架安全调用系统私有级 API

// 已应用壁纸的数据模型
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
    @Published var appliedWallpapers: [AppliedWallpaper] = [] // 存储精确过滤后的自定壁纸
    
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
        let workspace = Dynamic.LSApplicationWorkspace.defaultWorkspace()
        if workspace != nil {
            return workspace.openApplicationWithBundleID("com.apple.PosterBoard")
        }
        return false
    }
    
    // 【核心修复：防闪退与自动化刷新】
    func refreshPosterBoardSystem() {
        DispatchQueue.global(qos: .userInitiated).async {
            let service = Dynamic.FBSSystemService.sharedService()
            if service != nil {
                // 将 forReason 显式指定为 Int64(1)，完美匹配 Objective-C 的 long long 类型，彻底解决闪退崩溃问题
                service.terminateApplication("com.apple.PosterBoard", forReason: Int64(1), andDescription: "Refresh Cache", withOptions: nil)
            }
            
            // 自动化调用巨魔级别的容器缓存刷新指令
            let workspace = Dynamic.LSApplicationWorkspace.defaultWorkspace()
            if workspace != nil {
                workspace.pluginsNeedToBeRefreshed()
            }
            
            // 延时重新唤醒进程，给系统重构壁纸数据库预留时间
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                _ = self.openPosterBoard()
            }
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
    
    // 【核心修改：双重精准过滤系统自带壁纸】
    func fetchAppliedWallpapers() {
        var list: [AppliedWallpaper] = []
        guard let containerPath = SymHandler.getAppContainerPath(for: "com.apple.PosterBoard") else { return }
        let extVer = SymHandler.getExtensionVersion()
        let extensionsPath = URL(fileURLWithPath: "\(containerPath)/Library/Application Support/PRBPosterExtensionDataStore/\(extVer)/Extensions")
        
        guard let extensions = try? FileManager.default.contentsOfDirectory(at: extensionsPath, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) else { return }
        
        // 读取本 App 录入的自定历史追踪阵列
        let importedFolders = UserDefaults.standard.stringArray(forKey: "ImportedWallpaperFolders") ?? []
        
        for extFolder in extensions {
            let extName = extFolder.lastPathComponent
            let descriptorsPath = extFolder.appendingPathComponent("descriptors")
            guard let items = try? FileManager.default.contentsOfDirectory(at: descriptorsPath, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) else { continue }
            
            for item in items {
                let folderName = item.lastPathComponent
                if folderName == "__MACOSX" { continue }
                
                let lowerFolder = folderName.lowercased()
                // 过滤掉系统自带、固件迁移或核心原生组件的类目
                if lowerFolder.contains("system") || lowerFolder.hasPrefix("migration") || lowerFolder.contains("apple") || folderName.count < 5 {
                    continue
                }
                
                var displayName = folderName
                var isSystemStock = false
                
                let plistURL = item.appendingPathComponent("Wallpaper.plist")
                if FileManager.default.fileExists(atPath: plistURL.path) {
                    if let data = try? Data(contentsOf: plistURL),
                       let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] {
                        if let name = plist["name"] as? String {
                            displayName = name
                            // 屏蔽系统原装的默认壁纸分类名
                            if name == "Collections" || name == "Astronomy" || name == "Emoji" || name == "Kaleidoscope" || name == "Color" {
                                isSystemStock = true
                            }
                        }
                    }
                } else {
                    let idURL = item.appendingPathComponent("com.apple.posterkit.provider.descriptor.identifier")
                    if let idStr = try? String(contentsOf: idURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) {
                        displayName = "自定壁纸 (ID: \(idStr))"
                    }
                }
                
                if isSystemStock { continue }
                
                // 只有在追踪列表里，或者文件夹不包含系统特征的才会被认作是导入的自定壁纸
                if importedFolders.contains(folderName) || !lowerFolder.hasPrefix("com.apple") {
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
        
        // 同步从持久化追踪列表中移除该项
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
                        
                        let destURL = targetDir.appendingPathComponent(descr.lastPathComponent)
                        if FileManager.default.fileExists(atPath: destURL.path) {
                            try? FileManager.default.removeItem(at: destURL)
                        }
                        
                        try FileManager.default.moveItem(at: descr, to: destURL)
                        
                        // 将新导入成功的自定文件夹特征登记到追踪列表中
                        if !importedFolders.contains(descr.lastPathComponent) {
                            importedFolders.append(descr.lastPathComponent)
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
