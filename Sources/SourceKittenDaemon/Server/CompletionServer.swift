//
//  CompletionServer.swift
//  SourceKittenDaemon
//
//  Created by Benedikt Terhechte on 12/11/15.
//  Copyright © 2015 Benedikt Terhechte. All rights reserved.
//

import Foundation
import Vapor
import HTTP

/**
This runs a simple webserver that can be queried from Emacs to get completions
for a file.
*/
public class CompletionServer {

    let port: Int
    let completer: Completer
    
    var caches: [String: ResultType] = [:]
    var cacheKeys: [String] = []

    let droplet = try! Droplet.init(config: Config.init(arguments: ["vapor", "serve"], absoluteDirectory: nil), router: nil, server: nil)
    
    public init(project: Project, port: Int) {
        self.completer = Completer(project: project)
        self.port = port

        droplet.get("/ping") { request in
            return "OK"
        }

        droplet.get("/project") { request in
            return self.completer.project.projectFile.path
        }

        droplet.get("/files") { request in
            let files = self.completer.sourceFiles()
            guard let jsonFiles = try? JSONSerialization.data(
                    withJSONObject: files,
                    options: JSONSerialization.WritingOptions.prettyPrinted
                  ),
                  let filesString = String(data: jsonFiles, encoding: String.Encoding.utf8) else {
                throw Abort.custom(
                  status: .badRequest,
                  message: "{\"error\": \"Could not generate file list\"}"
                )
            }
            return filesString
        }

        droplet.get("/complete") { request in
            guard let offsetString = request.headers["X-Offset"],
                  let offset = Int(offsetString) else {
                throw Abort.custom(
                  status: .badRequest,
                  message: "{\"error\": \"Need X-Offset\"}"
                )
            }

            guard let path = request.headers["X-Path"] else {
                throw Abort.custom(
                  status: .badRequest,
                  message: "{\"error\": \"Need X-Path\"}"
                )
            }
            
            guard let _cacheKey = request.headers["X-Cachekey"] else {
                throw Abort.custom(
                    status: .badRequest,
                    message: "{\"error\": \"Need X-Cachekey\"}"
                )
            }
            
            guard let prefixString = request.headers["X-Prefix"] else {
                throw Abort.custom(
                    status: .badRequest,
                    message: "{\"error\": \"Need X-Prefix\"}"
                )
            }
            
            guard let type = request.headers["X-Type"], let typeInt = Int(type) else {
                throw Abort.custom(
                    status: .badRequest,
                    message: "{\"error\": \"Need X-Type\"}"
                )
            }
            
            print("[HTTP] GET /complete \(request.headers)")
            
            let completeType = CompleteType(rawValue: typeInt) ?? .ThisClass
            let cacheKey = offsetString + path + _cacheKey
            if let cache = self.caches[cacheKey] {
                print("target caches \(cacheKey)")
                return cache.filter(withType: completeType, prefixString: prefixString).asJSONString()
            }

            let url = URL(fileURLWithPath: path)
            let result = self.completer.complete(url, offset: offset)
            switch result {
            case .success(result: let result):
                let filtered = result.filter(withType: completeType, prefixString: prefixString)
                if filtered.count > 0 {
                    self.caches[cacheKey] = result
                    self.cacheKeys.append(cacheKey)
                    if self.cacheKeys.count > 5 {
                        let key = self.cacheKeys.removeFirst()
                        self.caches.removeValue(forKey: key)
                    }
                    return filtered.asJSONString()
                } else {
                    throw Abort.custom(
                        status: .badRequest,
                        message: "{\"error\": empty\"}"
                    )
                }
            case .failure(message: let msg):
                throw Abort.custom(
                  status: .badRequest,
                  message: "{\"error\": \"\(msg)\"}"
                )
            }
        }
    }

    public func start() {
        do {
            try droplet.run()
        } catch {
            
        }
    }
}

extension Abort {
    static func custom(status: Status, message: String) -> Abort {
        return Abort.init(.badRequest, metadata: nil, reason: message)
    }
}

typealias ResultType = [Array<String>]
enum CompleteType : Int {
    case ThisClass = 0
    case SuperClass = 1
}

extension Array where Element == Array<String> {
    func filter(withType type: CompleteType, prefixString:String = "") -> ResultType {
        var filtered:ResultType = []
        if prefixString != "" {
            for item in self {
                if let sourceText = item.first,
                    sourceText.hasPrefix(prefixString) {
                    filtered.append(item)
                    continue
                }
            }
        } else
        if type == .ThisClass {
            for item in self {
                if !item[1].hasSuffix("sp") {
                    filtered.append(item)
                }
            }
        } else
        if type == .SuperClass {
            for (index, item) in self.reversed().enumerated() {
                if item[1].hasSuffix("sp") {
                    filtered.append(item)
                    if index > 100 { //   if need too much?
                        break
                    }
                }
            }
        }

        print("filter item count \(filtered.count)")
        return filtered
    }
    
    func asJSONString() -> String {  // format for vim
        let itemsString = self.map { (item) -> String in
            return "{'word':'\(item[0])', 'abbr':'\(item[1])'},"
        }.joined()
        return "[\(itemsString)]"
    }
}
