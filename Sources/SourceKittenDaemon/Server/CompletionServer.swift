//
//  CompletionServer.swift
//  SourceKittenDaemon
//
//  Created by Benedikt Terhechte on 12/11/15.
//  Copyright © 2015 Benedikt Terhechte. All rights reserved.
//

import Foundation
import Embassy
import SourceKittenFramework
import libfuzzyMatch

enum Abort: Error {
    case custom(status: Int, message: String)
}

/**
This runs a simple webserver that can be queried from Emacs to get completions
for a file.
*/
public class CompletionServer {

    let completer: Completer
    let loop: SelectorEventLoop
    
    var server: DefaultHTTPServer?
    
    // custom
    var caches: [String: [CodeCompletionItem]] = [:]
    var cacheKeys: [String] = []
    
    public init(project: Project, port: Int) throws {
        let selector = try SelectSelector()
        self.loop = try SelectorEventLoop(selector: selector)
        self.completer = Completer(project: project)
        self.server = DefaultHTTPServer(eventLoop: loop, port: port, app: requestHandler)
    }

    public func start() throws {
        try server?.start()
        // Run event loop
        loop.runForever()
    }

    private func requestHandler(environ: [String: Any], startResponse: ((String, [(String, String)]) -> Void), sendBody: ((Data) -> Void)) {
        do {
            let returnResult = try routeRequest(environ: environ)
            startResponse("200 OK", [])
            sendBody(Data(returnResult.utf8))
            sendBody(Data())
        } catch Abort.custom(status: let status, message: let message) {
            startResponse("\(status) BAD REQUEST", [])
            sendBody(Data(message.utf8))
            sendBody(Data())
        } catch let error {
            startResponse("500 INTERNAL SERVER ERROR", [])
            sendBody(Data("\(error)".utf8))
            sendBody(Data())
        }
    }
    
    private func routeRequest(environ: [String: Any]) throws -> String {
        let routes = [
            "/ping": servePing,
            "/project": serveProject,
            "/files": serveFiles,
            "/complete": serveComplete,
        ]
        
        guard let path = environ["PATH_INFO"] as? String,
            let route = routes[path] else {
                throw Abort.custom(
                    status: 400,
                    message: "{\"error\": \"Could not generate file list\"}"
                )
        }
        
        return try route(environ)
    }
}

/**
 Concrete implementation of the calls
 */
extension CompletionServer {
    func servePing(environ: [String: Any]) throws -> String {
        return "OK"
    }
    
    func serveProject(environ: [String: Any]) throws -> String {
        return self.completer.project.projectFile.path
    }
    
    func serveFiles(environ: [String: Any]) throws -> String {
        let files = self.completer.sourceFiles()
        guard let jsonFiles = try? JSONSerialization.data(
            withJSONObject: files,
            options: JSONSerialization.WritingOptions.prettyPrinted
            ),
            let filesString = String(data: jsonFiles, encoding: String.Encoding.utf8) else {
                throw Abort.custom(
                    status: 400,
                    message: "{\"error\": \"Could not generate file list\"}"
                )
        }
        return filesString
    }
    
    func serveComplete(environ: [String: Any]) throws -> String {
        // HTTP is request header default prefix
        
        print("requseting recv")
        guard let offsetString = environ["HTTP_X_OFFSET"] as? String,
            let offset = Int(offsetString) else {
                throw Abort.custom(
                    status: 400,
                    message: "{\"error\": \"Need X-Offset as completion offset for completion\"}"
                )
        }
        
        guard let path = environ["HTTP_X_PATH"] as? String else {
            throw Abort.custom(
                status: 400,
                message: "{\"error\": \"Need X-Path as path to the temporary buffer\"}"
            )
        }

        guard let prefixString = environ["HTTP_X_PREFIX"] as? String else {
            throw Abort.custom(
                status: 400,
                message: "{\"error\": \"Need X-Prefix\"}"
                )
        }
        
        print("[HTTP] GET /complete X-Offset:\(offset) X-Path:\(path) prefix: \(prefixString)")
        
        let url = URL(fileURLWithPath: path)
        let result = self.completer.complete(url, offset: offset)
        
        switch result {
        case .success(result: let items):
            let filtered = items.filter(prefixString)
            if filtered.count > 0 {
//                self.caches[cacheKey] = items
//                self.cacheKeys.append(cacheKey)
//                if self.cacheKeys.count > 10 {
//                    let key = self.cacheKeys.removeFirst()
//                    self.caches.removeValue(forKey: key)
//                }
                return filtered.asJSONString()
            } else {
                return "[]"
            }
        case .failure(message: let msg):
            throw Abort.custom(
                status: 400,
                message: "{\"error\": \"\(msg)\"}"
            )
        }
    }
}

typealias ResultType = [Array<String>]

func _getCharPointer(_ string : String) -> UnsafeMutablePointer<Int8> {
    return UnsafeMutablePointer<Int8>(mutating: (string as NSString).utf8String!)
}

func _getWeight(_ string: String, patten: UnsafeMutablePointer<PatternContext>) -> CGFloat {
    return CGFloat(getWeight(_getCharPointer(string), UInt16(string.lengthOfBytes(using: .utf8)), patten, 0))
}

extension Array where Element == CodeCompletionItem {
    func filter(_ prefixString:String = "") -> ResultType {
        
        print("item count \(count)")
        
        var filtered: ResultType = []
        let patten = initPattern(_getCharPointer(prefixString), UInt16(prefixString.lengthOfBytes(using: .utf8)))
        if prefixString != "" {
            for item in self {
                if let desc = item.descriptionKey {
                   let weight = _getWeight(desc, patten: patten!)
                    //print(weight)
                    if weight > 0.01 {
                        filtered.append([item.sourcetext ?? "", item.descriptionKey ?? "", ""])
                    }
                }
            }
        } else { // use this class
            print("empty prefix")
            for item in self {
//                if item.context.hasPrefix("thisclass") {
                    filtered.append([item.sourcetext ?? "", item.descriptionKey ?? "", ""])
//                }
            }
        }

        print("filter item count \(filtered.count)")
        return filtered
    }
}

extension Array where Element == Array<String> {
//    func filter(withType type: CompleteType, prefixString:String = "") -> ResultType {
//
//        var filtered:ResultType = []
//        if prefixString != "" {
//            for item in self {
//                if let sourceText = item.first,
//                    sourceText.hasPrefix(prefixString) {
//                    filtered.append(item)
//                    continue
//                }
//            }
//        } else {
//            filtered = self
//        }
//
//        print("filter item count \(filtered.count)")
//        return filtered
//    }

//    func asJSONString() -> String {  // format for vim
//        let itemsString = self.map { (item) -> String in
//            return "{'word':'\(item[0])', 'abbr':'\(item[1])'}"
//        }.joined()
//        return "[\(itemsString)]"
//    }
    
    func asJSONString() -> String {
        let items = self.map { (item) -> [String: String] in
            return ["word":item[0], "abbr":item[1], "menu":item[2]]
            }

        let toJson : (Any) -> Data = { obj in
            do {
                return try JSONSerialization.data(withJSONObject: obj, options: [])
            } catch {}
            return Data()
        }

        let data = toJson(items)
        return String.init(data: data, encoding: String.Encoding.utf8) ?? ""
    }
}

extension String {
    func getPrefix() -> String { // if return "", maybe "self.", need search thisclass type
        if let index = index(where: { $0 == "." || $0 == " " }) {
            return substring(from: self.index(after: index))
        }
        return self
    }
}

