//
//  Copyright © 2017 Jan Gorman. All rights reserved.
//

import UIKit

public enum MapleBaconCacheError: Error {
  case imageNotFound
}

public enum CacheType {
  case none, memory, disk
}

/// The class responsible for caching images. Images will be cached both in memory and on disk.
public final class MapleBaconCache {
  
  private static let prefix = "com.schnaub.Cache."

  /// The default `Cache` singleton
  public static let `default` = MapleBaconCache(name: "default")

  public let cachePath: String
  
  private let memory = NSCache<NSString, DataWrapper>()
  private let backingStore: BackingStore
  private let diskQueue: DispatchQueue

  /// The max age to cache images on disk in seconds. Defaults to 7 days.
  public var maxCacheAgeSeconds: TimeInterval = 60 * 60 * 24 * 7

  /// Construct a new instance of the cache
  ///
  /// - Parameter name: The name of the cache. Used to construct a unique path on disk to store images in
  public init(name: String, backingStore: BackingStore = FileManager.default) {
    let cacheName = MapleBaconCache.prefix + name
    memory.name = cacheName

    self.backingStore = backingStore
    
    diskQueue = DispatchQueue(label: cacheName, qos: .background)
    
    let path = NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true).first!
    cachePath = (path as NSString).appendingPathComponent(name)

    NotificationCenter.default.addObserver(self, selector: #selector(cleanDisk), name: UIApplication.willTerminateNotification,
                                           object: nil)
  }

  /// Stores an image in the cache. Images will be added to both memory and disk.
  ///
  /// - Parameters
  ///     - data: The image data to cache
  ///     - key: The unique identifier of the image
  ///     - transformerId: An optional transformer ID appended to the key to uniquely identify the image
  ///     - completion: An optional closure called once the image has been persisted to disk. Runs on the main queue.
  public func store(data: Data? = nil, forKey key: String, transformerId: String? = nil,
                    completion: (() -> Void)? = nil) {
    let cacheKey = storeToMemory(data: data, forKey: key, transformerId: transformerId)
    diskQueue.async {
      defer {
        DispatchQueue.main.async {
          completion?()
        }
      }
      if let data = data {
        self.storeDataToDisk(data, key: cacheKey)
      }
    }
  }

  @discardableResult
  private func storeToMemory(data: Data?, forKey key: String, transformerId: String?) -> String {
    let cacheKey = makeCacheKey(key, identifier: transformerId)
    if let data = data {
      memory.setObject(DataWrapper(data: data), forKey: cacheKey as NSString)
    } else {
      memory.removeObject(forKey: cacheKey as NSString)
    }
    return cacheKey
  }

  private func makeCacheKey(_ key: String, identifier: String?) -> String {
    let fileSafeKey = key.replacingOccurrences(of: "/", with: "-")
    guard let identifier = identifier, !identifier.isEmpty else {
      return fileSafeKey
    }
    return fileSafeKey + "-" + identifier
  }
  
  private func storeDataToDisk(_ data: Data, key: String) {
    createCacheDirectoryIfNeeded()
    let path = (cachePath as NSString).appendingPathComponent(key)
    backingStore.createFile(atPath: path, contents: data, attributes: nil)
  }
  
  private func createCacheDirectoryIfNeeded() {
    guard !backingStore.fileExists(atPath: cachePath) else {
      return
    }
    try? backingStore.createDirectory(atPath: cachePath, withIntermediateDirectories: true, attributes: nil)
  }

  /// Retrieve an image from cache. Will look in both memory and on disk. When the image is only available on disk
  /// it will be stored again in memory for faster access.
  ///
  /// - Parameters
  ///     - key: The unique identifier of the image
  ///     - transformerId: An optional transformer ID appended to the key to uniquely identify the image
  ///     - completion: The completion called once the image has been retrieved from the cache
  public func retrieveImage(forKey key: String, transformerId: String? = nil, completion: (UIImage?, CacheType) -> Void) {
    retrieveData(forKey: key, transformerId: transformerId) { data, cacheType in
      guard let data = data else {
        completion(nil, cacheType)
        return
      }
      completion(UIImage(data: data), cacheType)
    }
  }

  /// Retrieve raw `Data` from cache. Will look in both memory and on disk. When the data is only available on disk
  /// it will be stored again in memory for faster access.
  ///
  /// - Parameters
  ///     - key: The unique identifier of the data
  ///     - transformerId: An optional transformer ID appended to the key to uniquely identify the data
  ///     - completion: The completion called once the image has been retrieved from the cache
  public func retrieveData(forKey key: String, transformerId: String? = nil, completion: (Data?, CacheType) -> Void) {
    let cacheKey = makeCacheKey(key, identifier: transformerId)
    if let dataWrapper = memory.object(forKey: cacheKey as NSString) {
      completion(dataWrapper.data, .memory)
      return
    }
    if let data = retrieveDataFromDisk(forKey: cacheKey), !data.isEmpty {
      storeToMemory(data: data, forKey: key, transformerId: transformerId)
      completion(data, .disk)
      return
    }
    completion(nil, .none)
  }

  private func retrieveDataFromDisk(forKey key: String) -> Data? {
    let url = URL(fileURLWithPath: cachePath).appendingPathComponent(key)
    return try? backingStore.fileContents(at: url)
  }

  public func clearMemory() {
    memory.removeAllObjects()
  }

  /// Clear the disk cache.
  ///
  /// - Parameter completion: An optional closure called once the cache has been cleared. Runs on the main queue.
  public func clearDisk(_ completion: (() -> Void)? = nil) {
    diskQueue.async {
      defer {
        DispatchQueue.main.async {
          completion?()
        }
      }

      try? self.backingStore.removeItem(atPath: self.cachePath)
      self.createCacheDirectoryIfNeeded()
    }
  }

  @objc
  private func cleanDisk() {
    diskQueue.async {
      for url in self.expiredFileUrls() {
        _ = try? self.backingStore.removeItem(at: url)
      }
    }
  }

  public func expiredFileUrls() -> [URL] {
    let cacheDirectory = URL(fileURLWithPath: cachePath)
    let keys: Set<URLResourceKey> = [.isDirectoryKey, .contentAccessDateKey]
    let contents = try? backingStore.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: Array(keys),
                                                         options: .skipsHiddenFiles)
    guard let files = contents else {
      return []
    }

    let expirationDate = Date(timeIntervalSinceNow: -maxCacheAgeSeconds)
    let expiredFileUrls = files.filter { url in
      let resource = try? url.resourceValues(forKeys: keys)
      let isDirectory = resource?.isDirectory
      guard let lastAccessDate = resource?.contentAccessDate else { return true }
      return isDirectory == false && lastAccessDate < expirationDate
    }
    return expiredFileUrls
  }

}

private final class DataWrapper {

  let data: Data

  init(data: Data) {
    self.data = data
  }

}
