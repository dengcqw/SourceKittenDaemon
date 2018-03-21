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
            try routeRequest(environ: environ) { (returnResult) in
                startResponse("200 OK", [])
                sendBody(Data(returnResult.utf8))
                sendBody(Data())
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
        }
        
        let url = URL(fileURLWithPath: path)
        let result = self.completer.complete(url, offset: offset)
        
        switch result {
        case .success(result: let items):
            if items.count > 0 {
                
                print("item count \(items.count)")
                
                caches[cacheKey] = items
                cacheKeys.append(cacheKey)
                if cacheKeys.count > 5 {
                    let key = cacheKeys.removeFirst()
                    caches.removeValue(forKey: key)
                }
                
                /* TODO: figure crash reason
                let queue = DispatchQueue(label: "com.sourcekittend.filter", attributes: .concurrent)
                var i = 0
                var endIndex = 0

                let date = Date()
                var total:[[String: String]] = []
                while i < items.count {
                    endIndex = i + 100
                    if endIndex >= items.count {
                        endIndex = items.count
                    }
                    print("filter \(i) - \(endIndex)")
                    let subArr = Array(items[i..<endIndex])
                    queue.async {
                        let filtered = subArr.filter(prefixString)
                        total.append(contentsOf: filtered)
                    }
                    i = endIndex
                }
                queue.async(flags: .barrier) {
                    print("all work done")
                    print("complete time: \(date.timeIntervalSinceNow)")
//                    DispatchQueue.main.async {
                        print("filter item count \(total.count)")
                        response(total.asJSONString())
//                    }
                }
 */

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
//        let patten = initPattern(_getCharPointer(prefixString), UInt16(prefixString.lengthOfBytes(using: .utf8)))
        if prefixString != "" {
            for item in self {
//                if let desc = item.descriptionKey {
//                   let weight = _getWeight(desc, patten: patten!)
                    //print(weight)
//                    if weight > 0.01 {
                        filtered.append(item.vimFormatItem())
//                    }
//                }
            }
        } else { // use this class
            print("empty prefix")
            for item in self {
                if item.context.hasSuffix("thisclass") {
                    filtered.append(item.vimFormatItem())
                }
            }
        }

        return filtered
    }
}

extension CodeCompletionItem {
    func vimFormatItem() -> [String: String] {
        return ["word":sourcetext ?? "", "abbr":descriptionKey ?? "", "menu":""]
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

