/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2020 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
 */

import Basics
import Dispatch
import struct Foundation.Data
import class Foundation.JSONDecoder
import class Foundation.JSONEncoder
import struct Foundation.URL
import TSCBasic

struct FilePackageCollectionsSourcesStorage: PackageCollectionsSourcesStorage {
    let fileSystem: FileSystem
    let path: AbsolutePath

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private let queue = DispatchQueue(label: "org.swift.swiftpm.FilePackageCollectionsSourcesStorage")

    init(fileSystem: FileSystem = localFileSystem, path: AbsolutePath? = nil) {
        self.fileSystem = fileSystem

        let name = "collections"
        self.path = path ?? fileSystem.dotSwiftPM.appending(components: "config", "\(name).json")

        self.encoder = JSONEncoder()
        if #available(macOS 10.15, *) {
            #if os(macOS)
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
            #else // `.withoutEscapingSlashes` is not in 5.3 on non-Darwin platforms
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            #endif
        }
        self.decoder = JSONDecoder()
    }

    func list(callback: @escaping (Result<[Model.CollectionSource], Error>) -> Void) {
        self.queue.async {
            do {
                let sources = try self.withLock {
                    try self.loadFromDisk()
                }
                callback(.success(sources))
            } catch {
                callback(.failure(error))
            }
        }
    }

    func add(source: Model.CollectionSource,
             order: Int?,
             callback: @escaping (Result<Void, Error>) -> Void) {
        self.queue.async {
            do {
                try self.withLock {
                    var sources = try self.loadFromDisk()
                    sources = sources.filter { $0 != source }
                    let order = order.flatMap { $0 >= 0 && $0 < sources.endIndex ? order : sources.endIndex } ?? sources.endIndex
                    sources.insert(source, at: order)
                    try self.saveToDisk(sources)
                }
                callback(.success(()))
            } catch {
                callback(.failure(error))
            }
        }
    }

    func remove(source: Model.CollectionSource,
                callback: @escaping (Result<Void, Error>) -> Void) {
        self.queue.async {
            do {
                try self.withLock {
                    var sources = try self.loadFromDisk()
                    sources = sources.filter { $0 != source }
                    try self.saveToDisk(sources)
                }
                callback(.success(()))
            } catch {
                callback(.failure(error))
            }
        }
    }

    func move(source: Model.CollectionSource,
              to order: Int,
              callback: @escaping (Result<Void, Error>) -> Void) {
        self.queue.async {
            do {
                try self.withLock {
                    var sources = try self.loadFromDisk()
                    sources = sources.filter { $0 != source }
                    let order = order >= 0 && order < sources.endIndex ? order : sources.endIndex
                    sources.insert(source, at: order)
                    try self.saveToDisk(sources)
                }
                callback(.success(()))
            } catch {
                callback(.failure(error))
            }
        }
    }

    func exists(source: Model.CollectionSource,
                callback: @escaping (Result<Bool, Error>) -> Void) {
        self.queue.async {
            do {
                let sources = try self.withLock {
                    try self.loadFromDisk()
                }
                callback(.success(sources.contains(source)))
            } catch {
                callback(.failure(error))
            }
        }
    }

    private func loadFromDisk() throws -> [Model.CollectionSource] {
        guard self.fileSystem.exists(self.path) else {
            return .init()
        }
        let buffer = try fileSystem.readFileContents(self.path).contents
        guard buffer.count > 0 else {
            return .init()
        }
        let container = try decoder.decode(StorageModel.Container.self, from: Data(buffer))
        return try container.sources()
    }

    private func saveToDisk(_ sources: [Model.CollectionSource]) throws {
        if !self.fileSystem.exists(self.path.parentDirectory) {
            try self.fileSystem.createDirectory(self.path.parentDirectory, recursive: true)
        }
        let container = StorageModel.Container(sources)
        let buffer = try encoder.encode(container)
        try self.fileSystem.writeFileContents(self.path, bytes: ByteString(buffer))
    }

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        if !fileSystem.exists(self.path.parentDirectory) {
            try self.fileSystem.createDirectory(self.path.parentDirectory, recursive: true)
        }
        return try self.fileSystem.withLock(on: self.path.parentDirectory, type: .exclusive, body)
    }
}

// MARK: - FilePackageCollectionsSourcesStorage Serialization

private enum StorageModel {
    struct Container: Codable {
        var data: [Source]

        init() {
            self.data = .init()
        }

        init(_ from: [Model.CollectionSource]) {
            self.data = from.map { $0.source() }
        }

        func sources() throws -> [Model.CollectionSource] {
            return try self.data.map { try Model.CollectionSource($0) }
        }
    }

    struct Source: Codable {
        let type: String
        let value: String
    }

    enum SourceType: String {
        case json
    }
}

// MARK: - Utility

private extension Model.CollectionSource {
    init(_ from: StorageModel.Source) throws {
        guard let url = URL(string: from.value) else {
            throw SerializationError.invalidURL(from.value)
        }
        self.url = url
        switch from.type {
        case StorageModel.SourceType.json.rawValue:
            self.type = .json
        default:
            throw SerializationError.unknownType(from.type)
        }
    }

    func source() -> StorageModel.Source {
        switch self.type {
        case .json:
            return .init(type: StorageModel.SourceType.json.rawValue, value: self.url.absoluteString)
        }
    }
}

private enum SerializationError: Error {
    case unknownType(String)
    case invalidURL(String)
}
