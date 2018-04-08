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

    private func requestHandler(environ: [String: Any], startResponse: @escaping ((String, [(String, String)]) -> Void), sendBody: @escaping ((Data) -> Void)) {
        do {
            startResponse("200 OK", [])
            let loop = environ["embassy.event_loop"] as! EventLoop
            try routeRequest(environ: environ) { (returnResult) in
                loop.call {
                    sendBody(Data(returnResult.utf8))
                    sendBody(Data())
                }
            }
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
    
    private func routeRequest(environ: [String: Any], response:@escaping (String) -> Void) throws {
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
        
        try route(environ, response)
    }
}

/**
 Concrete implementation of the calls
 */
extension CompletionServer {
    func servePing(environ: [String: Any], response:(String) -> Void) throws {
        response("OK")
    }
    
    func serveProject(environ: [String: Any], response:(String) -> Void) throws {
        response(self.completer.project.projectFile.path)
    }
    
    func serveFiles(environ: [String: Any], response:(String) -> Void) throws {
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
        response(filesString)
    }
    
    func serveComplete(environ: [String: Any], response:@escaping (String)->Void) throws {
        // "HTTP" is request header default prefix
        
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
        
        guard let _cacheKey = environ["HTTP_X_CACHEKEY"] as? String else {
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
        
        let cacheKey = offsetString + path + _cacheKey
        if let cache = self.caches[cacheKey] {
            print("target caches \(cacheKey)")
            response(cache.filter(prefixString).asJSONString())
            return
        }
        
        let url = URL(fileURLWithPath: path)
        let result = self.completer.complete(url, offset: offset)
        
        switch result {
        case .success(result: let items):
            print("item count \(items.count)")
            if items.count > 0 {
                caches[cacheKey] = items
                cacheKeys.append(cacheKey)
                if cacheKeys.count > 5 {
                    let key = cacheKeys.removeFirst()
                    caches.removeValue(forKey: key)
                }
                let date = Date()
                let filtered = items.filter(prefixString)
                print("complete time: \(date.timeIntervalSinceNow)")
                response(filtered.asJSONString())
            } else {
                response("[]")
            }
        case .failure(message: let msg):
            throw Abort.custom(
                status: 400,
                message: "{\"error\": \"\(msg)\"}"
            )
        }
    }
}

func _getCharPointer(_ string : String) -> UnsafeMutablePointer<Int8> {
    return UnsafeMutablePointer<Int8>(mutating: (string as NSString).utf8String!)
}

func _getWeight(_ string: String, patten: UnsafeMutablePointer<PatternContext>) -> CGFloat {
    return CGFloat(getWeight(_getCharPointer(string), UInt16(string.lengthOfBytes(using: .utf8)), patten, 0))
}

extension Array where Element == CodeCompletionItem {
    func filter(_ prefixString:String = "") -> [[String: String]] {
        
        var filtered: [[String: String]] = []
        if prefixString != "" {
            for item in self {
                if item.descriptionKey?.hasPrefix("accessibility") == true {
                    continue
                }
                filtered.append(item.vimFormatItem())
            }
        } else { // use this class
            print("empty prefix")
            for item in self {
                if item.descriptionKey?.hasPrefix("accessibility") == true {
                    continue
                }
                filtered.append(item.vimFormatItem())
            }
        }

        return filtered
    }
}

extension CodeCompletionItem {
    func vimFormatItem() -> [String: String] {
        return ["word":sourcetext ?? "", "abbr":descriptionKey ?? ""]
    }
}

extension Array {
    func asJSONString() -> String {
        let toJson : (Any) -> Data = { obj in
            do {
                return try JSONSerialization.data(withJSONObject: obj, options: [])
            } catch {}
            return Data()
        }

        let data = toJson(self)
        return String.init(data: data, encoding: String.Encoding.utf8) ?? ""
    }
}

