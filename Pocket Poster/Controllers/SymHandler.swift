//
//  SymHandler.swift
//  Pocket Poster
//
//  Created by lemin on 5/31/25.
//

import Foundation

class SymHandler {
    // MARK: URL Getter Operations
    static func getDocumentsDirectory() -> URL {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        let documentsDirectory = paths[0]
        return documentsDirectory
    }
    
    static func getLCDocumentsDirectory() -> URL {
        let lcPath = ProcessInfo.processInfo.environment["LC_HOME_PATH"]
        if let lcPath = lcPath {
            return URL(fileURLWithPath: "\(lcPath)/Documents")
        }
        return getDocumentsDirectory()
    }
    
    // 【修改点】移除旧的写死 Hash URL 的方法，不再需要 getPosterBoardHashURL 和 getCarPlayHashURL
    
    private static func getSymlinkURL() -> URL {
        return getLCDocumentsDirectory().appendingPathComponent(".Trash", conformingTo: .symbolicLink)
    }
    
    // MARK: - 核心：利用私有 API 动态获取 App 的 Data Container 路径
    static func getAppContainerPath(for bundleID: String) -> String? {
        guard let proxyClass = objc_getClass("LSApplicationProxy") as? NSObject.Type else { return nil }
        guard let proxy = proxyClass.perform(Selector(("applicationProxyForIdentifier:")), with: bundleID)?.takeUnretainedValue() as? NSObject else { return nil }
        guard let dataContainerURL = proxy.perform(Selector(("dataContainerURL")))?.takeUnretainedValue() as? URL else { return nil }
        return dataContainerURL.path
    }
    
    // MARK: Symlink Creation
    static func createSymlink(to path: String) throws -> URL {
        // returns the url of the symlink
        let symURL = getSymlinkURL()
        cleanup()
        
        // create the symlink to the dynamic app folder
        try FileManager.default.createSymbolicLink(at: symURL, withDestinationURL: URL(fileURLWithPath: path, isDirectory: true))
        
        return symURL
    }
    
    // 【修改点】将原来接受 appHash 的方法，改为接受 bundleID 和 subPath
    static func createAppSymlink(for bundleID: String, subPath: String) throws -> URL {
        guard let containerPath = getAppContainerPath(for: bundleID) else {
            throw NSError(domain: "SymHandler", code: -1, userInfo: [NSLocalizedDescriptionKey: "无法获取 \(bundleID) 的沙盒路径，请确保已通过 TrollStore 安装以获取足够权限。"])
        }
        let fullPath = containerPath + subPath
        return try createSymlink(to: fullPath)
    }
    
    static func getExtensionVersion() -> String {
        if #available(iOS 17.0, *) {
            return "61"
        }
        return "59"
    }
    
    // 【修改点】将传入的 appHash 改为 bundleID
    static func createDescriptorsSymlink(bundleID: String, ext: String) throws -> URL {
        let extVer = SymHandler.getExtensionVersion()
        let subPath = "/Library/Application Support/PRBPosterExtensionDataStore/\(extVer)/Extensions/\(ext)/descriptors"
        print("linking to \(bundleID) -> \(subPath)")
        return try createAppSymlink(for: bundleID, subPath: subPath)
    }
    
    static func cleanup() {
        // remove the symlink if it exists
        let symURL = getSymlinkURL()
        // remove existing symlink
        try? FileManager.default.removeItem(at: symURL)
    }
}
